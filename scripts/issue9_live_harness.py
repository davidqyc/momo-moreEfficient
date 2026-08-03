#!/usr/bin/env python3
"""Fail-closed Issue #9 smoke harness.

The default CLI mode is an offline plan. Live-capable components accept an
injected transport and an injected test-account credential, so tests can prove
the safety contract without reading credentials or opening a network socket.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import http.client
import json
import math
from pathlib import Path
import re
from typing import Any, Mapping, Protocol

import issue2_smoke


PRODUCTION_HOST = "open.maimemo.com"
OPEN_API_PREFIX = issue2_smoke.OPEN_API_PREFIX
DEFAULT_TIMEOUT_SECONDS = 10.0
MAX_RESPONSE_BYTES = 1_048_576
IDENTITY_ENDPOINT_FINDING = "没有找到"
TEST_ACCOUNT_CREDENTIAL_SOURCE = "secondary-test-account"
CONFIRMATION_PREFIX = "CONFIRM WRITE STEP"
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "tests" / "fixtures" / "issue2-smoke-input.example.json"
PRIVATE_STATE_ROOT = ROOT / "artifacts" / "private"


class SafetyError(RuntimeError):
    """A fail-closed safety check rejected the requested action."""


class ConfirmationError(SafetyError):
    """The exact per-step confirmation was absent or incorrect."""


class TransportError(RuntimeError):
    """A transport failed without exposing credentials or response content."""


class UnknownOutcomeError(SafetyError):
    """A write outcome is unknown; the caller must stop and inspect manually."""


class VerificationError(SafetyError):
    """A write or its immediate readback did not verify exactly."""


def _is_finite_positive(value: float) -> bool:
    return math.isfinite(value) and value > 0


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


def _validate_reviewed_request(method: str, path: str) -> None:
    """Allow only the Issue #2/#9 paths present in the reviewed schema."""

    if method == "GET":
        prefixes = (
            f"{OPEN_API_PREFIX}/vocabulary?",
            f"{OPEN_API_PREFIX}/vocabulary/query?",
            f"{OPEN_API_PREFIX}/interpretations?",
            f"{OPEN_API_PREFIX}/phrases?",
        )
        if path.startswith(prefixes):
            return
    elif method == "POST":
        if re.fullmatch(
            rf"{re.escape(OPEN_API_PREFIX)}/(?:interpretations|phrases)(?:/[^/?#]+)?",
            path,
        ):
            return
    raise SafetyError("request path is outside the reviewed Issue #2/#9 endpoints")


def _fingerprint(value: str) -> dict[str, Any]:
    encoded = value.encode("utf-8")
    return {
        "sha256": hashlib.sha256(encoded).hexdigest(),
        "utf8_bytes": len(encoded),
    }


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
    if isinstance(value, list):
        return [redact(item, key=key) for item in value]
    if isinstance(value, str) and normalized_key in _CONTENT_KEYS:
        return {"fingerprint": _fingerprint(value)}
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


@dataclass(frozen=True, repr=False)
class TestAccountCredential:
    """An injected credential. There is deliberately no CLI or file loader."""

    token: str = field(repr=False)
    account_label: str
    source_name: str = TEST_ACCOUNT_CREDENTIAL_SOURCE

    def __post_init__(self) -> None:
        if not self.token:
            raise SafetyError("an injected test-account credential is required")
        if self.source_name != TEST_ACCOUNT_CREDENTIAL_SOURCE:
            raise SafetyError("credential source is not the secondary test-account source")

    def __repr__(self) -> str:
        return "TestAccountCredential(<redacted>)"

    def __str__(self) -> str:
        return "<redacted test-account credential>"


@dataclass(frozen=True)
class ManualAccountGate:
    allow_network: bool
    account_label: str
    confirmation: str

    @property
    def expected_confirmation(self) -> str:
        return f"CONFIRM SECONDARY TEST ACCOUNT: {self.account_label}"

    def validate(self, credential: TestAccountCredential) -> None:
        if not self.allow_network:
            raise SafetyError("network mode was not explicitly enabled")
        label = self.account_label.strip()
        if not label or credential.account_label != label:
            raise SafetyError("credential label does not match the confirmed account")
        if any(term in label.casefold() for term in ("main", "primary", "owner", "prod")):
            raise SafetyError("main or production account labels are forbidden")
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
            payload = json.dumps(request.payload, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"

        try:
            connection.connect()
            if connection.sock is None:
                raise OSError("connection socket unavailable")
            connection.sock.settimeout(
                min(request.timeout_seconds, self.read_timeout_seconds)
            )
            connection.request(request.method, request.path, body=payload, headers=headers)
            response = connection.getresponse()
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES:
                raise OSError("response exceeds safety limit")
            decoded = json.loads(raw.decode("utf-8")) if raw else {}
            if not isinstance(decoded, dict):
                raise OSError("response is not an object")
            return HttpResponse(status=response.status, body=decoded)
        except Exception:
            raise TransportError("request failed; outcome may be unknown") from None
        finally:
            connection.close()


@dataclass(frozen=True)
class ExistingInterpretation:
    record_id: str | None
    text: str
    ownership_confirmed: bool


@dataclass(frozen=True)
class InterpretationDecision:
    operation: Mapping[str, Any]
    existing_snapshot: Mapping[str, Any] | None
    replacement_preview: Mapping[str, Any]


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
            existing_snapshot=None,
            replacement_preview=redact(operation["payload"]),
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
        existing_snapshot={"text": _fingerprint(record.text)},
        replacement_preview=redact(operation["payload"]),
    )


