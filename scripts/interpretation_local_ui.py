#!/usr/bin/env python3
"""Issue #54 — localhost-only daily UI over the validated batch importer.

The browser is only a presentation surface.  This adapter owns no Maimemo write
request: preview delegates to the importer's read-only preflight and execution
delegates to ``run_batch`` so its fresh preflight, exact confirmation binding,
one-POST/no-retry guard and immediate authenticated readback stay authoritative.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import hmac
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import secrets
import subprocess
import threading
import time
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlsplit
import webbrowser

import interpretation_batch_importer as importer
import issue9_live_harness as harness


STATIC_ROOT = Path(__file__).resolve().parent / "local_ui"
LOOPBACK_HOST = "127.0.0.1"
EPHEMERAL_PORT = 0
MAIN_ACCOUNT_LABEL = "主账号"
SESSION_HEADER = "X-Momo-Session"
MAX_HTTP_BODY_BYTES = importer.MAX_INPUT_BYTES + 16_384
IDLE_TIMEOUT_SECONDS = 300.0

# Closed grammar for the owner's compact ordinary paste.  These are syntax
# markers only: the accepted line is carried to the importer byte-for-byte.
ORDINARY_POS_MARKERS: tuple[str, ...] = (
    "n.",
    "v.",
    "adj.",
    "adv.",
    "phr.",
    "prep.",
    "conj.",
    "pron.",
    "det.",
    "num.",
    "interj.",
)

UI_CREATE = "CREATE"
UI_UPDATE = "UPDATE"
UI_MATCHING = "ALREADY_MATCHING"
UI_BLOCKED = "BLOCKED"
UI_STATES = (UI_CREATE, UI_UPDATE, UI_MATCHING, UI_BLOCKED)

CSP = (
    "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; "
    "form-action 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
    "img-src 'self' data:"
)

# Static AppleScript: the Token is returned on stdout and is never interpolated
# into argv, an environment variable, a file, a browser response or page state.
NATIVE_TOKEN_SCRIPT = """set answer to display dialog \"请输入当前登录的目标主账号 Token。本工具无法自动判断 Token 属于哪个账号。\" with title \"momo-moreEfficient · 连接主账号\" default answer \"\" with hidden answer buttons {\"取消\", \"连接\"} default button \"连接\" cancel button \"取消\"\nreturn text returned of answer"""
NATIVE_TOKEN_ARGV = ("/usr/bin/osascript", "-e", NATIVE_TOKEN_SCRIPT)


class LocalUiError(Exception):
    """A fixed owner-facing failure that never carries external or private text."""

    MESSAGES: Mapping[str, str] = {
        "not-connected": "请先点击“连接主账号”。",
        "token-cancelled": "未连接主账号；Token 提示已取消或输入无效。",
        "input-rejected": "输入格式不符合要求；请检查单词、词性标记和空行分组。",
        "preview-required": "请先预览当前输入。",
        "preview-stale": "预览已失效；未发送写请求，请重新预览。",
        "group-empty": "这个操作组没有可执行项目。",
        "group-finished": "这个操作组已经执行完成。",
        "request-rejected": "本地请求已被安全拒绝。",
        "execution-stopped": "执行已停止；不会重试、回滚或继续剩余项目。",
    }

    def __init__(self, code: str) -> None:
        if code not in self.MESSAGES:
            code = "request-rejected"
        self.code = code
        super().__init__(self.MESSAGES[code])

    @property
    def public_message(self) -> str:
        return self.MESSAGES[self.code]

    def __repr__(self) -> str:
        return f"LocalUiError({self.code!r})"


@dataclass(frozen=True)
class AdaptedBatch:
    """One accepted canonical or ordinary paste batch."""

    entries: tuple[importer.BatchEntry, ...]
    canonical_text: str = field(repr=False)
    input_format: str


def _ordinary_pos_marker(line: str) -> str | None:
    """Return the reviewed marker for one non-empty definition line."""
    return next(
        (
            marker
            for marker in ORDINARY_POS_MARKERS
            if line.startswith(marker) and line[len(marker):].strip()
        ),
        None,
    )


def _compact_items(block: Sequence[str]) -> list[list[str]]:
    """Parse one no-blank compact block through the closed POS grammar."""
    if len(block) < 2 or _ordinary_pos_marker(block[0]) is not None:
        raise LocalUiError("input-rejected")
    items: list[list[str]] = []
    spelling = block[0]
    definitions: list[str] = []
    for line in block[1:]:
        if _ordinary_pos_marker(line) is not None:
            definitions.append(line)
            continue
        if not definitions:
            raise LocalUiError("input-rejected")
        items.append([spelling, *definitions])
        spelling = line
        definitions = []
    if not definitions:
        raise LocalUiError("input-rejected")
    items.append([spelling, *definitions])
    return items


