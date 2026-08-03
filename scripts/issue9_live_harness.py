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
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Mapping, Protocol
from urllib.parse import parse_qsl, urlencode, urlsplit

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
    if ".." in path.split("?", 1)[0].split("/"):
        raise SafetyError("path traversal is forbidden")


def _validate_reviewed_request(method: str, path: str) -> None:
    """Allow only the Issue #2/#9 paths present in the reviewed schema."""

    if method == "GET":
        parsed = urlsplit(path)
        endpoints = {
            f"{OPEN_API_PREFIX}/vocabulary",
            f"{OPEN_API_PREFIX}/vocabulary/query",
            f"{OPEN_API_PREFIX}/interpretations",
            f"{OPEN_API_PREFIX}/phrases",
        }
        if (
            not parsed.scheme
            and not parsed.netloc
            and parsed.path in endpoints
            and parsed.query
            and parse_qsl(parsed.query, keep_blank_values=True)
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
    if resource not in {"vocabulary", "vocabulary/query", "interpretations", "phrases"}:
        raise SafetyError("query resource is not a reviewed endpoint")
    if not params:
        raise SafetyError("documented GET requests require query parameters")
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


def _assert_no_sensitive_keys(value: Any, path: str = "value") -> None:
    if isinstance(value, Mapping):
        for raw_key, item in value.items():
            key = str(raw_key)
            normalized = key.casefold()
            if any(term in normalized for term in ("authorization", "cookie", "token")):
                raise SafetyError(f"{path} contains a forbidden sensitive field")
            _assert_no_sensitive_keys(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _assert_no_sensitive_keys(item, f"{path}[{index}]")


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

    @property
    def fingerprint(self) -> str:
        return hashlib.sha256(self.token.encode("utf-8")).hexdigest()[:16]


@dataclass(frozen=True)
class ManualAccountGate:
    allow_network: bool
    account_label: str
    credential_fingerprint: str
    confirmation: str

    @property
    def expected_confirmation(self) -> str:
        return (
            f"CONFIRM SECONDARY TEST ACCOUNT: {self.account_label} "
            f"TOKEN-FP: {self.credential_fingerprint}"
        )

    def validate(self, credential: TestAccountCredential) -> None:
        if not self.allow_network:
            raise SafetyError("network mode was not explicitly enabled")
        label = self.account_label.strip()
        if not label or credential.account_label != label:
            raise SafetyError("credential label does not match the confirmed account")
        if any(term in label.casefold() for term in ("main", "primary", "owner", "prod")):
            raise SafetyError("main or production account labels are forbidden")
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
    method: str
    path: str
    payload: Mapping[str, Any]
    readback_path: str
    response_key: str
    confirmation: str
    rollback_snapshot: Mapping[str, Any] | None

    def interactive_preview(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "action": self.action,
            "method": self.method,
            "path": self.path,
            "payload": deepcopy(self.payload),
            "existing_record": deepcopy(self.rollback_snapshot),
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
            "version": 2,
            "sequence": self.sequence,
            "action": self.action,
            "status": status,
            "credential_fingerprint": credential_fingerprint,
            "safe_step_summary": self.safe_summary(),
            "rollback_snapshot": deepcopy(self.rollback_snapshot),
            **details,
        }
        _assert_no_sensitive_keys(document)
        return document


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
        required = ("id", "phrase", "interpretation", "tags", "origin")
    else:
        raise SafetyError("update action is outside the reviewed operations")

    missing = [key for key in required if key not in existing_record]
    if missing:
        raise SafetyError(
            f"rollback record is missing required fields: {', '.join(missing)}"
        )
    snapshot = {key: deepcopy(existing_record[key]) for key in required}
    _safe_record_id(snapshot["id"], "rollback record id")
    if not isinstance(snapshot["tags"], list) or not all(
        isinstance(tag, str) for tag in snapshot["tags"]
    ):
        raise SafetyError("rollback record tags must be a string list")
    for key, value in snapshot.items():
        if key not in {"tags"} and not isinstance(value, str):
            raise SafetyError(f"rollback record {key} must be a string")
    _assert_no_sensitive_keys(snapshot, "rollback record")
    return snapshot


def _validate_operation_payload(
    action: str,
    path: str,
    payload: Mapping[str, Any],
) -> None:
    contracts = {
        "create_interpretation": (
            "interpretation",
            {"voc_id", "interpretation", "tags", "status"},
            "/interpretations",
        ),
        "update_interpretation": (
            "interpretation",
            {"interpretation", "tags", "status"},
            "/interpretations/",
        ),
        "create_phrase_exact_case": (
            "phrase",
            {"voc_id", "phrase", "interpretation", "tags", "origin"},
            "/phrases",
        ),
        "update_phrase_inflected_case": (
            "phrase",
            {"phrase", "interpretation", "tags", "origin"},
            "/phrases/",
        ),
        "update_phrase_multiple_case": (
            "phrase",
            {"phrase", "interpretation", "tags", "origin"},
            "/phrases/",
        ),
    }
    contract = contracts.get(action)
    if contract is None:
        raise SafetyError("operation action is outside the reviewed write contract")
    entity_key, expected_fields, expected_path = contract
    if set(payload) != {entity_key}:
        raise SafetyError("write payload top-level keys do not match the reviewed contract")
    entity = payload.get(entity_key)
    if not isinstance(entity, Mapping) or set(entity) != expected_fields:
        raise SafetyError("write payload entity keys do not match the reviewed contract")
    suffix = path.removeprefix(OPEN_API_PREFIX)
    if expected_path.endswith("/"):
        if not suffix.startswith(expected_path):
            raise SafetyError("write action does not match its reviewed update path")
    elif suffix != expected_path:
        raise SafetyError("write action does not match its reviewed create path")


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
        record_id = _safe_record_id(phrase_record_id, "phrase record id")
        path = path.replace(issue2_smoke.CREATED_PHRASE_ID, record_id)

    _validate_api_path(path)
    _validate_reviewed_request(method, path)
    _assert_no_sensitive_keys(payload, "write payload")
    _validate_operation_payload(action, path, payload)
    if action.startswith("update_") and existing_record is None:
        raise SafetyError("update steps require a pre-write record snapshot")
    rollback_snapshot = _normalize_rollback_record(action, existing_record)
    if rollback_snapshot is not None and path.rsplit("/", 1)[-1] != rollback_snapshot["id"]:
        raise SafetyError("rollback record id does not match the update path")
    if "/interpretations" in path:
        readback_path = build_query_path(
            "interpretations", {"voc_id": vocabulary_id}
        )
        response_key = "interpretations"
    elif "/phrases" in path:
        readback_path = build_query_path("phrases", {"voc_id": vocabulary_id})
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
        rollback_snapshot=rollback_snapshot,
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


_READBACK_FIELDS = {
    "create_interpretation": ("interpretation", "tags", "status"),
    "update_interpretation": ("interpretation", "tags", "status"),
    "create_phrase_exact_case": ("phrase", "interpretation", "tags", "origin"),
    "update_phrase_inflected_case": ("phrase", "interpretation", "tags", "origin"),
    "update_phrase_multiple_case": ("phrase", "interpretation", "tags", "origin"),
}


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
    mismatches = [key for key, value in expected.items() if actual.get(key) != value]
    if mismatches:
        raise VerificationError(
            f"readback differs in expected fields: {', '.join(sorted(mismatches))}"
        )


@dataclass(frozen=True)
class HighlightObservation:
    ranges: tuple[tuple[int, int], ...]
    structure_verified: bool = True
    semantic_status: str = "awaiting-owner-app-comparison"

    def as_dict(self) -> dict[str, Any]:
        return {
            "ranges": [
                {"start": start, "end": end} for start, end in self.ranges
            ],
            "structure_verified": self.structure_verified,
            "semantic_status": self.semantic_status,
        }


def _observe_highlight(
    step: PreparedStep,
    actual: Mapping[str, Any],
) -> HighlightObservation | None:
    if step.response_key != "phrases":
        return None
    raw = actual.get("highlight")
    if not isinstance(raw, list) or not raw:
        raise VerificationError("phrase highlight is missing or not a non-empty range list")

    ranges: list[tuple[int, int]] = []
    for index, item in enumerate(raw):
        if not isinstance(item, Mapping):
            raise VerificationError(f"phrase highlight range {index} is not an object")
        start = item.get("start")
        end = item.get("end")
        if (
            not isinstance(start, int)
            or isinstance(start, bool)
            or not isinstance(end, int)
            or isinstance(end, bool)
            or start < 0
            or end < 0
            or start > end
        ):
            raise VerificationError(
                f"phrase highlight range {index} has invalid start/end"
            )
        ranges.append((start, end))
    return HighlightObservation(tuple(ranges))


@dataclass(frozen=True)
class StepResult:
    sequence: int
    action: str
    status: str
    write_status: int
    read_status: int
    record_id_fingerprint: Mapping[str, Any] | None
    verified_fields: tuple[str, ...]
    highlight_observation: HighlightObservation | None

    def safe_summary(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "action": self.action,
            "status": self.status,
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

    def persisted_state(self) -> dict[str, Any]:
        return self.safe_summary()


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

    def begin(self, step: PreparedStep, credential_fingerprint: str) -> Path:
        return self._create_document(
            step.sequence,
            step.persisted_state(
                "prepared-not-sent",
                credential_fingerprint,
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
    ) -> Path:
        return self._transition(
            step,
            credential_fingerprint,
            {"prepared-not-sent"},
            "write-succeeded-readback-unverified",
            write_status=write_status,
            record_id_fingerprint=record_id_fingerprint,
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
            result=result.persisted_state(),
            read_status=result.read_status,
            recovery_hint=(
                "This step is verified and must not be replayed without separate "
                "manual recovery approval."
            ),
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
        if provided_confirmation != step.confirmation:
            raise ConfirmationError("write confirmation does not match exactly")
        if state_store is None:
            raise SafetyError("every live write requires a private state store")

        credential_fingerprint = credential.fingerprint
        state_store.begin(step, credential_fingerprint)

        self._attempted = True
        try:
            write_response = self.transport.send(
                HttpRequest(step.method, step.path, step.payload), credential
            )
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

        written_id = _extract_written_id(step, write_response)
        record_id_fingerprint = _fingerprint(written_id) if written_id else None
        try:
            state_store.mark_write_succeeded(
                step,
                credential_fingerprint,
                write_status=write_response.status,
                record_id_fingerprint=record_id_fingerprint,
            )
        except SafetyError:
            raise UnknownOutcomeError(
                "write succeeded but the unverified journal transition failed; "
                "do not continue or retry"
            ) from None
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
            record = _select_readback_record(step, read_response, written_id)
            expected = _expected_fields(step)
            _verify_fields(expected, record)
            highlight_observation = _observe_highlight(step, record)
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
            write_status=write_response.status,
            read_status=read_response.status,
            record_id_fingerprint=record_id_fingerprint,
            verified_fields=tuple(sorted(expected)),
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
