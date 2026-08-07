#!/usr/bin/env python3
"""Fail-closed Issue #9 smoke harness.

The default CLI mode is an offline plan. Live-capable components accept an
injected transport and an injected test-account credential, so tests can prove
the safety contract without reading credentials or opening a network socket.
"""

from __future__ import annotations

import argparse
from copy import deepcopy
from dataclasses import dataclass, field
import getpass
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
from types import MappingProxyType
from typing import Any, Callable, Mapping, NoReturn, Protocol
import unicodedata
from urllib.parse import parse_qsl, urlencode, urlsplit
import warnings

import issue2_smoke


PRODUCTION_SCHEME = "https"
PRODUCTION_HOST = "open.maimemo.com"
PRODUCTION_BASE_URL = f"{PRODUCTION_SCHEME}://{PRODUCTION_HOST}"
OPEN_API_PREFIX = issue2_smoke.OPEN_API_PREFIX
DEFAULT_TIMEOUT_SECONDS = 10.0
MAX_RESPONSE_BYTES = 1_048_576
IDENTITY_ENDPOINT_FINDING = "没有找到"
TEST_ACCOUNT_CREDENTIAL_SOURCE = "secondary-test-account"
CONFIRMATION_PREFIX = "CONFIRM WRITE STEP"
REQUIRED_TAGS = tuple(issue2_smoke.REQUIRED_TAGS)
MAX_ACCOUNT_LABEL_CHARS = 96
MAX_GATE_CONFIRMATION_CHARS = 256
MAX_TOKEN_CHARS = 8_192
FORBIDDEN_ACCOUNT_LABEL_MARKERS = (
    "main",
    "primary",
    "owner",
    "prod",
    "production",
    "主号",
    "主账号",
    "主账户",
    "生产",
)
REQUIRED_TEST_ACCOUNT_LABEL_MARKERS = (
    "secondary",
    "test",
    "副号",
    "副账号",
    "测试",
)
READ_ONLY_ENDPOINT_TEMPLATES = (
    f"GET {OPEN_API_PREFIX}/vocabulary?spelling=<word>",
    f"GET {OPEN_API_PREFIX}/interpretations?voc_id=<id>",
    f"GET {OPEN_API_PREFIX}/phrases?voc_id=<id>",
)
READ_ONLY_CONFIRMATION_PREFIX = "CONFIRM READ-ONLY PROBE"
READ_ONLY_PRICING_TERMS_CLAUSE = "PRICING-TERMS-CHECKED: YES"
MAX_PROBE_WORD_CHARS = 256
PRIVATE_HIGHLIGHT_MAX_BYTES = 4_096
PRIVATE_HIGHLIGHT_MAX_DEPTH = 8
PRIVATE_HIGHLIGHT_MAX_ITEMS = 128
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "tests" / "fixtures" / "issue2-smoke-input.example.json"
PRIVATE_STATE_ROOT = ROOT / "artifacts" / "private"


class SafetyError(RuntimeError):
    """A fail-closed safety check rejected the requested action."""


class ConfirmationError(SafetyError):
    """The exact per-step confirmation was absent or incorrect."""


class TransportError(RuntimeError):
    """A transport failed without exposing credentials or response content."""


class TransportResponseError(TransportError):
    """A completely received response was rejected on its content.

    It carries only the numeric HTTP status, so the Issue #14 read-only
    diagnostic can still report that a response existed when the body was
    oversized, invalid UTF-8, invalid JSON or not a JSON object, and for a
    redirect whose body is deliberately never read.

    It is deliberately **not** used for transport I/O failures. A body read that
    times out, resets or ends early never crossed the transport completion
    boundary, so it stays a plain :class:`TransportError` with no status at all.

    Every write-path handler catches ``TransportError`` and therefore treats this
    narrower subclass identically.
    """

    def __init__(self, http_status: Any) -> None:
        super().__init__("response was rejected before use; outcome may be unknown")
        self.http_status = _plain_http_status(http_status)


class UnknownOutcomeError(SafetyError):
    """A write outcome is unknown; the caller must stop and inspect manually."""


class VerificationError(SafetyError):
    """A write or its immediate readback did not verify exactly."""


def _is_finite_positive(value: float) -> bool:
    return math.isfinite(value) and value > 0


def _plain_http_status(value: Any) -> int | None:
    """Return a plain in-range status code, or None when none is available."""
    if not isinstance(value, int) or isinstance(value, bool):
        return None
    status = int(value)
    if not 100 <= status <= 599:
        return None
    return status


def _validate_read_only_origin_contract() -> None:
    expected_endpoints = (
        "GET /open/api/v1/vocabulary?spelling=<word>",
        "GET /open/api/v1/interpretations?voc_id=<id>",
        "GET /open/api/v1/phrases?voc_id=<id>",
    )
    if (
        PRODUCTION_SCHEME != "https"
        or PRODUCTION_HOST != "open.maimemo.com"
        or PRODUCTION_BASE_URL != "https://open.maimemo.com"
        or READ_ONLY_ENDPOINT_TEMPLATES != expected_endpoints
    ):
        raise SafetyError("read-only production origin or endpoint set changed")


def _validate_api_path(path: str) -> None:
    if not isinstance(path, str) or not path.startswith(f"{OPEN_API_PREFIX}/"):
        raise SafetyError(f"path must stay under {OPEN_API_PREFIX}/")
    if (
        "://" in path
        or "\\" in path
        or "#" in path
        or any(ord(char) < 32 for char in path)
    ):
        raise SafetyError("path must be a safe relative OpenAPI path")
    if ".." in path.split("?", 1)[0].split("/"):
        raise SafetyError("path traversal is forbidden")


def _validate_reviewed_request(method: str, path: str) -> None:
    """Allow only the Issue #2/#9 paths present in the reviewed schema."""

    if method == "GET":
        parsed = urlsplit(path)
        endpoints = {
            f"{OPEN_API_PREFIX}/vocabulary": "spelling",
            f"{OPEN_API_PREFIX}/interpretations": "voc_id",
            f"{OPEN_API_PREFIX}/phrases": "voc_id",
        }
        pairs = parse_qsl(parsed.query, keep_blank_values=True)
        if (
            not parsed.scheme
            and not parsed.netloc
            and not parsed.fragment
            and parsed.path in endpoints
            and len(pairs) == 1
            and pairs[0][0] == endpoints[parsed.path]
            and pairs[0][1] != ""
        ):
            return
    elif method == "POST":
        if re.fullmatch(
            rf"{re.escape(OPEN_API_PREFIX)}/(?:interpretations|phrases)"
            rf"(?:/[A-Za-z0-9_-]+)?",
            path,
        ):
            return
    raise SafetyError("request path is outside the reviewed Issue #2/#9 endpoints")


def _safe_record_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
        raise SafetyError(f"{label} must be one safe path segment")
    return value


def build_query_path(resource: str, params: Mapping[str, Any]) -> str:
    contracts = {
        "vocabulary": "spelling",
        "interpretations": "voc_id",
        "phrases": "voc_id",
    }
    if resource not in contracts:
        raise SafetyError("query resource is not a reviewed endpoint")
    if set(params) != {contracts[resource]}:
        raise SafetyError("documented GET query parameters do not match the endpoint")
    for key, value in params.items():
        if (
            not isinstance(key, str)
            or not key
            or not isinstance(value, (str, int))
            or isinstance(value, str)
            and not value
        ):
            raise SafetyError("query parameters must be non-empty string/int pairs")
    path = f"{OPEN_API_PREFIX}/{resource}?{urlencode(params)}"
    _validate_api_path(path)
    _validate_reviewed_request("GET", path)
    return path


def _fingerprint(value: str) -> dict[str, Any]:
    encoded = value.encode("utf-8")
    return {
        "sha256": hashlib.sha256(encoded).hexdigest(),
        "utf8_bytes": len(encoded),
    }


def _freeze_json(value: Any) -> Any:
    """Defensively copy JSON-shaped data into recursively immutable containers."""

    if isinstance(value, Mapping):
        return MappingProxyType(
            {str(key): _freeze_json(item) for key, item in value.items()}
        )
    if isinstance(value, (list, tuple)):
        return tuple(_freeze_json(item) for item in value)
    return deepcopy(value)


def _thaw_json(value: Any) -> Any:
    """Return a detached JSON-serializable copy of frozen prepared data."""

    if isinstance(value, Mapping):
        return {str(key): _thaw_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_thaw_json(item) for item in value]
    return deepcopy(value)


_SENSITIVE_KEYS = {"authorization", "cookie", "token", "access_token"}
_CONTENT_KEYS = {
    "id",
    "voc_id",
    "interpretation",
    "phrase",
    "origin",
    "spelling",
}