def adapt_batch_text(document: Any) -> AdaptedBatch:
    """Accept canonical Markdown, blank blocks or compact POS-marked paste.

    In compact form every definition line starts with one reviewed POS marker;
    the next non-POS line is deterministically a spelling.  A possible spelling
    without a following POS definition fails closed instead of being attached to
    the previous interpretation.
    """
    if not isinstance(document, str) or len(document.encode("utf-8")) > importer.MAX_INPUT_BYTES:
        raise LocalUiError("input-rejected")
    normalized = document.replace("\r\n", "\n").replace("\r", "\n")
    try:
        if any(line.rstrip().startswith("#") for line in normalized.split("\n")):
            return AdaptedBatch(
                entries=importer.parse_batch(document),
                canonical_text=document,
                input_format="canonical-markdown",
            )

        blocks: list[list[str]] = []
        current: list[str] = []
        for line in normalized.split("\n"):
            if not line.strip():
                if current:
                    blocks.append(current)
                    current = []
                continue
            current.append(line)
        if current:
            blocks.append(current)
        if not blocks or any(len(block) < 2 for block in blocks):
            raise LocalUiError("input-rejected")
        ordinary_items: list[list[str]] = []
        for block in blocks:
            # POS-prefixed bodies use the compact grammar even when the owner
            # also inserted occasional blank separators.  Legacy blank-delimited
            # blocks whose first body line is not POS-prefixed remain accepted:
            # the blank boundary makes their one-item shape unambiguous.
            if _ordinary_pos_marker(block[1]) is not None:
                ordinary_items.extend(_compact_items(block))
            elif len(blocks) > 1:
                ordinary_items.append(block)
            else:
                raise LocalUiError("input-rejected")
        canonical = "\n\n".join(
            f"## {item[0]}\n" + "\n".join(item[1:]) for item in ordinary_items
        )
        return AdaptedBatch(
            entries=importer.parse_batch(canonical),
            canonical_text=canonical,
            input_format="ordinary-paste",
        )
    except LocalUiError:
        raise
    except Exception:
        raise LocalUiError("input-rejected") from None


def _entry_identity(entries: Sequence[importer.BatchEntry]) -> str:
    return importer._digest(
        [
            {
                "ordinal": entry.ordinal,
                "spelling": entry.spelling,
                "interpretation": entry.interpretation,
            }
            for entry in entries
        ]
    )


def _reindexed_entry(entry: importer.BatchEntry, ordinal: int) -> importer.BatchEntry:
    return importer.BatchEntry(
        ordinal=ordinal,
        spelling=entry.spelling,
        normalized_spelling=entry.normalized_spelling,
        interpretation=entry.interpretation,
        line=entry.line,
    )


def _reindexed_verdict(
    verdict: importer.PreflightItem, ordinal: int, state: str
) -> importer.PreflightItem:
    return importer.PreflightItem(
        ordinal=ordinal,
        spelling=verdict.spelling,
        interpretation=verdict.interpretation,
        state=state,
        existing_count=verdict.existing_count,
        vocabulary_id=verdict.vocabulary_id,
        returned_spelling=verdict.returned_spelling,
        error_class=verdict.error_class,
        http_status=verdict.http_status,
        baseline=verdict.baseline,
    )


def _ui_state(verdict: importer.PreflightItem) -> str:
    if verdict.state == importer.BLOCK_MISSING:
        return UI_CREATE
    if verdict.state == importer.READY_UPDATE:
        return UI_UPDATE
    if verdict.state == importer.ALREADY_MATCHING:
        return UI_MATCHING
    return UI_BLOCKED


def _safe_preview_item(verdict: importer.PreflightItem) -> dict[str, Any]:
    state = _ui_state(verdict)
    baseline = verdict.baseline
    item: dict[str, Any] = {
        "ordinal": verdict.ordinal,
        "spelling": verdict.spelling,
        "state": state,
        "proposed": verdict.interpretation,
    }
    if state in (UI_UPDATE, UI_MATCHING) and baseline is not None:
        item["current"] = baseline.interpretation
    if state == UI_BLOCKED:
        item["reason"] = (
            "AMBIGUOUS" if verdict.state == importer.BLOCK_AMBIGUOUS else "READ_FAILED"
        )
    return item