@dataclass(frozen=True)
class PreparedStep:
    sequence: int
    action: str
    method: str
    path: str
    payload: Mapping[str, Any]
    readback_path: str
    response_key: str
    confirmation: str
    pre_update_snapshot: Mapping[str, Any] | None

    def preview(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "action": self.action,
            "method": self.method,
            "path": self.path,
            "payload": redact(self.payload),
            "pre_update_snapshot": self.pre_update_snapshot,
            "required_confirmation": self.confirmation,
        }


def _confirmation_for(
    sequence: int, method: str, path: str, payload: Mapping[str, Any]
) -> str:
    canonical = json.dumps(
        {"method": method, "path": path, "payload": payload},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()[:12]
    return f"{CONFIRMATION_PREFIX} {sequence}: {digest}"


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

    if issue2_smoke.CREATED_PHRASE_ID in path:
        if not phrase_record_id:
            raise SafetyError("phrase update requires the previously captured record id")
        if any(char in phrase_record_id for char in "/?#"):
            raise SafetyError("phrase record id must be one path segment")
        path = path.replace(issue2_smoke.CREATED_PHRASE_ID, phrase_record_id)

    _validate_api_path(path)
    if action.startswith("update_") and existing_record is None:
        raise SafetyError("update steps require a pre-write record snapshot")
    pre_update_snapshot = redact(existing_record) if existing_record is not None else None
    if "/interpretations" in path:
        readback_path = f"{OPEN_API_PREFIX}/interpretations?voc_id={vocabulary_id}"
        response_key = "interpretations"
    elif "/phrases" in path:
        readback_path = f"{OPEN_API_PREFIX}/phrases?voc_id={vocabulary_id}"
        response_key = "phrases"
    else:
        raise SafetyError("write path is outside the reviewed Issue #2 endpoints")
    _validate_api_path(readback_path)

    return PreparedStep(
        sequence=sequence,
        action=action,
        method=method,
        path=path,
        payload=payload,
        readback_path=readback_path,
        response_key=response_key,
        confirmation=_confirmation_for(sequence, method, path, payload),
        pre_update_snapshot=pre_update_snapshot,
    )


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
    allowed = (
        f"{OPEN_API_PREFIX}/vocabulary?",
        f"{OPEN_API_PREFIX}/vocabulary/query?",
        f"{OPEN_API_PREFIX}/interpretations?",
        f"{OPEN_API_PREFIX}/phrases?",
    )
    if not path.startswith(allowed):
        raise SafetyError("read-only mode only permits reviewed documented GET paths")


def run_read_only_probe(
    transport: Transport,
    credential: TestAccountCredential,
    gate: ManualAccountGate,
    path: str,
) -> dict[str, Any]:
    gate.validate(credential)
    _documented_read_path(path)
    try:
        response = transport.send(HttpRequest("GET", path), credential)
    except TransportError:
        raise SafetyError("read-only request failed; stop") from None
    return {"status": response.status, "response_keys": sorted(response.body)}


def _extract_written_id(step: PreparedStep, response: HttpResponse) -> str | None:
    singular = "interpretation" if step.response_key == "interpretations" else "phrase"
    entity = response.body.get(singular)
    if isinstance(entity, Mapping) and isinstance(entity.get("id"), str):
        return entity["id"]
    path_tail = step.path.rsplit("/", 1)[-1]
    if path_tail not in {"interpretations", "phrases"}:
        return path_tail
    return None


def _select_readback_record(
    step: PreparedStep,
    response: HttpResponse,
    written_id: str | None,
) -> Mapping[str, Any]:
    raw_records = response.body.get(step.response_key)
    if not isinstance(raw_records, list):
        raise VerificationError("readback response does not contain the expected list")
    records = [record for record in raw_records if isinstance(record, Mapping)]
    if written_id is not None:
        matches = [record for record in records if record.get("id") == written_id]
    else:
        matches = records
    if len(matches) != 1:
        raise VerificationError("readback record identity is absent or ambiguous")
    return matches[0]


def _expected_fields(step: PreparedStep) -> Mapping[str, Any]:
    key = "interpretation" if step.response_key == "interpretations" else "phrase"
    fields = step.payload.get(key)
    if not isinstance(fields, Mapping):
        raise VerificationError("write payload does not contain the expected entity")
    return fields


def _verify_fields(expected: Mapping[str, Any], actual: Mapping[str, Any]) -> None:
    mismatches = [key for key, value in expected.items() if actual.get(key) != value]
    if mismatches:
        raise VerificationError(
            f"readback differs in expected fields: {', '.join(sorted(mismatches))}"
        )


@dataclass(frozen=True)
class StepResult:
    sequence: int
    action: str
    status: str
    write_status: int
    read_status: int
    record_id_fingerprint: Mapping[str, Any] | None
    verified_fields: tuple[str, ...]
    pre_update_snapshot: Mapping[str, Any] | None

    def as_private_state(self) -> dict[str, Any]:
        return {
            "version": 1,
            "sequence": self.sequence,
            "action": self.action,
            "status": self.status,
            "write_status": self.write_status,
            "read_status": self.read_status,
            "record_id_fingerprint": self.record_id_fingerprint,
            "verified_fields": list(self.verified_fields),
            "pre_update_snapshot": self.pre_update_snapshot,
        }


class PrivateStateStore:
    """Persist only allowlisted, sanitized results below artifacts/private/."""

    def __init__(self, root: Path = PRIVATE_STATE_ROOT) -> None:
        resolved = root.resolve()
        private_root = PRIVATE_STATE_ROOT.resolve()
        if resolved != private_root and private_root not in resolved.parents:
            raise SafetyError("private state must remain below artifacts/private")
        self.root = resolved

    def _write_document(self, sequence: int, document: Mapping[str, Any]) -> Path:
        self.root.mkdir(parents=True, exist_ok=True)
        destination = self.root / f"issue9-step-{sequence}.json"
        if destination.is_symlink():
            raise SafetyError("private state destination must not be a symlink")
        serialized = json.dumps(
            document, ensure_ascii=False, indent=2, sort_keys=True
        )
        lowered = serialized.lower()
        if any(term in lowered for term in ("authorization", "bearer ", "token")):
            raise SafetyError("private state failed the sensitive-key check")
        destination.write_text(serialized + "\n", encoding="utf-8")
        return destination

    def write_pre_update(self, step: PreparedStep) -> Path:
        if step.pre_update_snapshot is None:
            raise SafetyError("update snapshot is missing")
        return self._write_document(
            step.sequence,
            {
                "version": 1,
                "sequence": step.sequence,
                "action": step.action,
                "status": "prepared-not-sent",
                "pre_update_snapshot": step.pre_update_snapshot,
            },
        )

    def write_unknown_outcome(self, step: PreparedStep) -> Path:
        return self._write_document(
            step.sequence,
            {
                "version": 1,
                "sequence": step.sequence,
                "action": step.action,
                "status": "write-attempted-outcome-unknown",
                "pre_update_snapshot": step.pre_update_snapshot,
            },
        )

    def write(self, result: StepResult) -> Path:
        return self._write_document(result.sequence, result.as_private_state())


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
        state_store: PrivateStateStore | None = None,
    ) -> StepResult:
        gate.validate(credential)
        if self._attempted:
            raise SafetyError("this executor already attempted its single write step")
        if provided_confirmation != step.confirmation:
            raise ConfirmationError("write confirmation does not match exactly")
        if step.action.startswith("update_"):
            if state_store is None:
                raise SafetyError("update steps require a private pre-write snapshot store")
            state_store.write_pre_update(step)

        self._attempted = True
        try:
            write_response = self.transport.send(
                HttpRequest(step.method, step.path, step.payload), credential
            )
        except TransportError:
            if state_store is not None:
                try:
                    state_store.write_unknown_outcome(step)
                except SafetyError:
                    raise UnknownOutcomeError(
                        "write outcome is unknown and private state update failed; "
                        "do not retry and stop the run"
                    ) from None
            raise UnknownOutcomeError(
                "write outcome is unknown; do not retry and stop the run"
            ) from None

        if not 200 <= write_response.status < 300:
            raise VerificationError("write returned a non-success status; stop")

        written_id = _extract_written_id(step, write_response)
        try:
            read_response = self.transport.send(
                HttpRequest("GET", step.readback_path), credential
            )
        except TransportError:
            raise VerificationError("immediate readback failed; outcome is unverified") from None
        if not 200 <= read_response.status < 300:
            raise VerificationError("immediate readback returned a non-success status")

        record = _select_readback_record(step, read_response, written_id)
        expected = _expected_fields(step)
        _verify_fields(expected, record)
        result = StepResult(
            sequence=step.sequence,
            action=step.action,
            status="verified",
            write_status=write_response.status,
            read_status=read_response.status,
            record_id_fingerprint=_fingerprint(written_id) if written_id else None,
            verified_fields=tuple(sorted(expected)),
            pre_update_snapshot=step.pre_update_snapshot,
        )
        if state_store is not None:
            state_store.write(result)
        return result


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Issue #9 fail-closed smoke harness")
    parser.add_argument(
        "--mode",
        choices=("offline-plan", "read-only", "live-step"),
        default="offline-plan",
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_FIXTURE)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
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