def redact(value: Any, *, key: str | None = None) -> Any:
    """Return a deterministic, non-secret representation safe to persist."""

    normalized_key = key.lower() if key else None
    if normalized_key in _SENSITIVE_KEYS:
        return "[REDACTED]"
    if isinstance(value, Mapping):
        return {str(item_key): redact(item, key=str(item_key)) for item_key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [redact(item, key=key) for item in value]
    if isinstance(value, str) and normalized_key in _CONTENT_KEYS:
        return {"fingerprint": _fingerprint(value)}
    return value


def _assert_no_sensitive_keys(value: Any, path: str = "value") -> None:
    if isinstance(value, Mapping):
        for raw_key, item in value.items():
            key = str(raw_key)
            normalized = key.casefold()
            if any(term in normalized for term in ("authorization", "cookie", "token")):
                raise SafetyError(f"{path} contains a forbidden sensitive field")
            _assert_no_sensitive_keys(item, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            _assert_no_sensitive_keys(item, f"{path}[{index}]")


def _contains_credential_material(value: Any, credential_value: str) -> bool:
    if isinstance(value, Mapping):
        return any(
            _contains_credential_material(item, credential_value)
            for item in value.values()
        )
    if isinstance(value, (list, tuple)):
        return any(
            _contains_credential_material(item, credential_value) for item in value
        )
    return isinstance(value, str) and credential_value in value


def _has_control_characters(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def _validate_account_label_shape(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or len(value) > MAX_ACCOUNT_LABEL_CHARS
        or _has_control_characters(value)
    ):
        raise SafetyError("account label does not meet the fixed safety policy")
    normalized = value.casefold()
    if any(marker in normalized for marker in FORBIDDEN_ACCOUNT_LABEL_MARKERS):
        raise SafetyError("main or production account labels are forbidden")
    if not any(
        marker in normalized for marker in REQUIRED_TEST_ACCOUNT_LABEL_MARKERS
    ):
        raise SafetyError("account label is not an explicit secondary/test account label")
    return value


@dataclass(frozen=True)
class HttpRequest:
    method: str
    path: str
    payload: Mapping[str, Any] | None = None
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS

    def __post_init__(self) -> None:
        if self.method not in {"GET", "POST"}:
            raise SafetyError("only documented GET and POST requests are allowed")
        _validate_api_path(self.path)
        _validate_reviewed_request(self.method, self.path)
        if not _is_finite_positive(self.timeout_seconds):
            raise SafetyError("every request requires a finite positive timeout")
        if self.method == "GET" and self.payload is not None:
            raise SafetyError("GET requests must not carry a request payload")
        if self.method == "POST" and not isinstance(self.payload, Mapping):
            raise SafetyError("POST requests require a reviewed object payload")
        if self.payload is not None:
            object.__setattr__(self, "payload", _freeze_json(self.payload))


@dataclass(frozen=True, repr=False)
class TestAccountCredential:
    """An injected credential. There is deliberately no CLI or file loader."""

    token: str = field(repr=False)
    account_label: str
    source_name: str = TEST_ACCOUNT_CREDENTIAL_SOURCE

    def __post_init__(self) -> None:
        if (
            not isinstance(self.token, str)
            or not self.token
            or self.token != self.token.strip()
            or len(self.token) > MAX_TOKEN_CHARS
            or _has_control_characters(self.token)
        ):
            raise SafetyError("an injected test-account credential is required")
        label = _validate_account_label_shape(self.account_label)
        if self.token in label:
            raise SafetyError("account label contains forbidden credential material")
        if self.source_name != TEST_ACCOUNT_CREDENTIAL_SOURCE:
            raise SafetyError("credential source is not the secondary test-account source")

    def __repr__(self) -> str:
        return "TestAccountCredential(<redacted>)"

    def __str__(self) -> str:
        return "<redacted test-account credential>"

    @property
    def fingerprint(self) -> str:
        return hashlib.sha256(self.token.encode("utf-8")).hexdigest()[:16]


@dataclass(frozen=True, repr=False)
class ManualAccountGate:
    allow_network: bool
    account_label: str
    credential_fingerprint: str
    confirmation: str

    def __post_init__(self) -> None:
        _validate_account_label_shape(self.account_label)
        if (
            not isinstance(self.credential_fingerprint, str)
            or re.fullmatch(r"[0-9a-f]{16}", self.credential_fingerprint) is None
        ):
            raise SafetyError("credential fingerprint does not meet the fixed policy")
        if (
            not isinstance(self.confirmation, str)
            or not self.confirmation
            or self.confirmation != self.confirmation.strip()
            or len(self.confirmation) > MAX_GATE_CONFIRMATION_CHARS
            or _has_control_characters(self.confirmation)
        ):
            raise SafetyError("account confirmation does not meet the fixed policy")

    def __repr__(self) -> str:
        return (
            "ManualAccountGate(allow_network="
            f"{self.allow_network!r}, account_label=<redacted>, "
            f"credential_fingerprint={self.credential_fingerprint!r}, "
            "confirmation=<redacted>)"
        )

    def __str__(self) -> str:
        return (
            "<manual account gate; label/confirmation redacted; "
            f"fingerprint={self.credential_fingerprint}>"
        )

    @property
    def expected_confirmation(self) -> str:
        return (
            f"CONFIRM SECONDARY TEST ACCOUNT: {self.account_label} "
            f"TOKEN-FP: {self.credential_fingerprint}"
        )

    def validate(self, credential: TestAccountCredential) -> None:
        if not self.allow_network:
            raise SafetyError("network mode was not explicitly enabled")
        label = _validate_account_label_shape(self.account_label)
        if credential.account_label != label:
            raise SafetyError("credential label does not match the confirmed account")
        if credential.token in label or credential.token in self.confirmation:
            raise SafetyError("account gate contains forbidden credential material")
        if self.credential_fingerprint != credential.fingerprint:
            raise SafetyError("credential fingerprint does not match the confirmed token")
        if self.confirmation != self.expected_confirmation:
            raise SafetyError("secondary test-account confirmation does not match exactly")


class Transport(Protocol):
    def send(
        self, request: HttpRequest, credential: TestAccountCredential
    ) -> "HttpResponse": ...


@dataclass(frozen=True)
class HttpResponse:
    status: int
    body: Mapping[str, Any]


class ProductionHttpTransport:
    """Minimal stdlib transport with a locked host and no retry behavior."""

    def __init__(
        self,
        *,
        connect_timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        read_timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    ) -> None:
        _validate_read_only_origin_contract()
        if not _is_finite_positive(connect_timeout_seconds):
            raise SafetyError("connect timeout must be finite and positive")
        if not _is_finite_positive(read_timeout_seconds):
            raise SafetyError("read timeout must be finite and positive")
        self.connect_timeout_seconds = connect_timeout_seconds
        self.read_timeout_seconds = read_timeout_seconds

    def send(
        self, request: HttpRequest, credential: TestAccountCredential
    ) -> HttpResponse:
        _validate_api_path(request.path)
        connection = http.client.HTTPSConnection(
            PRODUCTION_HOST,
            timeout=min(request.timeout_seconds, self.connect_timeout_seconds),
        )
        payload = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {credential.token}",
        }
        if request.payload is not None:
            payload = json.dumps(
                _thaw_json(request.payload), ensure_ascii=False
            ).encode("utf-8")
            headers["Content-Type"] = "application/json"

        try:
            try:
                connection.connect()
                if connection.sock is None:
                    raise OSError("connection socket unavailable")
                connection.sock.settimeout(
                    min(request.timeout_seconds, self.read_timeout_seconds)
                )
                connection.request(
                    request.method, request.path, body=payload, headers=headers
                )
                response = connection.getresponse()
                # Remember only the numeric status, so a response that is later
                # rejected on content can still be reported as "a response
                # existed" without touching its body.
                status = _plain_http_status(response.status)
                is_redirect = 300 <= response.status < 400
                # A redirect body is never read, so no redirect content is
                # touched and the Authorization header is never forwarded.
                raw = None if is_redirect else response.read(MAX_RESPONSE_BYTES + 1)
            except Exception:
                # Connect, request, getresponse and response-body I/O failures
                # stay plain transport failures even when the status line has
                # already arrived: a timeout, reset, SSL failure or incomplete
                # read means this request never crossed the transport completion
                # boundary, so no status may be reported for it.
                raise TransportError("request failed; outcome may be unknown") from None

            # Past this point the response body has been completely received (or
            # deliberately not read, for a redirect), so only content rejections
            # remain and they may keep the numeric status.
            decoded: Any = None
            rejected = (
                is_redirect
                or not isinstance(raw, (bytes, bytearray))
                or len(raw) > MAX_RESPONSE_BYTES
            )
            if not rejected:
                try:
                    decoded = json.loads(bytes(raw).decode("utf-8")) if raw else {}
                except Exception:
                    rejected = True
                else:
                    rejected = not isinstance(decoded, dict)
            if rejected:
                raise TransportResponseError(status)
            return HttpResponse(status=response.status, body=decoded)
        finally:
            connection.close()


@dataclass(frozen=True)
class ExistingInterpretation:
    record_id: str | None
    text: str
    ownership_confirmed: bool
    tags: tuple[str, ...] = ()
    status: str = "PUBLISHED"

    def rollback_record(self) -> dict[str, Any]:
        if self.record_id is None:
            raise SafetyError("interpretation record id is missing")
        return {
            "id": self.record_id,
            "interpretation": self.text,
            "tags": list(self.tags),
            "status": self.status,
        }


@dataclass(frozen=True)
class InterpretationDecision:
    operation: Mapping[str, Any]
    existing_record: Mapping[str, Any] | None

    def interactive_preview(self) -> dict[str, Any]:
        return {
            "existing_record": deepcopy(self.existing_record),
            "proposed_payload": deepcopy(self.operation["payload"]),
        }

    def safe_summary(self) -> dict[str, Any]:
        return redact(self.interactive_preview())


def choose_interpretation_operation(
    vocabulary_id: str,
    proposed_text: str,
    existing: list[ExistingInterpretation],
) -> InterpretationDecision:
    """Choose create/update only when ownership and record identity are unambiguous."""

    if not existing:
        operation = issue2_smoke.build_interpretation_operation(
            vocabulary_id, proposed_text
        )
        return InterpretationDecision(
            operation=operation,
            existing_record=None,
        )
    if len(existing) != 1:
        raise SafetyError("multiple existing interpretations are ambiguous")

    record = existing[0]
    if not record.ownership_confirmed or not record.record_id:
        raise SafetyError("interpretation ownership or record id is not confirmed")
    operation = issue2_smoke.build_interpretation_operation(
        vocabulary_id,
        proposed_text,
        existing_id=record.record_id,
    )
    return InterpretationDecision(
        operation=operation,
        existing_record=record.rollback_record(),
    )


@dataclass(frozen=True)
class PreparedStep:
    sequence: int
    action: str
    vocabulary_id: str
    method: str
    path: str
    payload: Mapping[str, Any]
    readback_path: str
    response_key: str
    confirmation: str
    rollback_snapshot: Mapping[str, Any] | None

    def __post_init__(self) -> None:
        if isinstance(self.payload, Mapping):
            object.__setattr__(self, "payload", _freeze_json(self.payload))
        if isinstance(self.rollback_snapshot, Mapping):
            object.__setattr__(
                self,
                "rollback_snapshot",
                _freeze_json(self.rollback_snapshot),
            )

    def interactive_preview(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "action": self.action,
            "method": self.method,
            "path": self.path,
            "payload": _thaw_json(self.payload),
            "existing_record": _thaw_json(self.rollback_snapshot),
            "required_confirmation": self.confirmation,
        }

    def safe_summary(self) -> dict[str, Any]:
        summary = redact(self.interactive_preview())
        if self.action.startswith("update_"):
            record_id = self.path.rsplit("/", 1)[-1]
            summary["path"] = (
                self.path.rsplit("/", 1)[0]
                + "/[ID-SHA256:"
                + _fingerprint(record_id)["sha256"][:16]
                + "]"
            )
        return summary

    def persisted_state(
        self,
        status: str,
        credential_fingerprint: str,
        **details: Any,
    ) -> dict[str, Any]:
        document = {
            "version": 3,
            "sequence": self.sequence,
            "action": self.action,
            "status": status,
            "credential_fingerprint": credential_fingerprint,
            "safe_step_summary": self.safe_summary(),
            "request": {
                "method": self.method,
                "path": self.path,
                "payload": _thaw_json(self.payload),
            },
            "rollback_snapshot": _thaw_json(self.rollback_snapshot),
            **details,
        }
        _assert_no_sensitive_keys(document)
        return document


def _confirmation_for(
    sequence: int, method: str, path: str, payload: Mapping[str, Any]
) -> str:
    canonical = json.dumps(
        {"method": method, "path": path, "payload": _thaw_json(payload)},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()[:12]
    return f"{CONFIRMATION_PREFIX} {sequence}: {digest}"


def _normalize_rollback_record(
    action: str,
    existing_record: Mapping[str, Any] | None,
) -> Mapping[str, Any] | None:
    if not action.startswith("update_"):
        if existing_record is not None:
            raise SafetyError("create steps must not carry an existing record")
        return None
    if not isinstance(existing_record, Mapping):
        raise SafetyError("update steps require a complete rollback record")

    if action == "update_interpretation":
        required = ("id", "interpretation", "tags", "status")
    elif action.startswith("update_phrase_"):
        required = (
            "id",
            "phrase",
            "interpretation",
            "tags",
            "origin",
            "status",
        )
    else:
        raise SafetyError("update action is outside the reviewed operations")

    missing = [key for key in required if key not in existing_record]
    if missing:
        raise SafetyError(
            f"rollback record is missing required fields: {', '.join(missing)}"
        )
    snapshot = {key: deepcopy(existing_record[key]) for key in required}
    _safe_record_id(snapshot["id"], "rollback record id")
    if not isinstance(snapshot["tags"], (list, tuple)) or not all(
        isinstance(tag, str) for tag in snapshot["tags"]
    ):
        raise SafetyError("rollback record tags must be a string list")
    snapshot["tags"] = list(snapshot["tags"])
    for key, value in snapshot.items():
        if key not in {"tags"} and not isinstance(value, str):
            raise SafetyError(f"rollback record {key} must be a string")
    if action.startswith("update_phrase_") and snapshot["status"] != "PUBLISHED":
        raise SafetyError("phrase rollback status must be PUBLISHED")
    _assert_no_sensitive_keys(snapshot, "rollback record")
    return snapshot


_ACTION_CONTRACTS: dict[str, tuple[str, tuple[str, ...], str, bool]] = {
    "create_interpretation": (
        "interpretation",
        ("voc_id", "interpretation", "tags", "status"),
        "interpretations",
        False,
    ),
    "update_interpretation": (
        "interpretation",
        ("interpretation", "tags", "status"),
        "interpretations",
        True,
    ),
    "create_phrase_exact_case": (
        "phrase",
        ("voc_id", "phrase", "interpretation", "tags", "origin"),
        "phrases",
        False,
    ),
    "update_phrase_inflected_case": (
        "phrase",
        ("phrase", "interpretation", "tags", "origin"),
        "phrases",
        True,
    ),
    "update_phrase_multiple_case": (
        "phrase",
        ("phrase", "interpretation", "tags", "origin"),
        "phrases",
        True,
    ),
}


def _require_nonempty_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SafetyError(f"{label} must be a non-empty string")
    return value


def _validate_required_request_tags(value: Any) -> None:
    if not isinstance(value, (list, tuple)) or tuple(value) != REQUIRED_TAGS:
        raise SafetyError("write tags must be exactly MBA, BEC, GMAT")


def _validate_operation_payload(
    action: str,
    path: str,
    payload: Mapping[str, Any],
    vocabulary_id: str,
) -> None:
    contract = _ACTION_CONTRACTS.get(action)
    if contract is None:
        raise SafetyError("operation action is outside the reviewed write contract")
    entity_key, expected_fields, resource, is_update = contract
    target_vocabulary_id = _safe_record_id(vocabulary_id, "target vocabulary id")
    if set(payload) != {entity_key}:
        raise SafetyError("write payload top-level keys do not match the reviewed contract")
    entity = payload.get(entity_key)
    if not isinstance(entity, Mapping) or set(entity) != set(expected_fields):
        raise SafetyError("write payload entity keys do not match the reviewed contract")
    if is_update:
        match = re.fullmatch(
            rf"{re.escape(OPEN_API_PREFIX)}/{resource}/([A-Za-z0-9_-]+)",
            path,
        )
        if match is None:
            raise SafetyError("write action does not match its reviewed update path")
        _safe_record_id(match.group(1), "update record id")
    elif path != f"{OPEN_API_PREFIX}/{resource}":
        raise SafetyError("write action does not match its reviewed create path")

    _validate_required_request_tags(entity.get("tags"))
    if entity_key == "interpretation":
        _require_nonempty_text(entity.get("interpretation"), "interpretation")
        if entity.get("status") != "PUBLISHED":
            raise SafetyError("interpretation status must be PUBLISHED")
    else:
        for field_name in ("phrase", "interpretation", "origin"):
            _require_nonempty_text(entity.get(field_name), f"phrase {field_name}")

    if is_update:
        if "voc_id" in entity or "id" in entity:
            raise SafetyError("update payload must not contain voc_id or id")
    elif entity.get("voc_id") != target_vocabulary_id:
        raise SafetyError("create payload voc_id does not match the target vocabulary")


def _response_contract(action: str) -> tuple[str, str, bool]:
    contract = _ACTION_CONTRACTS.get(action)
    if contract is None:
        raise SafetyError("operation action is outside the reviewed write contract")
    entity_key, _fields, resource, is_update = contract
    return entity_key, resource, is_update


def prepare_operation(
    operation: Mapping[str, Any],
    vocabulary_id: str,
    *,
    phrase_record_id: str | None = None,
    existing_record: Mapping[str, Any] | None = None,
) -> PreparedStep:
    method = operation.get("method")
    path = operation.get("path")
    payload = operation.get("payload")
    sequence = operation.get("sequence")
    action = operation.get("action")
    if (
        method != "POST"
        or not isinstance(path, str)
        or not isinstance(payload, Mapping)
        or not isinstance(sequence, int)
        or not isinstance(action, str)
    ):
        raise SafetyError("operation is not one reviewed write step")

    target_vocabulary_id = _safe_record_id(vocabulary_id, "target vocabulary id")
    if issue2_smoke.CREATED_PHRASE_ID in path:
        if not phrase_record_id:
            raise SafetyError("phrase update requires the previously captured record id")
        record_id = _safe_record_id(phrase_record_id, "phrase record id")
        path = path.replace(issue2_smoke.CREATED_PHRASE_ID, record_id)

    payload_copy = _thaw_json(payload)
    _validate_api_path(path)
    _validate_reviewed_request(method, path)
    _assert_no_sensitive_keys(payload_copy, "write payload")
    _validate_operation_payload(action, path, payload_copy, target_vocabulary_id)
    if action.startswith("update_") and existing_record is None:
        raise SafetyError("update steps require a pre-write record snapshot")
    rollback_snapshot = _normalize_rollback_record(action, existing_record)
    if rollback_snapshot is not None and path.rsplit("/", 1)[-1] != rollback_snapshot["id"]:
        raise SafetyError("rollback record id does not match the update path")
    _entity_key, resource, _is_update = _response_contract(action)
    readback_path = build_query_path(resource, {"voc_id": target_vocabulary_id})
    response_key = resource
    _validate_api_path(readback_path)

    return PreparedStep(
        sequence=sequence,
        action=action,
        vocabulary_id=target_vocabulary_id,
        method=method,
        path=path,
        payload=payload_copy,
        readback_path=readback_path,
        response_key=response_key,
        confirmation=_confirmation_for(sequence, method, path, payload_copy),
        rollback_snapshot=rollback_snapshot,
    )


def _validate_prepared_step(step: PreparedStep) -> None:
    """Revalidate every value at the final executor trust boundary."""

    if not isinstance(step, PreparedStep):
        raise SafetyError("executor requires one reviewed PreparedStep")
    if not isinstance(step.sequence, int) or isinstance(step.sequence, bool) or step.sequence < 1:
        raise SafetyError("prepared step sequence must be a positive integer")
    if step.method != "POST" or not isinstance(step.path, str):
        raise SafetyError("prepared step method/path are outside the write contract")
    if not isinstance(step.action, str) or not isinstance(step.payload, Mapping):
        raise SafetyError("prepared step action/payload are outside the write contract")
    target_vocabulary_id = _safe_record_id(
        step.vocabulary_id, "target vocabulary id"
    )
    _validate_api_path(step.path)
    _validate_reviewed_request(step.method, step.path)
    _assert_no_sensitive_keys(step.payload, "write payload")
    _validate_operation_payload(
        step.action,
        step.path,
        step.payload,
        target_vocabulary_id,
    )

    _entity_key, resource, is_update = _response_contract(step.action)
    if step.response_key != resource:
        raise SafetyError("prepared response key does not match the write action")
    expected_readback = build_query_path(
        resource, {"voc_id": target_vocabulary_id}
    )
    if step.readback_path != expected_readback:
        raise SafetyError("prepared readback path does not match the target vocabulary")

    normalized = _normalize_rollback_record(
        step.action,
        _thaw_json(step.rollback_snapshot),
    )
    if _thaw_json(step.rollback_snapshot) != _thaw_json(normalized):
        raise SafetyError("prepared rollback snapshot is not canonical")
    if is_update:
        if normalized is None or step.path.rsplit("/", 1)[-1] != normalized["id"]:
            raise SafetyError("prepared update target and rollback record do not match")
    elif normalized is not None:
        raise SafetyError("prepared create must not carry a rollback snapshot")


def build_offline_plan(path: Path = DEFAULT_FIXTURE) -> dict[str, Any]:
    return issue2_smoke.build_plan(issue2_smoke.load_fixture(path))


def prepare_plan_step(
    plan: Mapping[str, Any],
    sequence: int,
    *,
    phrase_record_id: str | None = None,
    existing_record: Mapping[str, Any] | None = None,
) -> PreparedStep:
    operations = plan.get("operations")
    if not isinstance(operations, list):
        raise SafetyError("plan has no operation list")
    matches = [item for item in operations if item.get("sequence") == sequence]
    if len(matches) != 1:
        raise SafetyError("requested sequence is absent or ambiguous")
    vocabulary = plan.get("vocabulary")
    if not isinstance(vocabulary, Mapping) or not isinstance(vocabulary.get("id"), str):
        raise SafetyError("plan has no unambiguous vocabulary id")
    return prepare_operation(
        matches[0],
        vocabulary["id"],
        phrase_record_id=phrase_record_id,
        existing_record=existing_record,
    )


def _documented_read_path(path: str) -> None:
    _validate_api_path(path)
    _validate_reviewed_request("GET", path)


def run_read_only_probe(
    transport: Transport,
    credential: TestAccountCredential,
    gate: ManualAccountGate,
    resource: str,
    params: Mapping[str, Any],
) -> dict[str, Any]:
    gate.validate(credential)
    path = build_query_path(resource, params)
    _documented_read_path(path)
    try:
        response = transport.send(HttpRequest("GET", path), credential)
    except TransportError:
        raise SafetyError("read-only request failed; stop") from None
    if not 200 <= response.status < 300:
        raise SafetyError("read-only request returned a non-success status; stop")
    return {
        "status": response.status,
        "response_shape": _read_only_response_shape(response.body, resource),
    }


def _normalize_probe_spelling(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or len(value) > MAX_PROBE_WORD_CHARS
        or _has_control_characters(value)
    ):
        raise SafetyError("probe word does not meet the fixed safety policy")
    normalized = unicodedata.normalize("NFKC", value).casefold()
    if not normalized:
        raise SafetyError("probe word does not meet the fixed safety policy")
    return normalized


def _read_only_confirmation_for(
    account_label: str,
    credential_fingerprint: str,
    requested_word: str,
) -> str:
    _validate_read_only_origin_contract()
    binding = {
        "account_label": _validate_account_label_shape(account_label),
        "credential_fingerprint": credential_fingerprint,
        "requested_word": requested_word,
        "normalized_word": _normalize_probe_spelling(requested_word),
        "host": PRODUCTION_BASE_URL,
        "endpoints": list(READ_ONLY_ENDPOINT_TEMPLATES),
        "pricing_and_terms_checked": True,
    }
    canonical = json.dumps(
        binding,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()[:16]
    return (
        f"{READ_ONLY_CONFIRMATION_PREFIX}: {digest} "
        f"TOKEN-FP: {credential_fingerprint} {READ_ONLY_PRICING_TERMS_CLAUSE}"
    )


@dataclass(frozen=True, repr=False)
class ReadOnlyProbeGate:
    """One exact confirmation bound to the complete read-only probe context."""

    account_label: str
    credential_fingerprint: str
    requested_word: str
    confirmation: str

    def __post_init__(self) -> None:
        _validate_account_label_shape(self.account_label)
        _normalize_probe_spelling(self.requested_word)
        if (
            not isinstance(self.credential_fingerprint, str)
            or re.fullmatch(r"[0-9a-f]{16}", self.credential_fingerprint) is None
        ):
            raise SafetyError("credential fingerprint does not meet the fixed policy")
        if (
            not isinstance(self.confirmation, str)
            or not self.confirmation
            or self.confirmation != self.confirmation.strip()
            or len(self.confirmation) > MAX_GATE_CONFIRMATION_CHARS
            or _has_control_characters(self.confirmation)
        ):
            raise SafetyError("probe confirmation does not meet the fixed policy")

    def __repr__(self) -> str:
        return (
            "ReadOnlyProbeGate(account_label=<redacted>, "
            f"credential_fingerprint={self.credential_fingerprint!r}, "
            "requested_word=<redacted>, confirmation=<redacted>)"
        )

    def __str__(self) -> str:
        return (
            "<read-only probe gate; account/confirmation redacted; "
            f"fingerprint={self.credential_fingerprint}>"
        )

    @property
    def expected_confirmation(self) -> str:
        return _read_only_confirmation_for(
            self.account_label,
            self.credential_fingerprint,
            self.requested_word,
        )

    def safe_summary(self) -> dict[str, Any]:
        return {
            "mode": "read-only-probe",
            "account_label": "[REDACTED]",
            "token_fingerprint": self.credential_fingerprint,
            "requested_spelling_fingerprint": hashlib.sha256(
                self.requested_word.encode("utf-8")
            ).hexdigest()[:16],
            "host": PRODUCTION_BASE_URL,
            "allowed_endpoints": list(READ_ONLY_ENDPOINT_TEMPLATES),
            "required_confirmation": self.expected_confirmation,
            "manual_gate": (
                "Confirm current official pricing/terms permit personal test-account "
                "use and show no mandatory metered API fee."
            ),
        }

    def validate(self, credential: TestAccountCredential) -> None:
        account_gate = ManualAccountGate(
            allow_network=True,
            account_label=self.account_label,
            credential_fingerprint=self.credential_fingerprint,
            confirmation=(
                f"CONFIRM SECONDARY TEST ACCOUNT: {self.account_label} "
                f"TOKEN-FP: {self.credential_fingerprint}"
            ),
        )
        account_gate.validate(credential)
        if (
            credential.token in self.confirmation
            or credential.token in self.requested_word
        ):
            raise SafetyError("probe inputs contain forbidden credential material")
        if self.confirmation != self.expected_confirmation:
            raise ConfirmationError("read-only probe confirmation does not match exactly")


class ReadOnlyTransportGuard:
    """Prevent a read-only probe from delegating any non-reviewed request."""

    def __init__(self, delegate: Transport) -> None:
        self._delegate = delegate

    def send(
        self,
        request: HttpRequest,
        credential: TestAccountCredential,
    ) -> HttpResponse:
        if not isinstance(request, HttpRequest) or request.method != "GET":
            raise SafetyError("read-only transport accepts GET requests only")
        _documented_read_path(request.path)
        return self._delegate.send(request, credential)


READ_ONLY_CANONICAL_KEYS: Mapping[str, str] = {
    "vocabulary": "voc",
    "interpretations": "interpretations",
    "phrases": "phrases",
}


def _validate_read_only_body(body: Any) -> Mapping[str, Any]:
    """Structurally check a read-only body without copying server key names."""
    if not isinstance(body, Mapping) or not all(
        isinstance(key, str) for key in body
    ):
        raise SafetyError("read-only response is not a JSON object with string keys")
    if any(
        any(term in key.casefold() for term in ("authorization", "cookie", "token"))
        for key in body
    ):
        raise SafetyError("read-only response contains a sensitive top-level field")
    return body


def _read_only_response_shape(body: Any, endpoint: str) -> dict[str, Any]:
    """Summarize response shape with project-defined metadata only.

    Unknown top-level fields are ignored per Issue #11, and their names are
    never copied into the summary: a malformed body could otherwise carry
    private Maimemo content in a key string.
    """
    canonical = READ_ONLY_CANONICAL_KEYS.get(endpoint)
    if canonical is None:
        raise SafetyError("read-only response shape endpoint is not documented")
    body = _validate_read_only_body(body)
    return {
        "canonical_key": canonical,
        "canonical_key_present": canonical in body,
        "unknown_top_level_field_count": sum(1 for key in body if key != canonical),
    }


def _require_read_success(response: Any) -> HttpResponse:
    if not isinstance(response, HttpResponse) or not isinstance(response.status, int):
        raise SafetyError("read-only response status is structurally invalid")
    if 300 <= response.status < 400:
        raise SafetyError("read-only redirect response was rejected")
    if not 200 <= response.status < 300:
        raise SafetyError("read-only request returned a non-success status")
    _validate_read_only_body(response.body)
    return response


READ_ONLY_STATUS_ENUMS: Mapping[str, tuple[str, ...]] = {
    "interpretations": ("PUBLISHED", "UNPUBLISHED", "DELETED"),
    "phrases": ("PUBLISHED", "DELETED"),
}


def _read_only_record_status(record: Mapping[str, Any], response_key: str) -> str:
    """Return the documented status constant, never a server-provided string."""
    allowed = READ_ONLY_STATUS_ENUMS.get(response_key)
    if allowed is None:
        raise SafetyError("read-only record collection is not a documented endpoint")
    value = record.get("status")
    if isinstance(value, str) and not isinstance(value, bool):
        for documented in allowed:
            if value == documented:
                return documented
    raise SafetyError(
        "read-only record status is missing or outside the documented endpoint enum"
    )


def _read_only_phrase_length(record: Mapping[str, Any]) -> int:
    """Measure the phrase in memory only; the body is never printed or persisted."""
    if "phrase" not in record:
        raise SafetyError("phrase record is missing the phrase field")
    phrase = record["phrase"]
    if not isinstance(phrase, str) or not phrase:
        raise SafetyError("phrase record body is structurally invalid")
    return len(phrase)


def _read_only_highlight_shape(value: Any, phrase_length: int) -> str:
    if not isinstance(value, list):
        raise SafetyError("phrase highlight is not a documented range array")
    if not value:
        return "empty-array"

    def valid_range(start: Any, end: Any) -> bool:
        return (
            isinstance(start, int)
            and not isinstance(start, bool)
            and isinstance(end, int)
            and not isinstance(end, bool)
            and 0 <= start < end <= phrase_length
        )

    if all(
        isinstance(item, Mapping)
        and valid_range(item.get("start"), item.get("end"))
        for item in value
    ):
        return "object-range-array"
    if all(
        isinstance(item, (list, tuple))
        and len(item) == 2
        and valid_range(item[0], item[1])
        for item in value
    ):
        return "integer-pair-array"
    raise SafetyError("phrase highlight range structure is ambiguous or invalid")


def _summarize_read_only_records(
    response: HttpResponse,
    response_key: str,
    *,
    inspect_highlight: bool,
) -> tuple[int, dict[str, int], dict[str, int], dict[str, Any]]:
    response = _require_read_success(response)
    records = response.body.get(response_key)
    if not isinstance(records, list):
        raise SafetyError("read-only record collection is not an array")
    seen_ids: set[str] = set()
    statuses: dict[str, int] = {}
    highlight_shapes: dict[str, int] = {}
    for record in records:
        if not isinstance(record, Mapping):
            raise SafetyError("read-only record collection contains a malformed item")
        record_id = _safe_record_id(record.get("id"), "read-only record id")
        if record_id in seen_ids:
            raise SafetyError("read-only record collection contains duplicate ids")
        seen_ids.add(record_id)
        status = _read_only_record_status(record, response_key)
        statuses[status] = statuses.get(status, 0) + 1
        if inspect_highlight:
            phrase_length = _read_only_phrase_length(record)
            if "highlight" not in record:
                raise SafetyError("phrase record is missing highlight structure")
            shape = _read_only_highlight_shape(record["highlight"], phrase_length)
            highlight_shapes[shape] = highlight_shapes.get(shape, 0) + 1
    return (
        len(records),
        statuses,
        highlight_shapes,
        _read_only_response_shape(response.body, response_key),
    )


@dataclass(frozen=True, repr=False)
class ReadOnlyProbeResult:
    requested_spelling: str
    returned_spelling: str
    voc_id_fingerprint: str
    interpretation_count: int
    phrase_count: int
    interpretation_statuses: Mapping[str, int]
    phrase_statuses: Mapping[str, int]
    phrase_highlight_shapes: Mapping[str, int]
    response_statuses: Mapping[str, int]
    response_shapes: Mapping[str, Mapping[str, Any]]

    def __post_init__(self) -> None:
        for field_name in (
            "interpretation_statuses",
            "phrase_statuses",
            "phrase_highlight_shapes",
            "response_statuses",
            "response_shapes",
        ):
            object.__setattr__(self, field_name, _freeze_json(getattr(self, field_name)))

    def safe_summary(self) -> dict[str, Any]:
        return {
            "mode": "read-only-probe",
            "requested_spelling": self.requested_spelling,
            "returned_spelling": self.returned_spelling,
            "voc_id_fingerprint": self.voc_id_fingerprint,
            "interpretation_count": self.interpretation_count,
            "phrase_count": self.phrase_count,
            "interpretation_statuses": _thaw_json(self.interpretation_statuses),
            "phrase_statuses": _thaw_json(self.phrase_statuses),
            "phrase_highlight_shapes": _thaw_json(self.phrase_highlight_shapes),
            "response_statuses": _thaw_json(self.response_statuses),
            "response_shapes": _thaw_json(self.response_shapes),
        }

    def __repr__(self) -> str:
        return f"ReadOnlyProbeResult({self.safe_summary()!r})"

    def __str__(self) -> str:
        return json.dumps(self.safe_summary(), ensure_ascii=False, sort_keys=True)


READ_ONLY_FAILURE_STAGES: tuple[str, ...] = (
    "transport-init",
    "vocabulary",
    "interpretations",
    "phrases",
)
READ_ONLY_FAILURE_CLASSES: tuple[str, ...] = (
    "transport",
    "http-status",
    "schema",
    "safety",
)
READ_ONLY_FAILURE_MESSAGE = (
    "read-only probe stopped safely; only project-owned sanitized diagnostic "
    "fields are available"
)
MAX_READ_ONLY_REQUESTS = len(READ_ONLY_ENDPOINT_TEMPLATES)


@dataclass(frozen=True, repr=False)
class ReadOnlyFailureDiagnostic:
    """Fixed project-owned metadata describing one failed read-only probe.

    Every field is either a constant chosen from a closed project enum or a
    small integer counted locally, so no server text, response body, header,
    redirect target or external exception message can travel through it.

    Fixed class mapping (Issue #14):

    ``transport``
        No usable HTTP response was obtained: transport construction failed, the
        transport raised, or it returned something that is not a structurally
        valid response with a plain numeric status. This includes every response
        body I/O failure — timeout, connection reset, SSL failure, incomplete
        read — even when the status line had already arrived, because such a
        request never crossed the transport completion boundary.
    ``http-status``
        A response arrived and its numeric status was outside 2xx. Redirect (3xx)
        responses are reported here by status number only; the target is never read.
    ``schema``
        A 2xx response whose body was completely received but rejected: the
        already-reviewed structural validation (object shape, record arrays,
        record ids, documented status enum, spelling match, phrase/highlight
        structure) or the transport-level content contract (oversized body,
        invalid UTF-8, invalid JSON, decoded value that is not an object).
    ``safety``
        A local project invariant rejected the run without a response being
        classified: origin/gate/confirmation validation, a request the read-only
        guard refused to dispatch, or a final credential-containment check.

    ``http_status`` is reported exactly for ``http-status`` and ``schema``, which
    are the two classes that by construction follow a received response; it is
    always ``None`` for ``transport`` and ``safety``.
    """

    failure_stage: str
    failure_class: str
    http_status: int | None
    requests_attempted: int
    requests_completed: int

    def __post_init__(self) -> None:
        # Store the module-level constants themselves, so the emitted values can
        # never be a caller-supplied string that merely compares equal.
        stage = next(
            (item for item in READ_ONLY_FAILURE_STAGES if item == self.failure_stage),
            None,
        )
        if stage is None:
            raise SafetyError("read-only failure stage is outside the fixed enum")
        object.__setattr__(self, "failure_stage", stage)
        failure_class = next(
            (item for item in READ_ONLY_FAILURE_CLASSES if item == self.failure_class),
            None,
        )
        if failure_class is None:
            raise SafetyError("read-only failure class is outside the fixed enum")
        object.__setattr__(self, "failure_class", failure_class)
        for name in ("requests_attempted", "requests_completed"):
            counter = getattr(self, name)
            if (
                not isinstance(counter, int)
                or isinstance(counter, bool)
                or not 0 <= counter <= MAX_READ_ONLY_REQUESTS
            ):
                raise SafetyError("read-only request counter is outside the fixed range")
        if self.requests_completed > self.requests_attempted:
            raise SafetyError("read-only completed count cannot exceed attempted count")
        if self.failure_stage == "transport-init" and self.requests_attempted:
            raise SafetyError("transport-init cannot follow a dispatched request")
        status = self.http_status
        if self.failure_class in ("transport", "safety"):
            if status is not None:
                raise SafetyError("no HTTP status may be reported without a response")
        elif _plain_http_status(status) is None:
            raise SafetyError("reported HTTP status is not a plain numeric status code")
        elif self.failure_class == "http-status" and 200 <= status < 300:
            raise SafetyError("a success status cannot be an http-status failure")
        elif self.failure_class == "schema" and not 200 <= status < 300:
            raise SafetyError("a schema failure must follow a success status")
        elif not self.requests_completed:
            raise SafetyError("a reported HTTP status requires a completed request")
        else:
            object.__setattr__(self, "http_status", _plain_http_status(status))

    def safe_summary(self) -> dict[str, Any]:
        return {
            "mode": "read-only-probe",
            "status": "failed",
            "failure_stage": self.failure_stage,
            "failure_class": self.failure_class,
            "http_status": self.http_status,
            "requests_attempted": self.requests_attempted,
            "requests_completed": self.requests_completed,
        }

    def __repr__(self) -> str:
        return f"ReadOnlyFailureDiagnostic({self.safe_summary()!r})"

    def __str__(self) -> str:
        return json.dumps(self.safe_summary(), ensure_ascii=False, sort_keys=True)


class ReadOnlyProbeFailure(SafetyError):
    """A read-only failure that carries sanitized project-owned fields only."""

    def __init__(self, diagnostic: ReadOnlyFailureDiagnostic) -> None:
        if not isinstance(diagnostic, ReadOnlyFailureDiagnostic):
            raise SafetyError("read-only failure requires a project-owned diagnostic")
        super().__init__(READ_ONLY_FAILURE_MESSAGE)
        self.diagnostic = diagnostic

    def safe_summary(self) -> dict[str, Any]:
        return self.diagnostic.safe_summary()

    def detach_external_context(self) -> "ReadOnlyProbeFailure":
        """Drop any external exception object still attached to this failure.

        ``raise ... from None`` only suppresses the implicit context when a
        traceback is formatted; the original library exception stays reachable
        through ``__context__``. Detaching it keeps a socket, SSL, ``http.client``
        or JSON decoder message from being recovered from this object at all.
        """
        self.__cause__ = None
        self.__context__ = None
        self.__suppress_context__ = True
        return self

    def __repr__(self) -> str:
        return f"ReadOnlyProbeFailure({self.diagnostic!r})"

    def __str__(self) -> str:
        return READ_ONLY_FAILURE_MESSAGE


class _ReadOnlyProbeProgress:
    """Track the current stage and the two documented request counters.

    ``requests_attempted`` increments immediately before a reviewed GET is handed
    to the guarded transport. ``requests_completed`` increments only after that
    transport returned a structurally valid response with a plain numeric status,
    which is the transport-level completion boundary and happens before any
    status or schema validation.
    """

    def __init__(self) -> None:
        self.stage = "transport-init"
        self.requests_attempted = 0
        self.requests_completed = 0

    def enter(self, stage: str) -> None:
        if stage == "transport-init" or stage not in READ_ONLY_FAILURE_STAGES:
            raise SafetyError("read-only request stage is outside the fixed enum")
        self.stage = stage

    def dispatched(self) -> None:
        self.requests_attempted += 1

    def responded(self) -> None:
        self.requests_completed += 1

    def failure(
        self,
        failure_class: str,
        http_status: int | None = None,
    ) -> ReadOnlyProbeFailure:
        return ReadOnlyProbeFailure(
            ReadOnlyFailureDiagnostic(
                failure_stage=self.stage,
                failure_class=failure_class,
                http_status=http_status,
                requests_attempted=self.requests_attempted,
                requests_completed=self.requests_completed,
            )
        )


def _read_only_response_status(response: Any) -> int | None:
    """Return a plain numeric status only when a usable response was returned."""
    if not isinstance(response, HttpResponse):
        return None
    return _plain_http_status(response.status)


class ReadOnlyProbeExecutor:
    """Sequential, no-retry executor for the three reviewed GET requests."""

    def __init__(self, transport: Transport) -> None:
        self._transport = ReadOnlyTransportGuard(transport)

    def _send(
        self,
        progress: _ReadOnlyProbeProgress,
        stage: str,
        request: HttpRequest,
        credential: TestAccountCredential,
    ) -> tuple[HttpResponse, int]:
        progress.enter(stage)
        progress.dispatched()
        try:
            response = self._transport.send(request, credential)
        except TransportResponseError as rejected:
            rejected_status = rejected.http_status
            if rejected_status is None:
                raise progress.failure("transport") from None
            progress.responded()
            if 200 <= rejected_status < 300:
                raise progress.failure("schema", rejected_status) from None
            raise progress.failure("http-status", rejected_status) from None
        except SafetyError:
            raise progress.failure("safety") from None
        except Exception:
            raise progress.failure("transport") from None
        status = _read_only_response_status(response)
        if status is None:
            raise progress.failure("transport") from None
        progress.responded()
        if not 200 <= status < 300:
            raise progress.failure("http-status", status) from None
        try:
            _require_read_success(response)
        except Exception:
            raise progress.failure("schema", status) from None
        return response, status

    def execute(
        self,
        credential: TestAccountCredential,
        gate: ReadOnlyProbeGate,
    ) -> ReadOnlyProbeResult:
        progress = _ReadOnlyProbeProgress()
        try:
            return self._execute(progress, credential, gate)
        except ReadOnlyProbeFailure as failure:
            raise failure.detach_external_context() from None
        except Exception:
            unclassified = progress.failure("safety")
        # Raised outside the handler so the rejected external exception is not
        # re-attached as this failure's context by the raise statement itself.
        raise unclassified.detach_external_context() from None

    def _execute(
        self,
        progress: _ReadOnlyProbeProgress,
        credential: TestAccountCredential,
        gate: ReadOnlyProbeGate,
    ) -> ReadOnlyProbeResult:
        try:
            _validate_read_only_origin_contract()
            gate.validate(credential)
            requested_word = gate.requested_word
            vocabulary_request = HttpRequest(
                "GET",
                build_query_path("vocabulary", {"spelling": requested_word}),
            )
        except Exception:
            raise progress.failure("safety") from None

        vocabulary_response, vocabulary_status = self._send(
            progress,
            "vocabulary",
            vocabulary_request,
            credential,
        )
        try:
            vocabulary = vocabulary_response.body.get("voc")
            if not isinstance(vocabulary, Mapping):
                raise SafetyError(
                    "vocabulary response does not contain exactly one usable voc"
                )
            vocabulary_id = _safe_record_id(vocabulary.get("id"), "vocabulary id")
            returned_spelling = vocabulary.get("spelling")
            if not isinstance(returned_spelling, str) or (
                _normalize_probe_spelling(returned_spelling)
                != _normalize_probe_spelling(requested_word)
            ):
                raise SafetyError("vocabulary spelling does not match the requested word")
            vocabulary_shape = _read_only_response_shape(
                vocabulary_response.body, "vocabulary"
            )
        except Exception:
            raise progress.failure("schema", vocabulary_status) from None

        try:
            interpretation_request = HttpRequest(
                "GET",
                build_query_path("interpretations", {"voc_id": vocabulary_id}),
            )
        except Exception:
            progress.enter("interpretations")
            raise progress.failure("safety") from None
        interpretation_response, interpretation_status = self._send(
            progress,
            "interpretations",
            interpretation_request,
            credential,
        )
        try:
            (
                interpretation_count,
                interpretation_statuses,
                _unused_interpretation_highlights,
                interpretation_shape,
            ) = _summarize_read_only_records(
                interpretation_response,
                "interpretations",
                inspect_highlight=False,
            )
        except Exception:
            raise progress.failure("schema", interpretation_status) from None

        try:
            phrase_request = HttpRequest(
                "GET",
                build_query_path("phrases", {"voc_id": vocabulary_id}),
            )
        except Exception:
            progress.enter("phrases")
            raise progress.failure("safety") from None
        phrase_response, phrase_status = self._send(
            progress,
            "phrases",
            phrase_request,
            credential,
        )
        try:
            (
                phrase_count,
                phrase_statuses,
                phrase_highlight_shapes,
                phrase_shape,
            ) = _summarize_read_only_records(
                phrase_response,
                "phrases",
                inspect_highlight=True,
            )
            result = ReadOnlyProbeResult(
                requested_spelling=requested_word,
                returned_spelling=returned_spelling,
                voc_id_fingerprint=hashlib.sha256(
                    vocabulary_id.encode("utf-8")
                ).hexdigest()[:16],
                interpretation_count=interpretation_count,
                phrase_count=phrase_count,
                interpretation_statuses=interpretation_statuses,
                phrase_statuses=phrase_statuses,
                phrase_highlight_shapes=phrase_highlight_shapes,
                response_statuses={
                    "vocabulary": vocabulary_status,
                    "interpretations": interpretation_status,
                    "phrases": phrase_status,
                },
                response_shapes={
                    "vocabulary": vocabulary_shape,
                    "interpretations": interpretation_shape,
                    "phrases": phrase_shape,
                },
            )
        except Exception:
            raise progress.failure("schema", phrase_status) from None
        if _contains_credential_material(result.safe_summary(), credential.token):
            raise progress.failure("safety") from None
        return result


def _extract_written_id(step: PreparedStep, response: HttpResponse) -> str | None:
    singular = "interpretation" if step.response_key == "interpretations" else "phrase"
    entity = response.body.get(singular)
    path_tail = step.path.rsplit("/", 1)[-1]
    update_id = path_tail if path_tail not in {"interpretations", "phrases"} else None
    if isinstance(entity, Mapping) and "id" in entity:
        if not isinstance(entity.get("id"), str):
            raise VerificationError("write response record id is unsafe")
        try:
            response_id = _safe_record_id(entity["id"], "write response record id")
        except SafetyError:
            raise VerificationError("write response record id is unsafe") from None
        if update_id is not None and response_id != update_id:
            raise VerificationError("write response record id changed the update target")
        return response_id
    if update_id is not None:
        return _safe_record_id(update_id, "update record id")
    return None


def _select_readback_record(
    step: PreparedStep,
    response: HttpResponse,
    written_id: str | None,
) -> Mapping[str, Any]:
    raw_records = response.body.get(step.response_key)
    if not isinstance(raw_records, list):
        raise VerificationError("readback response does not contain the expected list")
    if not all(isinstance(record, Mapping) for record in raw_records):
        raise VerificationError("readback list contains an invalid record")
    records = list(raw_records)
    _require_single_interpretation_record(step, records, phase="interpretation readback")
    if written_id is not None:
        matches = [record for record in records if record.get("id") == written_id]
    else:
        matches = records
    if len(matches) != 1:
        raise VerificationError("readback record identity is absent or ambiguous")
    return matches[0]


_READBACK_FIELDS = {
    "create_interpretation": ("interpretation", "tags", "status"),
    "update_interpretation": ("interpretation", "tags", "status"),
    "create_phrase_exact_case": ("phrase", "interpretation", "tags", "origin"),
    "update_phrase_inflected_case": ("phrase", "interpretation", "tags", "origin"),
    "update_phrase_multiple_case": ("phrase", "interpretation", "tags", "origin"),
}


def _snapshot_fields(step: PreparedStep) -> tuple[str, ...]:
    fields = _READBACK_FIELDS.get(step.action)
    if fields is None:
        raise VerificationError("write action has no snapshot contract")
    if step.response_key == "phrases":
        return (*fields, "status")
    return fields


def _verify_phrase_publication_status(
    step: PreparedStep,
    record: Mapping[str, Any],
) -> None:
    if step.response_key == "phrases" and record.get("status") != "PUBLISHED":
        raise VerificationError(
            "phrase publication status is missing or not PUBLISHED"
        )


def _expected_fields(step: PreparedStep) -> Mapping[str, Any]:
    key = "interpretation" if step.response_key == "interpretations" else "phrase"
    fields = step.payload.get(key)
    if not isinstance(fields, Mapping):
        raise VerificationError("write payload does not contain the expected entity")
    required = _READBACK_FIELDS.get(step.action)
    if required is None:
        raise VerificationError("write action has no reviewed readback contract")
    missing = [field for field in required if field not in fields]
    if missing:
        raise VerificationError(
            f"write payload is missing readback fields: {', '.join(missing)}"
        )
    return {field: fields[field] for field in required}


def _verify_fields(expected: Mapping[str, Any], actual: Mapping[str, Any]) -> None:
    mismatches: list[str] = []
    for key, value in expected.items():
        actual_value = actual.get(key)
        if key == "tags":
            if not _tags_equal(value, actual_value):
                mismatches.append(key)
        elif actual_value != value:
            mismatches.append(key)
    if mismatches:
        raise VerificationError(
            f"readback differs in expected fields: {', '.join(sorted(mismatches))}"
        )


def _tags_equal(expected: Any, actual: Any) -> bool:
    if not isinstance(expected, (list, tuple)) or not isinstance(
        actual, (list, tuple)
    ):
        return False
    if not all(isinstance(tag, str) for tag in (*expected, *actual)):
        return False
    if len(expected) != len(set(expected)) or len(actual) != len(set(actual)):
        return False
    return set(expected) == set(actual)


def _record_id(record: Mapping[str, Any]) -> str:
    try:
        return _safe_record_id(record.get("id"), "readback record id")
    except SafetyError:
        raise VerificationError("readback record id is absent or unsafe") from None


def _record_snapshot(step: PreparedStep, record: Mapping[str, Any]) -> dict[str, Any]:
    fields = _snapshot_fields(step)
    snapshot = {"id": _record_id(record)}
    for name in fields:
        if name not in record:
            raise VerificationError(f"readback record is missing snapshot field: {name}")
        snapshot[name] = _thaw_json(record[name])
    _assert_no_sensitive_keys(snapshot, "verified record snapshot")
    return snapshot


@dataclass(frozen=True, repr=False)
class CreateBaseline:
    response_key: str
    record_ids: tuple[str, ...]
    records: tuple[Mapping[str, Any], ...] = field(repr=False)

    def __repr__(self) -> str:
        return (
            f"CreateBaseline(response_key={self.response_key!r}, "
            f"record_count={len(self.record_ids)})"
        )

    def private_state(self) -> dict[str, Any]:
        document = {
            "response_key": self.response_key,
            "record_ids": list(self.record_ids),
            "records": [_thaw_json(record) for record in self.records],
        }
        _assert_no_sensitive_keys(document, "create baseline")
        return document


def _identity_complete_records(
    step: PreparedStep,
    response: HttpResponse,
    *,
    phase: str,
) -> list[Mapping[str, Any]]:
    raw_records = response.body.get(step.response_key)
    if not isinstance(raw_records, list) or not all(
        isinstance(record, Mapping) for record in raw_records
    ):
        raise VerificationError(f"{phase} response has an invalid record list")
    records = list(raw_records)
    record_ids = [_record_id(record) for record in records]
    if len(record_ids) != len(set(record_ids)):
        raise VerificationError(f"{phase} response contains duplicate record ids")
    return records


def _require_single_interpretation_record(
    step: PreparedStep,
    records: list[Mapping[str, Any]],
    *,
    phase: str,
) -> None:
    if step.response_key != "interpretations":
        return
    if len(records) > 1:
        raise VerificationError(
            f"{phase} found multiple user interpretations; manual resolution is required"
        )
    if len(records) != 1:
        raise VerificationError(
            f"{phase} requires exactly one user interpretation"
        )


def _baseline_record_snapshot(
    step: PreparedStep,
    record: Mapping[str, Any],
) -> dict[str, Any]:
    snapshot = _record_snapshot(step, record)
    for key, value in snapshot.items():
        if key == "id":
            continue
        if key == "tags":
            if not isinstance(value, (list, tuple)) or not all(
                isinstance(tag, str) for tag in value
            ):
                raise VerificationError("create baseline tags are structurally invalid")
            snapshot[key] = list(value)
        elif not isinstance(value, str):
            raise VerificationError("create baseline writable field is structurally invalid")
    return snapshot


def _fields_match(expected: Mapping[str, Any], actual: Mapping[str, Any]) -> bool:
    try:
        _verify_fields(expected, actual)
    except VerificationError:
        return False
    return True


def _verify_create_preflight(
    step: PreparedStep,
    response: HttpResponse,
) -> CreateBaseline:
    if not 200 <= response.status < 300:
        raise VerificationError("create preflight returned a non-success status")
    records = _identity_complete_records(step, response, phase="create preflight")
    if step.action == "create_interpretation":
        if len(records) > 1:
            raise VerificationError(
                "create interpretation preflight found multiple user interpretations; "
                "manual resolution is required and no write was sent"
            )
        if len(records) == 1:
            raise VerificationError(
                "create interpretation preflight found an existing record; "
                "prepare the update flow instead"
            )
        return CreateBaseline(step.response_key, (), ())
    if step.action != "create_phrase_exact_case":
        raise VerificationError("create preflight action is outside the reviewed contract")

    snapshots = [_baseline_record_snapshot(step, record) for record in records]
    expected = _expected_fields(step)
    if any(_fields_match(expected, snapshot) for snapshot in snapshots):
        raise VerificationError(
            "create phrase preflight found an exact duplicate; no write was sent"
        )
    snapshots.sort(key=lambda snapshot: str(snapshot["id"]))
    record_ids = tuple(str(snapshot["id"]) for snapshot in snapshots)
    return CreateBaseline(
        step.response_key,
        record_ids,
        tuple(_freeze_json(snapshot) for snapshot in snapshots),
    )


def _select_create_readback_record(
    step: PreparedStep,
    response: HttpResponse,
    written_id: str | None,
    baseline: CreateBaseline,
) -> Mapping[str, Any]:
    records = _identity_complete_records(step, response, phase="create readback")
    _require_single_interpretation_record(
        step,
        records,
        phase="create interpretation readback",
    )
    post_by_id = {_record_id(record): record for record in records}
    baseline_ids = set(baseline.record_ids)
    post_ids = set(post_by_id)
    if not baseline_ids.issubset(post_ids):
        raise VerificationError("create readback lost baseline record identity")

    if written_id is not None:
        if written_id in baseline_ids:
            raise VerificationError("create response id already existed in the baseline")
        record = post_by_id.get(written_id)
        if record is None:
            raise VerificationError("create response id is absent from readback")
        return record

    new_ids = post_ids - baseline_ids
    if len(new_ids) != 1:
        raise VerificationError("create readback did not identify exactly one new record")
    return post_by_id[next(iter(new_ids))]


def _verify_update_preflight(
    step: PreparedStep,
    response: HttpResponse,
) -> Mapping[str, Any]:
    if not 200 <= response.status < 300:
        raise VerificationError("update preflight returned a non-success status")
    target_id = _safe_record_id(step.path.rsplit("/", 1)[-1], "update record id")
    record = _select_readback_record(step, response, target_id)
    snapshot = _thaw_json(step.rollback_snapshot)
    if not isinstance(snapshot, Mapping) or snapshot.get("id") != target_id:
        raise VerificationError("update preflight rollback identity is invalid")
    expected = {name: snapshot[name] for name in _snapshot_fields(step)}
    _verify_fields(expected, record)
    _verify_phrase_publication_status(step, record)
    return record


@dataclass(frozen=True)
class HighlightObservation:
    outcome: str
    raw_shape: str
    normalized_ranges: tuple[tuple[int, int], ...] = ()
    semantic_status: str = "awaiting-owner-app-comparison"
    reason: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome,
            "raw_shape": self.raw_shape,
            "normalized_ranges": [
                {"start": start, "end": end}
                for start, end in self.normalized_ranges
            ],
            "semantic_status": self.semantic_status,
            "reason": self.reason,
        }


def _observe_highlight(
    step: PreparedStep,
    actual: Mapping[str, Any],
) -> HighlightObservation | None:
    if step.response_key != "phrases":
        return None
    if "highlight" not in actual:
        return HighlightObservation(
            outcome="negative",
            raw_shape="missing",
            semantic_status="automatic-highlight-not-observed",
            reason="highlight field is missing",
        )
    raw = actual["highlight"]
    if raw == []:
        return HighlightObservation(
            outcome="negative",
            raw_shape="empty-array",
            semantic_status="automatic-highlight-not-observed",
            reason="highlight range array is empty",
        )
    if not isinstance(raw, list):
        return HighlightObservation(
            outcome="unknown",
            raw_shape=f"non-array:{type(raw).__name__}",
            semantic_status="not-verified",
            reason="highlight structure is not a recognized range array",
        )

    if all(isinstance(item, Mapping) for item in raw):
        raw_shape = "object-range-array"
        candidates = [(item.get("start"), item.get("end")) for item in raw]
    elif all(isinstance(item, (list, tuple)) and len(item) == 2 for item in raw):
        raw_shape = "integer-pair-array"
        candidates = [(item[0], item[1]) for item in raw]
    else:
        return HighlightObservation(
            outcome="unknown",
            raw_shape="unrecognized-array",
            semantic_status="not-verified",
            reason="highlight array mixes or omits recognized range shapes",
        )

    phrase = actual.get("phrase")
    phrase_length = len(phrase) if isinstance(phrase, str) else -1
    ranges: list[tuple[int, int]] = []
    for index, (start, end) in enumerate(candidates):
        if (
            not isinstance(start, int)
            or isinstance(start, bool)
            or not isinstance(end, int)
            or isinstance(end, bool)
            or not 0 <= start < end <= phrase_length
        ):
            return HighlightObservation(
                outcome="invalid",
                raw_shape=raw_shape,
                semantic_status="not-verified",
                reason=f"highlight range {index} is invalid or out of bounds",
            )
        ranges.append((start, end))
    return HighlightObservation(
        outcome="ranges-observed",
        raw_shape=raw_shape,
        normalized_ranges=tuple(ranges),
    )


def _json_utf8_size(value: Any) -> int | None:
    try:
        serialized = json.dumps(
            _thaw_json(value),
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        )
    except (TypeError, ValueError, RecursionError):
        return None
    return len(serialized.encode("utf-8"))


def _bounded_private_highlight(
    value: Any,
    *,
    raw_shape: str,
    credential_value: str,
) -> dict[str, Any]:
    stack: list[tuple[Any, int]] = [(value, 1)]
    maximum_depth = 0
    container_items = 0
    rejection_reason: str | None = None
    while stack:
        item, depth = stack.pop()
        maximum_depth = max(maximum_depth, depth)
        if depth > PRIVATE_HIGHLIGHT_MAX_DEPTH:
            rejection_reason = "depth-limit-exceeded"
            break
        if isinstance(item, Mapping):
            container_items += len(item)
            if container_items > PRIVATE_HIGHLIGHT_MAX_ITEMS:
                rejection_reason = "item-limit-exceeded"
                break
            for raw_key, nested in item.items():
                if not isinstance(raw_key, str):
                    rejection_reason = "non-json-key-rejected"
                    break
                normalized = raw_key.casefold()
                if any(
                    term in normalized
                    for term in ("authorization", "cookie", "token")
                ):
                    rejection_reason = "sensitive-key-rejected"
                    break
                stack.append((nested, depth + 1))
            if rejection_reason is not None:
                break
        elif isinstance(item, (list, tuple)):
            container_items += len(item)
            if container_items > PRIVATE_HIGHLIGHT_MAX_ITEMS:
                rejection_reason = "item-limit-exceeded"
                break
            stack.extend((nested, depth + 1) for nested in item)
        elif isinstance(item, str):
            if credential_value in item:
                rejection_reason = "credential-material-rejected"
                break
        elif item is None or isinstance(item, (bool, int)):
            continue
        elif isinstance(item, float):
            if not math.isfinite(item):
                rejection_reason = "non-json-number-rejected"
                break
        else:
            rejection_reason = "non-json-value-rejected"
            break

    utf8_bytes = _json_utf8_size(value)
    if rejection_reason is None and (
        utf8_bytes is None or utf8_bytes > PRIVATE_HIGHLIGHT_MAX_BYTES
    ):
        rejection_reason = (
            "serialization-rejected"
            if utf8_bytes is None
            else "byte-limit-exceeded"
        )
    if rejection_reason is not None:
        return {
            "status": "evidence-truncated/rejected",
            "raw_shape": raw_shape,
            "utf8_bytes": utf8_bytes,
            "observed_depth": maximum_depth,
            "observed_container_items": container_items,
            "reason": rejection_reason,
        }

    captured = _thaw_json(value)
    _assert_no_sensitive_keys(captured, "bounded raw highlight")
    return {
        "status": "captured",
        "raw_shape": raw_shape,
        "utf8_bytes": utf8_bytes,
        "observed_depth": maximum_depth,
        "observed_container_items": container_items,
        "value": captured,
    }


def _private_highlight_evidence(
    step: PreparedStep,
    record: Mapping[str, Any],
    observation: HighlightObservation | None,
    credential_value: str,
) -> Mapping[str, Any] | None:
    if step.response_key != "phrases" or observation is None:
        return None
    if "highlight" not in record:
        return _freeze_json(
            {
                "status": "missing",
                "raw_shape": observation.raw_shape,
                "utf8_bytes": 0,
            }
        )
    return _freeze_json(
        _bounded_private_highlight(
            record["highlight"],
            raw_shape=observation.raw_shape,
            credential_value=credential_value,
        )
    )


@dataclass(frozen=True, repr=False)
class StepResult:
    sequence: int
    action: str
    status: str
    payload_readback_status: str
    publication_status: str | None
    write_status: int
    read_status: int
    record_id_fingerprint: Mapping[str, Any] | None
    continuation_record_id: str | None = field(repr=False)
    verified_record_snapshot: Mapping[str, Any] = field(repr=False)
    bounded_raw_highlight: Mapping[str, Any] | None = field(repr=False)
    verified_fields: tuple[str, ...]
    highlight_observation: HighlightObservation | None

    def __repr__(self) -> str:
        return f"StepResult({self.safe_summary()!r})"

    def safe_summary(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "action": self.action,
            "status": self.status,
            "payload_readback_status": self.payload_readback_status,
            "publication_status": self.publication_status,
            "write_status": self.write_status,
            "read_status": self.read_status,
            "record_id_fingerprint": self.record_id_fingerprint,
            "verified_fields": list(self.verified_fields),
            "highlight_observation": (
                self.highlight_observation.as_dict()
                if self.highlight_observation is not None
                else None
            ),
        }

    def interactive_continuation(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "action": self.action,
            "record_id": self.continuation_record_id,
        }

    def private_persisted_state(self) -> dict[str, Any]:
        document = {
            **self.safe_summary(),
            "continuation_record_id": self.continuation_record_id,
            "verified_record_snapshot": _thaw_json(self.verified_record_snapshot),
            "bounded_raw_highlight": _thaw_json(self.bounded_raw_highlight),
        }
        _assert_no_sensitive_keys(document, "private result")
        return document


@dataclass(frozen=True, repr=False)
class PrivateContinuation:
    record_id: str = field(repr=False)
    action: str
    credential_fingerprint: str
    record_snapshot: Mapping[str, Any] = field(repr=False)

    def __repr__(self) -> str:
        return (
            f"PrivateContinuation(action={self.action!r}, record_id=<private>, "
            f"credential_fingerprint={self.credential_fingerprint!r})"
        )


class PrivateStateStore:
    """Durable, private per-step journal below ignored artifacts/private/."""

    def __init__(self, root: Path = PRIVATE_STATE_ROOT) -> None:
        resolved = root.resolve()
        private_root = PRIVATE_STATE_ROOT.resolve()
        if resolved != private_root and private_root not in resolved.parents:
            raise SafetyError("private state must remain below artifacts/private")
        self.root = resolved

    def _ensure_root(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)

    def _destination(self, sequence: int) -> Path:
        return self.root / f"issue9-step-{sequence}.json"

    def assert_absent(self, sequence: int) -> None:
        destination = self._destination(sequence)
        if os.path.lexists(destination):
            existing_status = "unreadable"
            try:
                existing_status = str(self.read(sequence).get("status", "unknown"))
            except SafetyError:
                pass
            raise SafetyError(
                f"step {sequence} already has private state '{existing_status}'; "
                "do not replay it. Inspect artifacts/private and obtain separate "
                "manual recovery approval."
            )

    def _fsync_root(self) -> None:
        descriptor = os.open(self.root, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def _serialize(self, document: Mapping[str, Any]) -> str:
        _assert_no_sensitive_keys(document, "private state")
        return json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"

    def _create_document(self, sequence: int, document: Mapping[str, Any]) -> Path:
        self._ensure_root()
        destination = self._destination(sequence)
        serialized = self._serialize(document)
        if destination.is_symlink():
            raise SafetyError("private state destination must not be a symlink")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(destination, flags, 0o600)
        except FileExistsError:
            existing_status = "unreadable"
            try:
                existing_status = str(self.read(sequence).get("status", "unknown"))
            except SafetyError:
                pass
            raise SafetyError(
                f"step {sequence} already has private state '{existing_status}'; "
                "do not replay it. Inspect artifacts/private and obtain separate "
                "manual recovery approval."
            ) from None
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(destination, 0o600)
        self._fsync_root()
        return destination

    def _replace_document(self, sequence: int, document: Mapping[str, Any]) -> Path:
        self._ensure_root()
        destination = self._destination(sequence)
        serialized = self._serialize(document)
        if not destination.exists() or destination.is_symlink():
            raise SafetyError("private state transition has no safe existing journal")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".issue9-step-{sequence}-",
            suffix=".tmp",
            dir=self.root,
        )
        temporary = Path(temporary_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(serialized)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, destination)
            os.chmod(destination, 0o600)
            self._fsync_root()
        except Exception:
            raise SafetyError("private state transition could not be persisted") from None
        return destination

    def read(self, sequence: int) -> dict[str, Any]:
        destination = self._destination(sequence)
        if not destination.is_file() or destination.is_symlink():
            raise SafetyError("private state journal is missing or unsafe")
        try:
            parsed = json.loads(destination.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            raise SafetyError("private state journal is unreadable") from None
        if not isinstance(parsed, dict):
            raise SafetyError("private state journal is not an object")
        _assert_no_sensitive_keys(parsed, "private state")
        return parsed

    def begin(
        self,
        step: PreparedStep,
        credential_fingerprint: str,
        *,
        create_baseline: CreateBaseline | None,
    ) -> Path:
        return self._create_document(
            step.sequence,
            step.persisted_state(
                "prepared-not-sent",
                credential_fingerprint,
                create_baseline=(
                    create_baseline.private_state()
                    if create_baseline is not None
                    else None
                ),
                recovery_hint=(
                    "Do not replay this step after interruption. Inspect this private "
                    "journal and obtain separate manual recovery approval."
                ),
            ),
        )

    def _transition(
        self,
        step: PreparedStep,
        credential_fingerprint: str,
        expected_statuses: set[str],
        new_status: str,
        **details: Any,
    ) -> Path:
        current = self.read(step.sequence)
        if current.get("status") not in expected_statuses:
            raise SafetyError("private state transition was attempted from an unsafe status")
        if current.get("credential_fingerprint") != credential_fingerprint:
            raise SafetyError("private state credential fingerprint changed mid-step")
        document = dict(current)
        document.update(status=new_status, **details)
        return self._replace_document(step.sequence, document)

    def mark_unknown(
        self,
        step: PreparedStep,
        credential_fingerprint: str,
        *,
        reason: str,
        write_status: int | None = None,
    ) -> Path:
        return self._transition(
            step,
            credential_fingerprint,
            {"prepared-not-sent"},
            "write-attempted-outcome-unknown",
            reason=reason,
            write_status=write_status,
            recovery_hint=(
                "The write outcome is unknown. Do not retry. Inspect the test account "
                "and this private journal before any separately approved recovery."
            ),
        )

    def mark_write_succeeded(
        self,
        step: PreparedStep,
        credential_fingerprint: str,
        *,
        write_status: int,
        record_id_fingerprint: Mapping[str, Any] | None,
        continuation_record_id: str | None,
    ) -> Path:
        if continuation_record_id is not None:
            _safe_record_id(continuation_record_id, "continuation record id")
        return self._transition(
            step,
            credential_fingerprint,
            {"prepared-not-sent"},
            "write-succeeded-readback-unverified",
            write_status=write_status,
            record_id_fingerprint=record_id_fingerprint,
            continuation_record_id=continuation_record_id,
            recovery_hint=(
                "The POST succeeded but readback is not verified. Do not replay; "
                "inspect the test account before separate manual recovery approval."
            ),
        )

    def preserve_unverified(
        self,
        step: PreparedStep,
        credential_fingerprint: str,
        *,
        reason: str,
        read_status: int | None = None,
    ) -> Path:
        return self._transition(
            step,
            credential_fingerprint,
            {"write-succeeded-readback-unverified"},
            "write-succeeded-readback-unverified",
            reason=reason,
            read_status=read_status,
            recovery_hint=(
                "Readback is unresolved. Do not replay. Compare the test account and "
                "private rollback snapshot before separate manual recovery approval."
            ),
        )

    def mark_verified(
        self,
        step: PreparedStep,
        credential_fingerprint: str,
        result: StepResult,
    ) -> Path:
        return self._transition(
            step,
            credential_fingerprint,
            {"write-succeeded-readback-unverified"},
            "verified",
            continuation_record_id=result.continuation_record_id,
            verified_record_snapshot=_thaw_json(result.verified_record_snapshot),
            result=result.private_persisted_state(),
            read_status=result.read_status,
            recovery_hint=(
                "This step is verified and must not be replayed without separate "
                "manual recovery approval."
            ),
        )

    def load_verified_continuation(self, sequence: int) -> PrivateContinuation:
        state = self.read(sequence)
        if state.get("status") != "verified":
            raise SafetyError("previous phrase step is not verified; continuation blocked")
        record_id = _safe_record_id(
            state.get("continuation_record_id"), "private continuation record id"
        )
        credential_fingerprint = state.get("credential_fingerprint")
        action = state.get("action")
        snapshot = state.get("verified_record_snapshot")
        if not isinstance(credential_fingerprint, str) or not credential_fingerprint:
            raise SafetyError("private continuation credential fingerprint is missing")
        if not isinstance(snapshot, Mapping) or snapshot.get("id") != record_id:
            raise SafetyError("private continuation record snapshot is missing")
        if not isinstance(action, str):
            raise SafetyError("private continuation action is missing")
        return PrivateContinuation(
            record_id=record_id,
            action=action,
            credential_fingerprint=credential_fingerprint,
            record_snapshot=_freeze_json(snapshot),
        )


def prepare_phrase_continuation_step(
    plan: Mapping[str, Any],
    sequence: int,
    *,
    previous_state_store: PrivateStateStore,
    previous_sequence: int,
    credential_fingerprint: str,
) -> PreparedStep:
    """Prepare only the reviewed exact -> inflected -> multiple phrase chain."""

    expected_previous = {
        3: (2, "create_phrase_exact_case"),
        4: (3, "update_phrase_inflected_case"),
    }
    expected = expected_previous.get(sequence)
    if expected is None or previous_sequence != expected[0]:
        raise SafetyError("phrase continuation sequence is outside the reviewed matrix")
    continuation = previous_state_store.load_verified_continuation(previous_sequence)
    if continuation.action != expected[1]:
        raise SafetyError("private continuation action does not match the phrase matrix")
    if continuation.credential_fingerprint != credential_fingerprint:
        raise SafetyError("phrase continuation credential fingerprint changed")
    return prepare_plan_step(
        plan,
        sequence,
        phrase_record_id=continuation.record_id,
        existing_record=_thaw_json(continuation.record_snapshot),
    )


class SingleStepExecutor:
    """A one-shot executor: one instance can attempt at most one write."""

    def __init__(self, transport: Transport) -> None:
        self.transport = transport
        self._attempted = False

    def execute(
        self,
        step: PreparedStep,
        provided_confirmation: str,
        credential: TestAccountCredential,
        gate: ManualAccountGate,
        *,
        state_store: PrivateStateStore | None,
    ) -> StepResult:
        gate.validate(credential)
        if self._attempted:
            raise SafetyError("this executor already attempted its single write step")
        if state_store is None:
            raise SafetyError("every live write requires a private state store")

        if _contains_credential_material(step.payload, credential.token) or (
            step.rollback_snapshot is not None
            and _contains_credential_material(
                step.rollback_snapshot, credential.token
            )
        ):
            raise SafetyError(
                "prepared content contains injected credential material; stop before "
                "preview persistence or any request"
            )

        _validate_prepared_step(step)
        write_request = HttpRequest(
            step.method,
            step.path,
            _thaw_json(step.payload),
        )
        recomputed_confirmation = _confirmation_for(
            step.sequence,
            write_request.method,
            write_request.path,
            write_request.payload,
        )
        if (
            recomputed_confirmation != step.confirmation
            or recomputed_confirmation != provided_confirmation
        ):
            raise ConfirmationError(
                "write confirmation is not bound to the final method/path/payload"
            )

        credential_fingerprint = credential.fingerprint
        state_store.assert_absent(step.sequence)

        _entity_key, _resource, is_update = _response_contract(step.action)
        create_baseline: CreateBaseline | None = None
        if is_update:
            try:
                preflight_response = self.transport.send(
                    HttpRequest("GET", step.readback_path), credential
                )
            except TransportError:
                raise VerificationError(
                    "update preflight failed; no write was sent. Inspect the test "
                    "account and retry only after manual review."
                ) from None
            try:
                _verify_update_preflight(step, preflight_response)
            except (SafetyError, VerificationError) as exc:
                if (
                    step.response_key == "interpretations"
                    and "multiple user interpretations" in str(exc)
                ):
                    raise VerificationError(str(exc)) from None
                raise VerificationError(
                    "update preflight found a stale or identity mismatch; no write "
                    "was sent"
                ) from None
        else:
            try:
                preflight_response = self.transport.send(
                    HttpRequest("GET", step.readback_path), credential
                )
            except TransportError:
                raise VerificationError(
                    "create preflight failed; no write was sent. Inspect the test "
                    "account and prepare the step again after manual review."
                ) from None
            try:
                create_baseline = _verify_create_preflight(
                    step, preflight_response
                )
            except (SafetyError, VerificationError) as exc:
                raise VerificationError(str(exc)) from None
            if _contains_credential_material(
                create_baseline.private_state(), credential.token
            ):
                raise VerificationError(
                    "create baseline contains forbidden credential material; "
                    "no write was sent"
                )

        # Repeat the full validation at the last boundary before journal creation
        # and POST, then rebuild the frozen request from those final values.
        _validate_prepared_step(step)
        write_request = HttpRequest(
            step.method,
            step.path,
            _thaw_json(step.payload),
        )
        final_confirmation = _confirmation_for(
            step.sequence,
            write_request.method,
            write_request.path,
            write_request.payload,
        )
        if (
            final_confirmation != step.confirmation
            or final_confirmation != provided_confirmation
        ):
            raise ConfirmationError(
                "write confirmation changed before the final send boundary"
            )
        state_store.begin(
            step,
            credential_fingerprint,
            create_baseline=create_baseline,
        )

        self._attempted = True
        try:
            write_response = self.transport.send(write_request, credential)
        except TransportError:
            try:
                state_store.mark_unknown(
                    step,
                    credential_fingerprint,
                    reason="write-transport-error",
                )
            except SafetyError:
                raise UnknownOutcomeError(
                    "write outcome is unknown and the private journal could not be "
                    "updated; do not retry and inspect manually"
                ) from None
            raise UnknownOutcomeError(
                "write outcome is unknown; do not retry and stop the run"
            ) from None

        if not 200 <= write_response.status < 300:
            try:
                state_store.mark_unknown(
                    step,
                    credential_fingerprint,
                    reason="write-non-success-status",
                    write_status=write_response.status,
                )
            except SafetyError:
                raise UnknownOutcomeError(
                    "write returned a non-success status and the unknown-outcome "
                    "journal transition failed; do not retry and inspect manually"
                ) from None
            raise UnknownOutcomeError(
                "write returned a non-success status but its outcome is treated as "
                "unknown; do not retry and inspect manually"
            )

        written_id_error: VerificationError | None = None
        try:
            written_id = _extract_written_id(step, write_response)
        except VerificationError as exc:
            written_id = None
            written_id_error = exc
        reported_write_id = written_id
        if (
            written_id_error is None
            and create_baseline is not None
            and written_id is not None
            and written_id in set(create_baseline.record_ids)
        ):
            written_id_error = VerificationError(
                "create response id already existed in the preflight baseline"
            )
            written_id = None
        record_id_fingerprint = (
            _fingerprint(reported_write_id) if reported_write_id else None
        )
        try:
            state_store.mark_write_succeeded(
                step,
                credential_fingerprint,
                write_status=write_response.status,
                record_id_fingerprint=record_id_fingerprint,
                continuation_record_id=written_id,
            )
        except SafetyError:
            raise UnknownOutcomeError(
                "write succeeded but the unverified journal transition failed; "
                "do not continue or retry"
            ) from None
        if written_id_error is not None:
            try:
                state_store.preserve_unverified(
                    step,
                    credential_fingerprint,
                    reason="write-response-record-id-invalid",
                )
            except SafetyError:
                raise VerificationError(
                    "write succeeded with an invalid record id and the unresolved "
                    "journal could not be updated; do not replay"
                ) from None
            raise written_id_error
        try:
            read_response = self.transport.send(
                HttpRequest("GET", step.readback_path), credential
            )
        except TransportError:
            try:
                state_store.preserve_unverified(
                    step,
                    credential_fingerprint,
                    reason="readback-transport-error",
                )
            except SafetyError:
                raise VerificationError(
                    "immediate readback failed and the unresolved journal could not "
                    "be updated; do not replay and inspect manually"
                ) from None
            raise VerificationError("immediate readback failed; outcome is unverified") from None
        if not 200 <= read_response.status < 300:
            try:
                state_store.preserve_unverified(
                    step,
                    credential_fingerprint,
                    reason="readback-non-success-status",
                    read_status=read_response.status,
                )
            except SafetyError:
                raise VerificationError(
                    "readback returned a non-success status and the unresolved journal "
                    "could not be updated; do not replay and inspect manually"
                ) from None
            raise VerificationError("immediate readback returned a non-success status")

        try:
            if create_baseline is not None:
                record = _select_create_readback_record(
                    step,
                    read_response,
                    written_id,
                    create_baseline,
                )
            else:
                record = _select_readback_record(step, read_response, written_id)
            expected = _expected_fields(step)
            _verify_fields(expected, record)
            _verify_phrase_publication_status(step, record)
            verified_record_snapshot = _record_snapshot(step, record)
            continuation_record_id = verified_record_snapshot["id"]
            highlight_observation = _observe_highlight(step, record)
            bounded_raw_highlight = _private_highlight_evidence(
                step,
                record,
                highlight_observation,
                credential.token,
            )
        except VerificationError:
            try:
                state_store.preserve_unverified(
                    step,
                    credential_fingerprint,
                    reason="readback-verification-failed",
                    read_status=read_response.status,
                )
            except SafetyError:
                raise VerificationError(
                    "readback verification failed and the unresolved journal could not "
                    "be updated; do not replay and inspect manually"
                ) from None
            raise
        result = StepResult(
            sequence=step.sequence,
            action=step.action,
            status="verified",
            payload_readback_status="verified",
            publication_status=(
                str(record["status"]) if step.response_key == "phrases" else None
            ),
            write_status=write_response.status,
            read_status=read_response.status,
            record_id_fingerprint=_fingerprint(continuation_record_id),
            continuation_record_id=continuation_record_id,
            verified_record_snapshot=_freeze_json(verified_record_snapshot),
            bounded_raw_highlight=bounded_raw_highlight,
            verified_fields=tuple(sorted(_snapshot_fields(step))),
            highlight_observation=highlight_observation,
        )
        try:
            state_store.mark_verified(step, credential_fingerprint, result)
        except SafetyError:
            raise VerificationError(
                "readback matched but verified state could not be persisted; "
                "the step remains unresolved and must not be replayed"
            ) from None
        return result


CLI_PROGRAM_NAME = "issue9_live_harness.py"
SANITIZED_ARGV_ERROR = (
    "command line arguments were rejected; the rejected argument names and "
    "values are deliberately not echoed. This CLI never accepts a Token on "
    "the command line: enter it only at the hidden interactive prompt."
)


class SanitizedArgumentParser(argparse.ArgumentParser):
    """Argument parser whose failures never echo user-supplied argv values.

    ``argparse`` normally interpolates the offending argument into its error
    text, so a mistaken ``--token <secret>`` would be written to stderr. Every
    argparse failure path funnels through :meth:`error`, so discarding the
    generated message there contains any secret before it can be printed.
    """

    def error(self, message: str) -> NoReturn:
        del message  # server- or operator-supplied text is never echoed
        self.fail_closed(SANITIZED_ARGV_ERROR)

    def fail_closed(self, reason: str) -> NoReturn:
        """Exit with a fixed, project-owned reason and the static usage text."""
        self.print_usage(sys.stderr)
        sys.stderr.write(f"{self.prog}: error: {reason}\n")
        raise SystemExit(2)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = SanitizedArgumentParser(
        prog=CLI_PROGRAM_NAME,
        description="Issue #9 fail-closed smoke harness",
    )
    parser.add_argument(
        "--mode",
        choices=("offline-plan", "read-only", "live-step"),
        default="offline-plan",
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_FIXTURE)
    commands = parser.add_subparsers(dest="command")
    read_only = commands.add_parser(
        "read-only-probe",
        help="run the explicitly confirmed secondary-account GET-only probe",
    )
    read_only.add_argument("--word", required=True)
    read_only.add_argument("--account-label", required=True)
    read_only.add_argument(
        "--allow-network",
        action="store_true",
        help="explicitly acknowledge that this command may create the locked transport",
    )
    args = parser.parse_args(argv)
    if args.command is not None and args.mode != "offline-plan":
        parser.fail_closed("subcommands cannot be combined with a legacy network mode")
    return args


def _hidden_prompt(prompt: Callable[[str], str], message: str) -> str:
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        return prompt(message)


UNCLASSIFIED_READ_ONLY_FAILURE = ReadOnlyFailureDiagnostic(
    failure_stage="transport-init",
    failure_class="safety",
    http_status=None,
    requests_attempted=0,
    requests_completed=0,
)


def _print_read_only_failure(diagnostic: ReadOnlyFailureDiagnostic) -> None:
    """Print exactly one sanitized diagnostic object and nothing else."""
    if not isinstance(diagnostic, ReadOnlyFailureDiagnostic):
        diagnostic = UNCLASSIFIED_READ_ONLY_FAILURE
    print(
        json.dumps(
            diagnostic.safe_summary(),
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )


def _run_read_only_probe_cli(
    args: argparse.Namespace,
    *,
    token_prompt: Callable[[str], str],
    confirmation_prompt: Callable[[str], str],
    transport_factory: Callable[[], Transport],
    stdin_isatty: Callable[[], bool],
) -> int:
    if not args.allow_network:
        print("BLOCKED: read-only-probe requires the explicit --allow-network flag.")
        return 3
    if args.input != DEFAULT_FIXTURE:
        print("BLOCKED: read-only-probe does not accept an input or config file.")
        return 3
    try:
        account_label = _validate_account_label_shape(args.account_label)
        requested_word = args.word
        _normalize_probe_spelling(requested_word)
    except SafetyError:
        print("BLOCKED: read-only-probe account label or word failed validation.")
        return 3
    if not stdin_isatty():
        print("BLOCKED: read-only-probe requires an interactive terminal; pipes are forbidden.")
        return 3

    try:
        token = _hidden_prompt(
            token_prompt,
            "Secondary/test-account Maimemo Token (hidden): ",
        )
        credential = TestAccountCredential(token, account_label)
        if credential.token in requested_word:
            raise SafetyError("probe word contains forbidden credential material")
        expected_confirmation = _read_only_confirmation_for(
            account_label,
            credential.fingerprint,
            requested_word,
        )
        preview_gate = ReadOnlyProbeGate(
            account_label=account_label,
            credential_fingerprint=credential.fingerprint,
            requested_word=requested_word,
            confirmation=expected_confirmation,
        )
        print("READ-ONLY PROBE — GET ONLY — NO RESPONSE PERSISTENCE")
        preview = preview_gate.safe_summary()
        preview["requested_spelling"] = requested_word
        print(json.dumps(preview, ensure_ascii=False, indent=2, sort_keys=True))
        provided_confirmation = _hidden_prompt(
            confirmation_prompt,
            "Exact read-only confirmation (hidden): ",
        )
        gate = ReadOnlyProbeGate(
            account_label=account_label,
            credential_fingerprint=credential.fingerprint,
            requested_word=requested_word,
            confirmation=provided_confirmation,
        )
        gate.validate(credential)
    except Exception:
        print("BLOCKED: hidden credential or exact confirmation was not accepted.")
        return 3

    try:
        executor = ReadOnlyProbeExecutor(transport_factory())
    except Exception:
        _print_read_only_failure(
            ReadOnlyFailureDiagnostic(
                failure_stage="transport-init",
                failure_class="transport",
                http_status=None,
                requests_attempted=0,
                requests_completed=0,
            )
        )
        return 4
    try:
        result = executor.execute(credential, gate)
    except ReadOnlyProbeFailure as failure:
        _print_read_only_failure(failure.diagnostic)
        return 4
    except Exception:
        # Defensive only: the executor converts every failure into a
        # ReadOnlyProbeFailure, so nothing unclassified should reach this path.
        _print_read_only_failure(UNCLASSIFIED_READ_ONLY_FAILURE)
        return 4
    print(json.dumps(result.safe_summary(), ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def main(
    argv: list[str] | None = None,
    *,
    token_prompt: Callable[[str], str] | None = None,
    confirmation_prompt: Callable[[str], str] | None = None,
    transport_factory: Callable[[], Transport] | None = None,
    stdin_isatty: Callable[[], bool] | None = None,
) -> int:
    args = parse_args(argv)
    if args.command == "read-only-probe":
        return _run_read_only_probe_cli(
            args,
            token_prompt=token_prompt or getpass.getpass,
            confirmation_prompt=confirmation_prompt or getpass.getpass,
            transport_factory=transport_factory or ProductionHttpTransport,
            stdin_isatty=stdin_isatty or sys.stdin.isatty,
        )
    if args.mode != "offline-plan":
        print(
            "BLOCKED: network modes require a separately injected secondary "
            "test-account credential and an explicit manual account gate."
        )
        return 3
    try:
        plan = build_offline_plan(args.input)
    except issue2_smoke.FixtureError as exc:
        print(f"ERROR: {exc}")
        return 2
    print(issue2_smoke.BANNER)
    print(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