def _group_material(
    entries: Sequence[importer.BatchEntry],
    verdicts: Sequence[importer.PreflightItem],
    *,
    mode: str,
) -> tuple[tuple[importer.BatchEntry, ...], tuple[importer.PreflightItem, ...]]:
    wanted = UI_CREATE if mode == importer.MODE_CREATE else UI_UPDATE
    selected = [
        (entry, verdict)
        for entry, verdict in zip(entries, verdicts)
        if _ui_state(verdict) == wanted
    ]
    group_entries = tuple(
        _reindexed_entry(entry, ordinal)
        for ordinal, (entry, _verdict) in enumerate(selected, start=1)
    )
    state = importer.READY_CREATE if mode == importer.MODE_CREATE else importer.READY_UPDATE
    group_verdicts = tuple(
        _reindexed_verdict(verdict, ordinal, state)
        for ordinal, (_entry, verdict) in enumerate(selected, start=1)
    )
    return group_entries, group_verdicts


def _plan_signature(plan: importer.BatchPlan) -> str:
    """Full digest of the exact existing confirmation binding; never emitted."""
    return importer._digest(plan.confirmation_binding())


def _preview_plan(
    *,
    mode: str,
    entries: Sequence[importer.BatchEntry],
    verdicts: Sequence[importer.PreflightItem],
    credential: importer.MainAccountCredential,
) -> tuple[tuple[importer.BatchEntry, ...], str | None]:
    group_entries, group_verdicts = _group_material(entries, verdicts, mode=mode)
    if not group_entries:
        return (), None
    builder = importer.build_plan if mode == importer.MODE_CREATE else importer.build_update_plan
    plan = builder(
        account_label=MAIN_ACCOUNT_LABEL,
        credential_fingerprint=credential.fingerprint,
        entries=group_entries,
        preflight=group_verdicts,
        account_mode=importer.ACCOUNT_MAIN,
    )
    return group_entries, _plan_signature(plan)


@dataclass(repr=False)
class PreviewSnapshot:
    nonce: str
    input_identity: str
    entries: tuple[importer.BatchEntry, ...] = field(repr=False)
    verdicts: tuple[importer.PreflightItem, ...] = field(repr=False)
    create_entries: tuple[importer.BatchEntry, ...] = field(repr=False)
    update_entries: tuple[importer.BatchEntry, ...] = field(repr=False)
    create_signature: str | None = field(default=None, repr=False)
    update_signature: str | None = field(default=None, repr=False)
    executed: set[str] = field(default_factory=set, repr=False)
    created: int = 0
    updated: int = 0
    failed: int = 0

    @property
    def matching(self) -> int:
        return sum(_ui_state(item) == UI_MATCHING for item in self.verdicts)

    def __repr__(self) -> str:
        return (
            "PreviewSnapshot(items="
            f"{len(self.entries)}, create={len(self.create_entries)}, "
            f"update={len(self.update_entries)}, matching={self.matching})"
        )


