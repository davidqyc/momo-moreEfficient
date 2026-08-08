#!/usr/bin/env python3
"""Issue #27 — one-shot secondary-account phrase CREATE probe."""

# A deliberately small, disposable, procedural spike; not a phrase subsystem.
# The written payload is fixed here and is never caller-supplied, the CLI has no
# subcommands, and every already-reviewed primitive (hidden credential handling,
# account-label policy, production transport, HttpRequest, reviewed GET path
# building, the observed `data` wrappers, vocabulary/status/record-id/highlight
# validation) is imported from the frozen `issue9_live_harness` rather than
# copied. The reviewed maximum is 3 GETs + 1 POST, with zero retries.

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import getpass
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Callable, Mapping
from urllib.parse import urlsplit

_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

import issue9_live_harness as harness  # noqa: E402


MODE, OPERATION = "phrase-create-probe", "phrase-create"
CREATE_PATH = f"{harness.OPEN_API_PREFIX}/phrases"
COLLECTION_KEY = "phrases"
READ_PATHS: tuple[str, ...] = (f"{harness.OPEN_API_PREFIX}/vocabulary", CREATE_PATH)
# The fixed, project-owned write target: legitimate dictionary-like business
# English that no caller can modify, which is how the current platform ban on
# meaningless/test content is made unbypassable.
SPELLING = "acquisition"
PHRASE_TEXT = "The acquisition strengthened the company's position in the market."
TRANSLATION = "这次收购加强了公司在市场中的地位。"
TAGS: tuple[str, ...] = ("MBA", "BEC", "GMAT")
ORIGIN, PUBLISHED = "自编", "PUBLISHED"
# The target spelling occurs exactly once, at this half-open English span. It is
# a readback *observation* contract, never a request field.
TARGET_SPAN = (4, 15)
# The documented CREATE request keys. Nothing else is ever sent: no highlight,
# no status, no top-level id, no Chinese-range field, no undocumented key.
BODY_FIELDS: tuple[str, ...] = ("voc_id", "phrase", "interpretation", "tags", "origin")
# A phrase-specific write confirmation sharing wording with neither the read-only
# nor the interpretation-write confirmation, so no earlier confirmation string
# can be pasted into this gate.
CONFIRMATION_PREFIX = "CONFIRM ONE REAL PHRASE WRITE"
WRITE_POLICY = harness.WRITE_POLICY_STATEMENT
TOKEN_PROMPT = "Secondary/test-account Maimemo Token (hidden): "
MAX_GETS, MAX_POSTS = 3, 1
# One write-once marker below the ignored artifacts/private/. Deliberately not a
# journal state machine: it never transitions after creation.
MARKER_NAME = "issue27-phrase-create-armed-1.json"
MARKER_STATEMENT = "the one-shot phrase write was armed; automatic replay is blocked"
STAGES: tuple[str, ...] = (
    "transport-init", "preflight-vocabulary", "preflight-phrases",
    "confirmation", "write", "readback",
)
CLASSES: tuple[str, ...] = (
    "transport", "http-status", "schema", "safety",
    "confirmation", "ambiguous", "mismatch", "unknown-write-outcome",
)
# The write-outcome vocabulary is shared with the reviewed interpretation probe.
OUTCOMES: tuple[str, ...] = harness.INTERPRETATION_CREATE_WRITE_OUTCOMES
NOT_ATTEMPTED = harness.WRITE_OUTCOME_NOT_ATTEMPTED
NOT_VERIFIED = harness.WRITE_OUTCOME_NOT_VERIFIED
AMBIGUOUS, CONFIRMED = harness.WRITE_OUTCOME_AMBIGUOUS, harness.WRITE_OUTCOME_CONFIRMED_SUCCESS
RECOVERED = harness.WRITE_OUTCOME_RECOVERED_SUCCESS
# Closed highlight enums. Malformed, mixed, negative, inverted or out-of-bounds
# structures fail closed as schema; they never become a normal verdict.
SHAPES: tuple[str, ...] = ("integer-pair-array", "object-range-array", "empty-array")
VERDICT_EXACT, VERDICT_EMPTY, VERDICT_OTHER = "exact-target-span", "empty", "other-reviewed-range"
VERDICTS: tuple[str, ...] = (VERDICT_EXACT, VERDICT_EMPTY, VERDICT_OTHER)
FAILURE_MESSAGE = "phrase-create probe stopped safely; only sanitized project fields are available"


def _pinned(allowed: tuple[str, ...], value: Any) -> str:
    """Return the module-owned constant equal to ``value``, selected by identity."""
    if not isinstance(value, str):
        raise harness.SafetyError("value is outside the fixed project enum")
    match = next((item for item in allowed if item == value), None)
    if match is None:
        raise harness.SafetyError("value is outside the fixed project enum")
    return match


def _plain_count(value: Any, maximum: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= maximum


def _valid_fingerprint(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{16}", value) is not None


def _short_fingerprint(value: str) -> str:
    return harness._fingerprint(value)["sha256"][:16]


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _account_gate(label: str, fingerprint: str) -> harness.ManualAccountGate:
    return harness.ManualAccountGate(
        allow_network=True, account_label=label, credential_fingerprint=fingerprint,
        confirmation=f"CONFIRM SECONDARY TEST ACCOUNT: {label} TOKEN-FP: {fingerprint}",
    )


def validate_contract() -> None:
    """Fail closed if the fixed phrase write contract ever drifts."""
    harness._validate_read_only_origin_contract()
    if (
        CREATE_PATH != "/open/api/v1/phrases" or SPELLING != "acquisition"
        or PHRASE_TEXT != "The acquisition strengthened the company's position in the market."
        or TRANSLATION != "这次收购加强了公司在市场中的地位。"
        or TAGS != ("MBA", "BEC", "GMAT") or TAGS != harness.REQUIRED_TAGS or ORIGIN != "自编"
        or PUBLISHED != "PUBLISHED" or TARGET_SPAN != (4, 15) or (MAX_GETS, MAX_POSTS) != (3, 1)
        or PHRASE_TEXT[4:15] != SPELLING or PHRASE_TEXT.count(SPELLING) != 1
        or BODY_FIELDS != ("voc_id", "phrase", "interpretation", "tags", "origin")
        or READ_PATHS != ("/open/api/v1/vocabulary", "/open/api/v1/phrases")
        or CONFIRMATION_PREFIX
        in (harness.READ_ONLY_CONFIRMATION_PREFIX, harness.WRITE_CONFIRMATION_PREFIX)
        or "WRITE" not in CONFIRMATION_PREFIX or "PHRASE" not in CONFIRMATION_PREFIX
    ):
        raise harness.SafetyError("the fixed phrase-create write contract changed")


def fixed_request_body(vocabulary_id: str) -> dict[str, Any]:
    """The single documented CREATE body, built only from project-owned values."""
    return {"phrase": {
        "voc_id": harness._safe_record_id(vocabulary_id, "target vocabulary id"),
        "phrase": PHRASE_TEXT, "interpretation": TRANSLATION,
        "tags": list(TAGS), "origin": ORIGIN,
    }}


def validate_create_body(body: Any, vocabulary_id: str) -> None:
    """Reject anything that is not exactly the documented fixed payload."""
    if not isinstance(body, Mapping) or set(body) != {"phrase"}:
        raise harness.SafetyError("phrase create body must be one reviewed object")
    thawed = harness._thaw_json(body)
    harness._assert_no_sensitive_keys(thawed, "phrase create body")
    entity = thawed["phrase"]
    if not isinstance(entity, Mapping) or set(entity) != set(BODY_FIELDS):
        raise harness.SafetyError("phrase create body carries undocumented fields")
    if (
        entity["voc_id"] != vocabulary_id or entity["phrase"] != PHRASE_TEXT
        or entity["interpretation"] != TRANSLATION or entity["origin"] != ORIGIN
        or not isinstance(entity["tags"], list) or tuple(entity["tags"]) != TAGS
    ):
        raise harness.SafetyError("phrase create body is not the fixed project payload")


# The immutable plan. Preview, confirmation digest, marker document and the POST
# all derive from one recursively frozen `request_body`; there is deliberately no
# second mutable dictionary that could drift between preview and send time. The
# raw `vocabulary_id` is bound into the confirmation digest but never leaves
# through repr, the preview, the marker or the result — those carry only the
# fingerprint.
@dataclass(frozen=True)
class PhraseCreatePlan:
    """One frozen, fully bound phrase-create write plan."""

    account_label: str = field(repr=False)
    credential_fingerprint: str
    returned_spelling: str
    vocabulary_id: str = field(repr=False)
    preflight_phrase_count: int
    request_body: Mapping[str, Any] = field(repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "request_body", harness._freeze_json(self.request_body))
        self.revalidate()

    def revalidate(self) -> None:
        """Recheck every bound value; called again immediately before the POST."""
        validate_contract()
        harness._validate_account_label_shape(self.account_label)
        harness._safe_record_id(self.vocabulary_id, "target vocabulary id")
        if (
            not _valid_fingerprint(self.credential_fingerprint)
            or not isinstance(self.returned_spelling, str)
            or self.preflight_phrase_count != 0
            or not _plain_count(self.preflight_phrase_count, 0)
        ):
            raise harness.SafetyError("the plan violates the fixed zero-baseline write policy")
        normalize = harness._normalize_probe_spelling
        if normalize(self.returned_spelling) != normalize(SPELLING):
            raise harness.SafetyError("returned spelling is not the fixed target spelling")
        validate_create_body(self.request_body, self.vocabulary_id)

    @property
    def voc_id_fingerprint(self) -> str:
        return _short_fingerprint(self.vocabulary_id)

    @property
    def request_body_digest(self) -> str:
        return harness._fingerprint(_canonical(harness._thaw_json(self.request_body)))["sha256"]

    @property
    def readback_path(self) -> str:
        return harness.build_query_path(COLLECTION_KEY, {"voc_id": self.vocabulary_id})

    def write_request(self) -> harness.HttpRequest:
        """Build the single POST from the frozen plan body, never from a copy."""
        self.revalidate()
        return harness.HttpRequest("POST", CREATE_PATH, harness._thaw_json(self.request_body))

    def bound_fields(self) -> dict[str, Any]:
        """The shared, id-free description behind preview, digest and marker."""
        return {
            "operation": OPERATION, "host": harness.PRODUCTION_BASE_URL, "method": "POST",
            "path": CREATE_PATH, "requested_spelling": SPELLING, "phrase": PHRASE_TEXT,
            "interpretation": TRANSLATION, "tags": list(TAGS), "origin": ORIGIN,
            "preflight_phrase_count": self.preflight_phrase_count,
            "voc_id_fingerprint": self.voc_id_fingerprint,
            "credential_fingerprint": self.credential_fingerprint,
            "request_body_digest": self.request_body_digest,
        }

    def confirmation_binding(self) -> dict[str, Any]:
        # The raw id and the account label are bound here but never emitted.
        return dict(self.bound_fields(), account_label=self.account_label,
                    vocabulary_id=self.vocabulary_id, pricing_and_terms_checked=True)

    @property
    def expected_confirmation(self) -> str:
        self.revalidate()
        digest = harness._fingerprint(_canonical(self.confirmation_binding()))["sha256"][:16]
        return (
            f"{CONFIRMATION_PREFIX}: {digest} TOKEN-FP: {self.credential_fingerprint} "
            f"{harness.WRITE_PRICING_TERMS_CLAUSE} {harness.WRITE_ONE_POST_CLAUSE}"
        )

    def safe_preview(self) -> dict[str, Any]:
        """Owner-readable WRITE preview. No raw id, token or server content."""
        return dict(
            self.bound_fields(), mode=MODE, write=True, account_label="[REDACTED]",
            returned_spelling=self.returned_spelling, write_policy=WRITE_POLICY,
            request_body_fields=list(BODY_FIELDS),
            omitted_request_fields=["highlight", "status", "id"],
            maximum_requests={"get": MAX_GETS, "post": MAX_POSTS, "retries": 0},
            required_confirmation=self.expected_confirmation,
            manual_gate=("Confirm current official pricing/terms permit personal secondary/"
                         "test-account use and show no mandatory metered API fee."),
        )

    def marker_document(self, credential_fingerprint: str) -> dict[str, Any]:
        """The minimal write-once continuity evidence. No raw id or credential."""
        if credential_fingerprint != self.credential_fingerprint:
            raise harness.SafetyError("marker credential fingerprint does not match the plan")
        document = dict(self.bound_fields(), version=1, mode=MODE, armed=True,
                        statement=MARKER_STATEMENT,
                        recovery_hint="Never replay this write; recovery is GET-only.")
        harness._assert_no_sensitive_keys(document, "phrase attempt marker")
        return document

    def validate(self, credential: harness.TestAccountCredential) -> None:
        """Rebind the plan to the exact manual secondary-account gate."""
        self.revalidate()
        _account_gate(self.account_label, self.credential_fingerprint).validate(credential)
        if harness._contains_credential_material(
            harness._thaw_json(self.request_body), credential.token
        ) or credential.token in (self.returned_spelling, self.vocabulary_id):
            raise harness.SafetyError("write plan contains forbidden credential material")

    def validate_confirmation(self, provided: Any) -> None:
        if not isinstance(provided, str) or provided != self.expected_confirmation:
            raise harness.ConfirmationError("phrase write confirmation does not match exactly")


# The write-once replay blocker. It is armed after preflight and the exact
# confirmation, immediately before the single POST, and never transitions
# afterwards. If the process dies between arming and the POST, the conservative
# result is that automatic replay stays blocked and the owner returns to the
# Coordinator.
class PhraseAttemptMarker:
    """One write-once private marker below the ignored artifacts/private/."""

    def __init__(self, root: Path = harness.PRIVATE_STATE_ROOT) -> None:
        resolved, private_root = Path(root).resolve(), harness.PRIVATE_STATE_ROOT.resolve()
        if resolved != private_root and private_root not in resolved.parents:
            raise harness.SafetyError("the marker must remain below artifacts/private")
        self.root = resolved

    @property
    def path(self) -> Path:
        return self.root / MARKER_NAME

    def assert_absent(self) -> None:
        if os.path.lexists(self.path):
            raise harness.SafetyError("an attempt marker exists; do not replay this write")

    def arm(self, document: Mapping[str, Any]) -> Path:
        """Create the marker, or fail closed so that zero POSTs can happen."""
        harness._assert_no_sensitive_keys(document, "phrase attempt marker")
        serialized = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        self.assert_absent()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(self.path, flags, 0o600)
        except OSError:
            raise harness.SafetyError("the attempt marker could not be created safely") from None
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(self.path, 0o600)
        return self.path


# The POST counter is incremented *before* the delegate is called, so once a POST
# invocation begins a second one is impossible in this process no matter how the
# first ends — timeout, reset, TLS failure, malformed body, 4xx, 5xx or an
# exception raised inside the probe's own error handling.
class SinglePhraseWriteGuard:
    """Structurally cap the probe at three reviewed GETs and exactly one POST."""

    def __init__(self, delegate: harness.Transport) -> None:
        validate_contract()
        self._delegate, self.get_count, self.post_count = delegate, 0, 0

    def send(
        self, request: harness.HttpRequest, credential: harness.TestAccountCredential
    ) -> harness.HttpResponse:
        validate_contract()
        if not isinstance(request, harness.HttpRequest):
            raise harness.SafetyError("this transport requires one reviewed request")
        if request.method == "GET":
            harness._documented_read_path(request.path)
            if (request.payload is not None or self.get_count >= MAX_GETS
                    or urlsplit(request.path).path not in READ_PATHS):
                raise harness.SafetyError("GET is outside the reviewed endpoints or budget")
            self.get_count += 1
        elif request.method == "POST":
            if request.path != CREATE_PATH or self.post_count >= MAX_POSTS:
                raise harness.SafetyError("POST is outside the reviewed path or single budget")
            # Count first: from here a second POST is impossible in this process.
            self.post_count += 1
        else:
            raise harness.SafetyError("this probe accepts only reviewed GET and POST")
        return self._delegate.send(request, credential)


# Every attribute below is either a constant chosen by identity from a closed
# enum or a small locally counted integer, so no server text, body, header or
# external exception message can travel out through a failure. `post_count` comes
# from the guard, which counts before dispatching, so it can never under-report a
# POST that did reach the server.
class PhraseCreateFailure(harness.SafetyError):
    """A fail-closed probe failure carrying only closed project-owned fields."""

    def __init__(self, progress: "Progress", stage: str, reason: str,
                 http_status: Any = None, outcome: str | None = None) -> None:
        super().__init__(FAILURE_MESSAGE)
        posts = progress.guard.post_count
        self.failure_stage = _pinned(STAGES, stage)
        self.failure_class = _pinned(CLASSES, reason)
        self.write_outcome = _pinned(
            OUTCOMES, outcome or (NOT_ATTEMPTED if posts == 0 else NOT_VERIFIED))
        if (
            self.write_outcome in (CONFIRMED, RECOVERED)
            or (self.write_outcome == NOT_ATTEMPTED) != (posts == 0)
            or (posts and self.failure_stage not in ("write", "readback"))
            or not _plain_count(posts, MAX_POSTS)
        ):
            raise harness.SafetyError("failure fields violate the fixed write invariants")
        self.http_status = harness._plain_http_status(http_status)
        self.post_count, self.post_attempted = posts, posts >= 1
        self.readback_attempted = progress.readback
        self.requests_attempted, self.requests_completed = progress.attempted, progress.completed

    def safe_summary(self) -> dict[str, Any]:
        return {
            "mode": MODE, "status": "failed", "operation": "create",
            "failure_stage": self.failure_stage, "failure_class": self.failure_class,
            "http_status": self.http_status, "post_attempted": self.post_attempted,
            "post_count": self.post_count, "readback_attempted": self.readback_attempted,
            "write_outcome": self.write_outcome, "requests_attempted": self.requests_attempted,
            "requests_completed": self.requests_completed,
        }

    def detach_external_context(self) -> "PhraseCreateFailure":
        self.__cause__ = self.__context__ = None
        self.__suppress_context__ = True
        return self

    def __repr__(self) -> str:
        return f"PhraseCreateFailure({self.safe_summary()!r})"

    def __str__(self) -> str:
        return FAILURE_MESSAGE


class Progress:
    """Stage, request counters and the guard-owned POST count for one run."""

    def __init__(self, guard: SinglePhraseWriteGuard) -> None:
        self.guard, self.stage = guard, "transport-init"
        self.attempted = self.completed = 0
        self.readback = False

    def enter(self, stage: str) -> None:
        self.stage = _pinned(STAGES[1:], stage)

    def fail(self, reason: str, http_status: Any = None,
             outcome: str | None = None) -> PhraseCreateFailure:
        """Return one sanitized, always-constructible fail-closed object."""
        try:
            return PhraseCreateFailure(self, self.stage, reason, http_status, outcome)
        except Exception:
            # An unclassifiable internal state must still leave as one sanitized
            # object; the POST count still comes from the guard.
            return PhraseCreateFailure(
                self, "write" if self.guard.post_count else "confirmation", "safety")

    def read(self, stage: str, request: harness.HttpRequest,
             credential: harness.TestAccountCredential,
             outcome: str | None = None) -> tuple[harness.HttpResponse, int]:
        """Dispatch one reviewed GET and classify every failure mode."""
        self.enter(stage)
        self.attempted += 1
        status: int | None = None
        try:
            response = self.guard.send(request, credential)
            status = harness._read_only_response_status(response)
            if status is None:
                raise harness.TransportError("no usable response status")
            self.completed += 1
            harness._require_read_success(response)
            return response, status
        except harness.TransportResponseError as rejected:
            status = rejected.http_status
            if status is not None:
                self.completed += 1
            reason = "transport"
        except harness.SafetyError:
            reason = "safety"
        except Exception:
            reason = "transport"
        if status is not None:
            reason = "schema" if 200 <= status < 300 else "http-status"
        raise self.fail(reason, status, outcome) from None


def phrase_records(response: Any) -> list[Mapping[str, Any]]:
    """Strictly validate one authenticated phrases collection response."""
    checked = harness._require_read_success(response)
    canonical = harness._canonical_probe_collection_body(checked.body, COLLECTION_KEY)
    if not isinstance(canonical, Mapping):
        raise harness.SafetyError("phrase collection response is not an object")
    records = canonical.get(COLLECTION_KEY)
    if not isinstance(records, list):
        raise harness.SafetyError("phrase collection is not an array")
    seen: set[str] = set()
    for record in records:
        if not isinstance(record, Mapping):
            raise harness.SafetyError("phrase collection contains a malformed item")
        seen.add(harness._safe_record_id(record.get("id"), "phrase record id"))
        harness._read_only_record_status(record, COLLECTION_KEY)
    if len(seen) != len(records):
        raise harness.SafetyError("phrase collection contains duplicate ids")
    return list(records)


# Tags are compared as a set-like field: exactly three, each expected tag once,
# server ordering irrelevant, duplicates and extras rejected. The id and status
# were already validated by phrase_records().
def verify_phrase_record(record: Mapping[str, Any]) -> str:
    """Return the record id only when it matches the intended write exactly."""
    tags = record.get("tags")
    if (
        record.get("phrase") != PHRASE_TEXT or record.get("interpretation") != TRANSLATION
        or record.get("origin") != ORIGIN or not isinstance(tags, list)
        or harness._read_only_record_status(record, COLLECTION_KEY) != PUBLISHED
        or len(tags) != len(TAGS) or not harness._tags_equal(list(TAGS), tags)
    ):
        raise harness.VerificationError("the readback record does not match the intended write")
    return harness._safe_record_id(record.get("id"), "created phrase id")


# `highlight` is never sent; this is a pure observation of what the authenticated
# readback returned, reported as two closed enums. Anything the reviewed rules
# reject raises, so it fails closed instead of becoming a verdict.
def observe_highlight(record: Mapping[str, Any]) -> tuple[str, str]:
    """Classify the returned ``highlight`` through the reviewed range rules."""
    shape = _pinned(SHAPES, harness._read_only_highlight_shape(
        record.get("highlight"), harness._read_only_phrase_length(record)))
    if shape == "empty-array":
        return shape, VERDICT_EMPTY
    raw = record["highlight"]
    ranges = ([(item["start"], item["end"]) for item in raw] if shape == "object-range-array"
              else [(item[0], item[1]) for item in raw])
    if len(ranges) == 1 and ranges[0] == TARGET_SPAN:
        return shape, VERDICT_EXACT
    return shape, VERDICT_OTHER


def success_summary(plan: "PhraseCreatePlan", progress: Progress, record_id: str,
                    write_status: Any, read_status: int, uncertain: bool,
                    shape: str, verdict: str) -> dict[str, Any]:
    """Build the one compact sanitized success object, or fail closed."""
    validate_contract()
    post_status = harness._plain_http_status(write_status)
    record_fingerprint = _short_fingerprint(record_id)
    if (
        progress.guard.post_count != MAX_POSTS
        or not _valid_fingerprint(plan.voc_id_fingerprint)
        or not _valid_fingerprint(record_fingerprint)
        or not 200 <= (harness._plain_http_status(read_status) or 0) < 300
        or (not uncertain and not 200 <= (post_status or 0) < 300)
    ):
        raise harness.SafetyError("a verified write requires one POST and a 2xx readback")
    return {
        "mode": MODE, "status": "recovered-succeeded" if uncertain else "succeeded",
        "write_outcome": RECOVERED if uncertain else CONFIRMED, "operation": "create",
        "requested_spelling": SPELLING, "preflight_count": plan.preflight_phrase_count,
        "post_write_count": 1, "intended_tags": list(TAGS), "origin": ORIGIN,
        "voc_id_fingerprint": plan.voc_id_fingerprint, "post_http_status": post_status,
        "phrase_record_id_fingerprint": record_fingerprint, "readback_http_status": read_status,
        "post_count": progress.guard.post_count, "readback_attempted": True,
        "requests_attempted": progress.attempted, "requests_completed": progress.completed,
        "highlight_shape": _pinned(SHAPES, shape), "highlight_verdict": _pinned(VERDICTS, verdict),
    }


def run_probe(transport: harness.Transport, credential: harness.TestAccountCredential,
              account_label: str, confirm: Callable[["PhraseCreatePlan"], str],
              marker: PhraseAttemptMarker) -> dict[str, Any]:
    """Run the whole one-shot sequence and contain every failure it can produce."""
    progress = Progress(SinglePhraseWriteGuard(transport))
    try:
        return _sequence(progress, credential, account_label, confirm, marker)
    except PhraseCreateFailure as failure:
        raise failure.detach_external_context() from None
    except Exception:
        contained = progress.fail("safety")
    raise contained.detach_external_context() from None


def _sequence(progress: Progress, credential: harness.TestAccountCredential, account_label: str,
              confirm: Callable[["PhraseCreatePlan"], str],
              marker: PhraseAttemptMarker) -> dict[str, Any]:
    try:
        validate_contract()
        marker.assert_absent()
        label = harness._validate_account_label_shape(account_label)
        _account_gate(label, credential.fingerprint).validate(credential)
        request = harness.HttpRequest(
            "GET", harness.build_query_path("vocabulary", {"spelling": SPELLING}))
    except Exception:
        raise progress.fail("safety") from None

    response, status = progress.read("preflight-vocabulary", request, credential)
    try:
        vocabulary_id, returned = harness._validate_probe_vocabulary(
            harness._canonical_probe_vocabulary_body(response.body), SPELLING)
        request = harness.HttpRequest(
            "GET", harness.build_query_path(COLLECTION_KEY, {"voc_id": vocabulary_id}))
    except Exception:
        raise progress.fail("schema", status) from None

    response, status = progress.read("preflight-phrases", request, credential)
    try:
        records = phrase_records(response)
    except Exception:
        raise progress.fail("schema", status) from None
    # The zero baseline is the whole recovery invariant. One record would require
    # an update, which is out of scope; more than one is ambiguous. Neither may
    # fall back to a write or to another word.
    if len(records) > 1:
        raise progress.fail("ambiguous", status) from None
    if records:
        raise progress.fail("safety") from None

    progress.enter("confirmation")
    try:
        plan = PhraseCreatePlan(
            account_label=account_label, credential_fingerprint=credential.fingerprint,
            returned_spelling=returned, vocabulary_id=vocabulary_id,
            preflight_phrase_count=len(records), request_body=fixed_request_body(vocabulary_id))
        plan.validate(credential)
        if harness._contains_credential_material(plan.safe_preview(), credential.token):
            raise harness.SafetyError("preview contains forbidden credential material")
    except Exception:
        raise progress.fail("safety") from None
    try:
        provided = confirm(plan)
        plan.validate_confirmation(provided)
    except Exception:
        raise progress.fail("confirmation") from None

    progress.enter("write")
    try:
        # Arm the write-once replay blocker. If it already exists, or cannot be
        # created safely, zero POSTs happen. Then recheck the immutable plan and
        # rebuild the request from that same frozen body.
        marker.arm(plan.marker_document(credential.fingerprint))
        plan.revalidate()
        if plan.expected_confirmation != provided:
            raise harness.ConfirmationError("confirmation changed before the send boundary")
        request = plan.write_request()
        if harness._contains_credential_material(
            harness._thaw_json(request.payload), credential.token
        ):
            raise harness.SafetyError("request contains forbidden credential material")
    except harness.ConfirmationError:
        raise progress.fail("confirmation") from None
    except Exception:
        raise progress.fail("safety") from None

    write_status, uncertain = _single_post(progress, request, credential)
    if progress.guard.post_count == 0:
        # The guard refused to dispatch, so nothing was written and there is
        # nothing to recover: no readback is performed.
        raise progress.fail("safety", None, NOT_ATTEMPTED) from None
    return _readback(progress, plan, credential, write_status, uncertain)


def _single_post(progress: Progress, request: harness.HttpRequest,
                 credential: harness.TestAccountCredential) -> tuple[int | None, bool]:
    """Invoke the POST exactly once and classify its outcome."""
    # No exception path here — or anywhere downstream — can send a second POST:
    # the guard consumed the single POST budget before delegating.
    progress.attempted += 1
    try:
        response = progress.guard.send(request, credential)
    except harness.TransportResponseError as rejected:
        if rejected.http_status is not None:
            progress.completed += 1
        return rejected.http_status, True
    except Exception:
        return None, True
    status = harness._read_only_response_status(response)
    if status is None:
        return None, True
    progress.completed += 1
    return status, not 200 <= status < 300


def _readback(progress: Progress, plan: "PhraseCreatePlan",
              credential: harness.TestAccountCredential, write_status: int | None,
              uncertain: bool) -> dict[str, Any]:
    """Perform exactly one GET-only readback. This is never a write retry."""
    progress.enter("readback")
    progress.readback = True
    try:
        request = harness.HttpRequest("GET", plan.readback_path)
    except Exception:
        raise progress.fail("safety", None, NOT_VERIFIED) from None
    response, read_status = progress.read("readback", request, credential, NOT_VERIFIED)
    try:
        records = phrase_records(response)
    except Exception:
        raise progress.fail("schema", read_status, NOT_VERIFIED) from None
    if not records:
        raise progress.fail("unknown-write-outcome", read_status, NOT_VERIFIED) from None
    if len(records) > 1:
        raise progress.fail("ambiguous", read_status, AMBIGUOUS) from None
    try:
        record_id = verify_phrase_record(records[0])
    except Exception:
        raise progress.fail("mismatch", read_status, NOT_VERIFIED) from None
    # Only once the record itself verifies is the returned highlight observed;
    # an unusable highlight is a schema failure, not a verdict.
    try:
        shape, verdict = observe_highlight(records[0])
        summary = success_summary(plan, progress, record_id, write_status, read_status,
                                  uncertain, shape, verdict)
    except Exception:
        raise progress.fail("schema", read_status, NOT_VERIFIED) from None
    if harness._contains_credential_material(summary, credential.token):
        raise progress.fail("safety", None, NOT_VERIFIED) from None
    return summary


CLI_PROGRAM_NAME = "phrase_create_probe.py"
UNCLASSIFIED_SUMMARY = {
    "mode": MODE, "status": "failed", "operation": "create",
    "failure_stage": "transport-init", "failure_class": "safety", "http_status": None,
    "post_attempted": False, "post_count": 0, "readback_attempted": False,
    "write_outcome": NOT_ATTEMPTED, "requests_attempted": 0, "requests_completed": 0,
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """One command, no subcommands, and no caller-supplied content at all."""
    parser = harness.SanitizedArgumentParser(
        prog=CLI_PROGRAM_NAME,
        description="Issue #27 one-shot phrase CREATE probe; content is fixed by this project",
    )
    parser.add_argument("--account-label", required=True)
    parser.add_argument("--allow-network", action="store_true",
                        help="explicitly acknowledge that this command may create the transport")
    return parser.parse_args(argv)


def _print_failure(failure: Any) -> None:
    """Print exactly one sanitized diagnostic object and nothing else."""
    summary = (failure.safe_summary() if isinstance(failure, PhraseCreateFailure)
               else dict(UNCLASSIFIED_SUMMARY))
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))


def _cli_confirm(plan: "PhraseCreatePlan", prompt: Callable[[str], str]) -> str:
    """Show the sanitized WRITE preview, then take the hidden exact confirmation."""
    print(json.dumps(plan.safe_preview(), ensure_ascii=False, indent=2, sort_keys=True))
    return harness._hidden_prompt(prompt, "Exact phrase-create WRITE confirmation (hidden): ")


def main(argv: list[str] | None = None, *, token_prompt: Callable[[str], str] | None = None,
         confirmation_prompt: Callable[[str], str] | None = None,
         transport_factory: Callable[[], harness.Transport] | None = None,
         stdin_isatty: Callable[[], bool] | None = None,
         marker_factory: Callable[[], PhraseAttemptMarker] | None = None) -> int:
    args = parse_args(argv)
    try:
        if not args.allow_network:
            raise harness.SafetyError("network access was not explicitly enabled")
        account_label = harness._validate_account_label_shape(args.account_label)
        validate_contract()
        if not (stdin_isatty or sys.stdin.isatty)():
            raise harness.SafetyError("an interactive terminal is required")
        marker = marker_factory() if marker_factory is not None else PhraseAttemptMarker()
        marker.assert_absent()
        transport = (transport_factory or harness.ProductionHttpTransport)()
    except Exception:
        print("BLOCKED: --allow-network, the account label, the fixed write contract, an "
              "interactive terminal, the locked transport, or the absence of an attempt "
              "marker was rejected.")
        return 3
    try:
        credential = harness.TestAccountCredential(
            harness._hidden_prompt(token_prompt or getpass.getpass, TOKEN_PROMPT), account_label)
    except Exception:
        print("BLOCKED: the hidden secondary-account credential was not accepted.")
        return 3
    print(f"PHRASE CREATE PROBE — WRITE — {WRITE_POLICY}")
    try:
        summary = run_probe(
            transport, credential, account_label,
            lambda plan: _cli_confirm(plan, confirmation_prompt or getpass.getpass), marker)
    except Exception as failure:
        _print_failure(failure)
        return 4
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