def prompt_main_account_credential(
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> importer.MainAccountCredential:
    """Obtain the main-account Token through one static hidden native prompt."""
    try:
        completed = runner(
            list(NATIVE_TOKEN_ARGV),
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise LocalUiError("token-cancelled")
        answer = completed.stdout.rstrip("\r\n")
        return importer.MainAccountCredential(answer, MAIN_ACCOUNT_LABEL)
    except LocalUiError:
        raise
    except Exception:
        raise LocalUiError("token-cancelled") from None


class LocalUiController:
    """Memory-only UI state.  Its repr contains no credential or private text."""

    def __init__(
        self,
        *,
        transport_factory: Callable[[], harness.Transport] = harness.ProductionHttpTransport,
        token_prompt: Callable[[], importer.MainAccountCredential] = prompt_main_account_credential,
        report_factory: Callable[[], importer.BatchRunReport] = importer.BatchRunReport,
        sleep: Callable[[float], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
        idle_timeout: float = IDLE_TIMEOUT_SECONDS,
    ) -> None:
        if not isinstance(idle_timeout, (int, float)) or idle_timeout <= 0:
            raise LocalUiError("request-rejected")
        self._transport_factory = transport_factory
        self._token_prompt = token_prompt
        self._report_factory = report_factory
        self._sleep = sleep
        self._clock = clock
        self._idle_timeout = float(idle_timeout)
        self._last_activity = float(clock())
        self._credential: importer.MainAccountCredential | None = None
        self._preview: PreviewSnapshot | None = None
        self._lock = threading.RLock()

    def __repr__(self) -> str:
        return "LocalUiController(<memory-only state>)"

    def connect(self) -> dict[str, Any]:
        # A reconnect attempt first forgets the previous credential.  Cancelling
        # a new prompt can therefore never silently leave an older account live.
        with self._lock:
            self._credential = None
            self._preview = None
            self._last_activity = float(self._clock())
        credential = self._token_prompt()
        if not isinstance(credential, importer.MainAccountCredential):
            raise LocalUiError("token-cancelled")
        with self._lock:
            self._credential = credential
            self._preview = None
            self._last_activity = float(self._clock())
        return {"connected": True}

    def disconnect(self) -> None:
        """Immediately forget the Token and every preview authorization."""
        with self._lock:
            self._credential = None
            self._preview = None
            self._last_activity = float(self._clock())

    def _expire_locked(self, now: float) -> bool:
        if (
            self._credential is None
            or now - self._last_activity < self._idle_timeout
        ):
            return False
        self._credential = None
        self._preview = None
        self._last_activity = now
        return True

    def expire_if_idle(self) -> bool:
        """Clear credentials after a bounded inactive interval; never sleeps."""
        with self._lock:
            return self._expire_locked(float(self._clock()))

    def heartbeat(self) -> dict[str, Any]:
        """Keep one visible browser session active, or report its expiry."""
        with self._lock:
            now = float(self._clock())
            expired = self._expire_locked(now)
            self._last_activity = now
            return {"connected": self._credential is not None, "expired": expired}

    def _require_credential(self) -> importer.MainAccountCredential:
        now = float(self._clock())
        self._expire_locked(now)
        credential = self._credential
        if credential is None:
            raise LocalUiError("not-connected")
        self._last_activity = now
        return credential

    def preview(self, document: Any) -> dict[str, Any]:
        adapted = adapt_batch_text(document)
        with self._lock:
            credential = self._require_credential()
            # Starting a new preview invalidates the old one immediately.  A
            # read failure can therefore never leave an earlier plan executable.
            self._preview = None
            guard = importer.BatchWriteGuard(
                self._transport_factory(),
                max_gets=2 * len(adapted.entries),
                max_posts=0,
                sleep=self._sleep,
            )
            verdicts = importer.preflight_batch(
                guard,
                adapted.entries,
                credential,
                mode=importer.MODE_UPDATE,
            )
            if guard.post_count != 0:
                raise LocalUiError("request-rejected")
            for verdict in verdicts:
                baseline = verdict.baseline
                if any(
                    credential.token in value
                    for value in (verdict.spelling, verdict.interpretation)
                ) or (
                    baseline is not None
                    and any(
                        credential.token in value
                        for value in (
                            baseline.interpretation,
                            baseline.record_id,
                            *baseline.tags,
                        )
                    )
                ):
                    raise LocalUiError("request-rejected")
            create_entries, create_signature = _preview_plan(
                mode=importer.MODE_CREATE,
                entries=adapted.entries,
                verdicts=verdicts,
                credential=credential,
            )
            update_entries, update_signature = _preview_plan(
                mode=importer.MODE_UPDATE,
                entries=adapted.entries,
                verdicts=verdicts,
                credential=credential,
            )
            snapshot = PreviewSnapshot(
                nonce=secrets.token_urlsafe(24),
                input_identity=_entry_identity(adapted.entries),
                entries=adapted.entries,
                verdicts=verdicts,
                create_entries=create_entries,
                update_entries=update_entries,
                create_signature=create_signature,
                update_signature=update_signature,
            )
            self._preview = snapshot
            self._last_activity = float(self._clock())
            return self._preview_response(snapshot, adapted.input_format)

    def _preview_response(
        self, snapshot: PreviewSnapshot, input_format: str | None = None
    ) -> dict[str, Any]:
        counts = {state: 0 for state in UI_STATES}
        items = []
        for verdict in snapshot.verdicts:
            counts[_ui_state(verdict)] += 1
            items.append(_safe_preview_item(verdict))
        response: dict[str, Any] = {
            "preview_nonce": snapshot.nonce,
            "items": items,
            "counts": {
                "create": counts[UI_CREATE],
                "update": counts[UI_UPDATE],
                "matching": counts[UI_MATCHING],
                "blocked": counts[UI_BLOCKED],
            },
            "actions": {
                "create": bool(snapshot.create_entries)
                and importer.MODE_CREATE not in snapshot.executed,
                "update": bool(snapshot.update_entries)
                and importer.MODE_UPDATE not in snapshot.executed,
            },
            "summary": {
                "created": snapshot.created,
                "updated": snapshot.updated,
                "matching": snapshot.matching,
                "failed": snapshot.failed,
            },
        }
        if input_format is not None:
            response["input_format"] = input_format
        return response

    def execute(self, mode: str, document: Any, preview_nonce: Any) -> dict[str, Any]:
        if mode not in (importer.MODE_CREATE, importer.MODE_UPDATE):
            raise LocalUiError("request-rejected")
        adapted = adapt_batch_text(document)
        with self._lock:
            credential = self._require_credential()
            snapshot = self._preview
            if snapshot is None:
                raise LocalUiError("preview-required")
            if (
                not isinstance(preview_nonce, str)
                or not hmac.compare_digest(preview_nonce, snapshot.nonce)
                or not hmac.compare_digest(
                    _entry_identity(adapted.entries), snapshot.input_identity
                )
            ):
                self._preview = None
                raise LocalUiError("preview-stale")
            if mode in snapshot.executed:
                raise LocalUiError("group-finished")
            group_entries = (
                snapshot.create_entries if mode == importer.MODE_CREATE else snapshot.update_entries
            )
            expected_signature = (
                snapshot.create_signature
                if mode == importer.MODE_CREATE
                else snapshot.update_signature
            )
            if not group_entries or expected_signature is None:
                raise LocalUiError("group-empty")

            approved = False

            def confirm(plan: importer.BatchPlan) -> str:
                nonlocal approved
                if not hmac.compare_digest(_plan_signature(plan), expected_signature):
                    return ""
                approved = True
                return plan.expected_confirmation

            result = importer.run_batch(
                mode=mode,
                entries=group_entries,
                transport=self._transport_factory(),
                credential=credential,
                account_label=MAIN_ACCOUNT_LABEL,
                confirm=confirm,
                emit=lambda _line: None,
                sleep=self._sleep,
                report=self._report_factory(),
                account_mode=importer.ACCOUNT_MAIN,
            )

            if not approved or (result.status == "blocked" and result.post_count == 0):
                self._preview = None
                raise LocalUiError("preview-stale")

            verified = result.verified_count
            if mode == importer.MODE_CREATE:
                snapshot.created += verified
            else:
                snapshot.updated += verified
            if result.status != "verified":
                snapshot.failed += 1
                response = self._preview_response(snapshot)
                response["actions"] = {"create": False, "update": False}
                response["result"] = {
                    "operation": UI_CREATE if mode == importer.MODE_CREATE else UI_UPDATE,
                    "succeeded": verified,
                    "failed": 1,
                    "stopped": True,
                    "message": LocalUiError.MESSAGES["execution-stopped"],
                }
                self._preview = None
                self._last_activity = float(self._clock())
                return response
            snapshot.executed.add(mode)
            self._last_activity = float(self._clock())
            response = self._preview_response(snapshot)
            response["result"] = {
                "operation": UI_CREATE if mode == importer.MODE_CREATE else UI_UPDATE,
                "succeeded": verified,
                "failed": 0,
            }
            return response


class LocalUiHttpServer(HTTPServer):
    allow_reuse_address = False

    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        *,
        controller: LocalUiController,
        session_secret: str,
    ) -> None:
        if server_address != (LOOPBACK_HOST, EPHEMERAL_PORT):
            raise LocalUiError("request-rejected")
        self.controller = controller
        self.session_secret = session_secret
        super().__init__(server_address, handler_class, bind_and_activate=True)
        host, port = self.server_address
        if host != LOOPBACK_HOST or not isinstance(port, int) or port <= 0:
            self.server_close()
            raise LocalUiError("request-rejected")
        self.expected_origin = f"http://{LOOPBACK_HOST}:{port}"

    def service_actions(self) -> None:
        """Called by ``serve_forever`` each poll; clears abandoned credentials."""
        self.controller.expire_if_idle()


class LocalUiRequestHandler(BaseHTTPRequestHandler):
    server: LocalUiHttpServer

    def log_message(self, _format: str, *args: Any) -> None:
        """Suppress request logging so query/body/private text never reaches logs."""

    def _headers(self, status: int, content_type: str, length: int) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.end_headers()

    def _send_bytes(self, status: int, body: bytes, content_type: str) -> None:
        self._headers(status, content_type, len(body))
        self.wfile.write(body)

    def _send_json(self, status: int, value: Mapping[str, Any]) -> None:
        body = json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        self._send_bytes(status, body, "application/json; charset=utf-8")

    def _authorized_api_request(self) -> bool:
        origin = self.headers.get("Origin")
        supplied = self.headers.get(SESSION_HEADER)
        return (
            isinstance(origin, str)
            and hmac.compare_digest(origin, self.server.expected_origin)
            and isinstance(supplied, str)
            and hmac.compare_digest(supplied, self.server.session_secret)
        )

    def _read_json(self) -> Mapping[str, Any]:
        if self.headers.get_content_type() != "application/json":
            raise LocalUiError("request-rejected")
        try:
            length = int(self.headers.get("Content-Length", ""))
        except (TypeError, ValueError):
            raise LocalUiError("request-rejected") from None
        if length < 0 or length > MAX_HTTP_BODY_BYTES:
            raise LocalUiError("request-rejected")
        try:
            value = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            raise LocalUiError("request-rejected") from None
        if not isinstance(value, Mapping):
            raise LocalUiError("request-rejected")
        return value

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlsplit(self.path)
        if parsed.query or parsed.fragment:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "未找到。"})
            return
        assets = {
            "/": ("index.html", "text/html; charset=utf-8"),
            "/index.html": ("index.html", "text/html; charset=utf-8"),
            "/app.js": ("app.js", "text/javascript; charset=utf-8"),
            "/styles.css": ("styles.css", "text/css; charset=utf-8"),
        }
        asset = assets.get(parsed.path)
        if asset is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "未找到。"})
            return
        try:
            body = (STATIC_ROOT / asset[0]).read_bytes()
        except Exception:
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "页面不可用。"})
            return
        self._send_bytes(HTTPStatus.OK, body, asset[1])

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized_api_request():
            self._send_json(
                HTTPStatus.FORBIDDEN,
                {"error": LocalUiError.MESSAGES["request-rejected"]},
            )
            return
        path = urlsplit(self.path)
        if path.query or path.fragment:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "未找到。"})
            return
        try:
            payload = self._read_json()
            if path.path == "/api/connect" and set(payload) == set():
                response = self.server.controller.connect()
            elif path.path == "/api/heartbeat" and set(payload) == set():
                response = self.server.controller.heartbeat()
            elif path.path == "/api/preview" and set(payload) == {"document"}:
                response = self.server.controller.preview(payload["document"])
            elif path.path in ("/api/execute-create", "/api/execute-update") and set(
                payload
            ) == {"document", "preview_nonce"}:
                mode = (
                    importer.MODE_CREATE
                    if path.path.endswith("create")
                    else importer.MODE_UPDATE
                )
                response = self.server.controller.execute(
                    mode, payload["document"], payload["preview_nonce"]
                )
            elif path.path == "/api/quit" and set(payload) == set():
                self.server.controller.disconnect()
                response = {"stopped": True}
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                raise LocalUiError("request-rejected")
        except LocalUiError as rejected:
            self._send_json(
                HTTPStatus.CONFLICT if rejected.code.startswith("preview") else HTTPStatus.BAD_REQUEST,
                {"error": rejected.public_message, "code": rejected.code},
            )
            return
        except Exception:
            self._send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": LocalUiError.MESSAGES["request-rejected"]},
            )
            return
        self._send_json(HTTPStatus.OK, response)


def build_server(
    controller: LocalUiController,
    *,
    session_secret: str | None = None,
    server_class: type[LocalUiHttpServer] = LocalUiHttpServer,
) -> LocalUiHttpServer:
    secret = session_secret or secrets.token_urlsafe(32)
    if not isinstance(secret, str) or len(secret) < 32:
        raise LocalUiError("request-rejected")
    return server_class(
        (LOOPBACK_HOST, EPHEMERAL_PORT),
        LocalUiRequestHandler,
        controller=controller,
        session_secret=secret,
    )


def run_local_ui(*, open_browser: Callable[[str], Any] = webbrowser.open) -> None:
    controller = LocalUiController()
    server = build_server(controller)
    try:
        # The fragment is not sent in the HTTP request and therefore cannot
        # enter request logs.  Unlike embedding the secret in a public GET
        # response, it also prevents another local process from fetching it.
        open_browser(f"{server.expected_origin}/#{server.session_secret}")
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()


def main() -> int:
    try:
        run_local_ui()
    except Exception:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
