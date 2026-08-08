#!/usr/bin/env python3
"""Issue #32 — small-batch interpretation importer: dry-run and create-only.

This is the first actually useful product workflow: the owner keeps a batch of
roughly 8–15 vocabulary entries whose interpretations are already written, and
this tool removes the repetitive manual entry into Maimemo. It never rewrites,
improves, translates, summarizes or otherwise alters the owner's interpretation
text — the only text transformation is normalizing the document's own newline /
blank-line boundary so the batch can be split into entries at all.

Deliberate non-goals, so this stays a bicycle: no update/replace path, no
phrase/example path, no delete path, no workflow engine, no plugin system, no
service layer, no database, no server, no GUI and no general Maimemo client
library. `scripts/issue9_live_harness.py` remains a frozen spike/safety harness:
every already-reviewed primitive (hidden credential handling, account-label
policy, production transport, ``HttpRequest``, reviewed GET path building, the
observed ``data`` wrappers, vocabulary/collection/record-id/status validation and
the documented create-payload contract) is imported from it rather than copied.

The reviewed network shape is per item, sequential, and structurally capped:

    dry-run  — 2 GETs per item, 0 POSTs;
    create   — 2 preflight GETs per item, then at most 1 POST + 1 readback GET
               per item, with no retry of any kind.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlsplit

_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

import issue9_live_harness as harness  # noqa: E402


MODE_DRY_RUN = "dry-run"
MODE_CREATE = "create"
MODES: tuple[str, ...] = (MODE_DRY_RUN, MODE_CREATE)
OPERATION = "batch-interpretation-create"
CREATE_PATH = f"{harness.OPEN_API_PREFIX}/interpretations"
COLLECTION_KEY = "interpretations"
# Exactly two reviewed GET endpoints. Phrases are outside the set on purpose:
# this tool performs no phrase request of any kind.
READ_PATHS: tuple[str, ...] = (f"{harness.OPEN_API_PREFIX}/vocabulary", CREATE_PATH)
# Tags and status are project-owned and are never accepted from the caller.
TAGS: tuple[str, ...] = ("MBA", "BEC", "GMAT")
STATUS = "PUBLISHED"
# The documented CREATE request keys. Nothing else is ever sent.
BODY_FIELDS: tuple[str, ...] = ("voc_id", "interpretation", "tags", "status")

# One simple Markdown batch format, and only one. No YAML/JSON/CSV/TSV variant.
HEADING_MARKER = "##"
HEADING_PATTERN = re.compile(r"^##[ ](\S.*)$")
MAX_BATCH_ITEMS = 30
TYPICAL_BATCH_ITEMS = (8, 15)
MAX_INTERPRETATION_CHARS = 2_000
MAX_INPUT_BYTES = 262_144

# A batch-specific write confirmation. It shares wording with neither the
# read-only nor the single-write confirmation, so no earlier confirmation string
# can be pasted into this gate.
CONFIRMATION_PREFIX = "CONFIRM BATCH INTERPRETATION CREATE"
BATCH_ONE_POST_CLAUSE = "EXACTLY-ONE-POST-PER-ITEM-NO-RETRY-IMMEDIATE-READBACK"
WRITE_POLICY = "EXACTLY ONE POST PER ITEM / NO RETRY / IMMEDIATE READBACK"
TOKEN_PROMPT = "Secondary/test-account Maimemo Token (hidden): "
CONFIRMATION_PROMPT = "Exact batch CREATE confirmation (hidden): "
PRICING_TERMS_GATE = (
    "Confirm current official pricing/terms permit personal secondary/test-account "
    "use and show no mandatory metered API fee."
)

# Conservative fixed pacing between production requests, so a 15-item batch does
# not arrive as one burst. It is a two-line local mechanism, not a rate limiter,
# and no correctness rule in this module depends on its value: tests inject a
# recording no-op sleep.
#
# The floor is chosen so a full batch stays inside the currently published
# official request windows (20 requests / 10 s, 40 requests / 60 s) without
# relying on network latency: a CREATE item costs at most 4 requests
# (2 preflight GET + 1 POST + 1 readback GET), so a 15-item batch sends 60
# requests. At 1.6 s, 20 intervals span 32 s and 40 intervals span 64 s.
PACING_SECONDS = 1.6

PARSE_REASONS: tuple[str, ...] = (
    "empty-document",
    "content-before-first-heading",
    "malformed-heading",
    "spelling-policy",
    "empty-interpretation",
    "interpretation-policy",
    "duplicate-spelling",
    "batch-too-large",
    "input-unreadable",
)

# The per-item preflight classification. `blocked-error` is the only state that
# also carries a closed transport/http/schema/safety class.
READY_CREATE = "ready-create"
BLOCK_EXISTING = "blocked-existing"
BLOCK_AMBIGUOUS = "blocked-ambiguous"
BLOCK_ERROR = "blocked-error"
PREFLIGHT_STATES: tuple[str, ...] = (
    READY_CREATE,
    BLOCK_EXISTING,
    BLOCK_AMBIGUOUS,
    BLOCK_ERROR,
)

ERROR_CLASSES: tuple[str, ...] = (
    "transport",
    "http-status",
    "schema",
    "safety",
    "ambiguous",
    "mismatch",
    "unknown-write-outcome",
)

# The write-outcome vocabulary is shared with the reviewed one-shot probe.
OUTCOMES: tuple[str, ...] = harness.INTERPRETATION_CREATE_WRITE_OUTCOMES
NOT_ATTEMPTED = harness.WRITE_OUTCOME_NOT_ATTEMPTED
CONFIRMED = harness.WRITE_OUTCOME_CONFIRMED_SUCCESS
RECOVERED = harness.WRITE_OUTCOME_RECOVERED_SUCCESS
NOT_VERIFIED = harness.WRITE_OUTCOME_NOT_VERIFIED
AMBIGUOUS = harness.WRITE_OUTCOME_AMBIGUOUS

RUN_STATUSES: tuple[str, ...] = ("ready", "blocked", "verified", "stopped")

REPORT_PREFIX = "issue32-interpretation-batch"
REPORT_VERSION = 1

BLOCKED_GATE_MESSAGE = (
    "BLOCKED: --allow-network, --mode, the batch file, the account label, the "
    "fixed contract, an interactive terminal or the locked transport was rejected."
)
BLOCKED_CREDENTIAL_MESSAGE = (
    "BLOCKED: the hidden secondary-account credential was not accepted."
)
BLOCKED_INTERNAL_MESSAGE = (
    "BLOCKED: the batch importer stopped safely; only project-owned sanitized "
    "fields are available."
)


def _pinned(allowed: tuple[str, ...], value: Any) -> str:
    """Return the module-owned constant equal to ``value``, selected by identity.

    Returning the constant *object* is what keeps every emitted enum
    project-owned: a server string, an injected transport or an external
    exception can never smuggle its own text out through one of these fields,
    even when that text happens to compare equal.
    """
    if not isinstance(value, str):
        raise harness.SafetyError("value is outside the fixed project enum")
    match = next((item for item in allowed if item == value), None)
    if match is None:
        raise harness.SafetyError("value is outside the fixed project enum")
    return match


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _short_fingerprint(value: str) -> str:
    return harness._fingerprint(value)["sha256"][:16]


def _valid_fingerprint(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{16}", value) is not None


def _plain_count(value: Any, maximum: int) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= maximum
    )


def _account_gate(label: str, fingerprint: str) -> harness.ManualAccountGate:
    return harness.ManualAccountGate(
        allow_network=True,
        account_label=label,
        credential_fingerprint=fingerprint,
        confirmation=f"CONFIRM SECONDARY TEST ACCOUNT: {label} TOKEN-FP: {fingerprint}",
    )


def validate_contract() -> None:
    """Fail closed if the fixed batch-create contract ever drifts."""
    harness._validate_read_only_origin_contract()
    if (
        CREATE_PATH != "/open/api/v1/interpretations"
        or READ_PATHS != ("/open/api/v1/vocabulary", "/open/api/v1/interpretations")
        or TAGS != ("MBA", "BEC", "GMAT")
        or TAGS != harness.REQUIRED_TAGS
        or STATUS != "PUBLISHED"
        or BODY_FIELDS != ("voc_id", "interpretation", "tags", "status")
        or MODES != (MODE_DRY_RUN, MODE_CREATE)
        or MAX_BATCH_ITEMS != 30
        or CONFIRMATION_PREFIX
        in (harness.READ_ONLY_CONFIRMATION_PREFIX, harness.WRITE_CONFIRMATION_PREFIX)
        or "BATCH" not in CONFIRMATION_PREFIX
        or "CREATE" not in CONFIRMATION_PREFIX
    ):
        raise harness.SafetyError("the fixed batch interpretation-create contract changed")


# --------------------------------------------------------------------------- #
# Batch parsing
# --------------------------------------------------------------------------- #


class BatchFormatError(harness.SafetyError):
    """A local batch-document rejection naming one closed project-owned reason.

    The offending spelling, interpretation, line text or file path is never
    interpolated: the owner gets the reason plus a 1-based line number, which is
    enough to find the entry in their own file.
    """

    def __init__(self, reason: str, line: int | None = None) -> None:
        self.reason = _pinned(PARSE_REASONS, reason)
        self.line = line if isinstance(line, int) and not isinstance(line, bool) else None
        super().__init__(self.message)

    @property
    def message(self) -> str:
        location = "" if self.line is None else f" (line {self.line})"
        return f"batch document rejected: {self.reason}{location}"

    def __repr__(self) -> str:
        return f"BatchFormatError({self.reason!r}, line={self.line!r})"

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True)
class BatchEntry:
    """One parsed entry: the owner's spelling and their exact interpretation."""

    ordinal: int
    spelling: str
    normalized_spelling: str
    interpretation: str = field(repr=False)
    line: int = 0

    def __post_init__(self) -> None:
        if not _plain_count(self.ordinal, MAX_BATCH_ITEMS) or self.ordinal < 1:
            raise harness.SafetyError("batch entry ordinal is outside the fixed bound")
        normalized = harness._normalize_probe_spelling(self.spelling)
        if normalized != self.normalized_spelling:
            raise harness.SafetyError("batch entry spelling normalization does not match")
        _validate_interpretation_text(self.interpretation)


def _validate_interpretation_text(value: Any) -> str:
    """Accept the owner's interpretation verbatim, or fail closed.

    This is a validator, never a rewriter: the accepted string is returned
    unchanged. Internal newlines are preserved; every other control character is
    rejected rather than stripped, so nothing invisible is ever silently altered.
    """
    if not isinstance(value, str) or not value.strip():
        raise BatchFormatError("empty-interpretation")
    if len(value) > MAX_INTERPRETATION_CHARS or any(
        (ord(character) < 32 or ord(character) == 127) and character != "\n"
        for character in value
    ):
        raise BatchFormatError("interpretation-policy")
    return value


def parse_batch(document: Any) -> tuple[BatchEntry, ...]:
    """Parse the one supported Markdown batch format into frozen entries.

    The format is exactly::

        ## <spelling>
        <interpretation body until the next ## heading>

    Only the document's own outer boundary is normalized: CRLF/CR line endings
    become LF, and blank lines immediately before/after a body are dropped.
    Everything inside a body — including internal line breaks and indentation —
    is preserved byte for byte.
    """
    validate_contract()
    if not isinstance(document, str):
        raise BatchFormatError("input-unreadable")
    lines = document.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    headings: list[tuple[int, str]] = []
    bodies: list[list[str]] = []
    for index, raw_line in enumerate(lines, start=1):
        stripped = raw_line.rstrip()
        if stripped.startswith("#"):
            match = HEADING_PATTERN.fullmatch(stripped)
            if match is None:
                raise BatchFormatError("malformed-heading", index)
            headings.append((index, match.group(1)))
            bodies.append([])
            if len(headings) > MAX_BATCH_ITEMS:
                raise BatchFormatError("batch-too-large", index)
            continue
        if not headings:
            if raw_line.strip():
                raise BatchFormatError("content-before-first-heading", index)
            continue
        bodies[-1].append(raw_line)
    if not headings:
        raise BatchFormatError("empty-document")

    entries: list[BatchEntry] = []
    seen: dict[str, int] = {}
    for ordinal, ((line, spelling), body_lines) in enumerate(
        zip(headings, bodies), start=1
    ):
        try:
            normalized = harness._normalize_probe_spelling(spelling)
        except harness.SafetyError:
            raise BatchFormatError("spelling-policy", line) from None
        if normalized in seen:
            raise BatchFormatError("duplicate-spelling", line)
        seen[normalized] = line
        body = list(body_lines)
        while body and not body[0].strip():
            body.pop(0)
        while body and not body[-1].strip():
            body.pop()
        interpretation = "\n".join(body)
        if not interpretation.strip():
            raise BatchFormatError("empty-interpretation", line)
        try:
            _validate_interpretation_text(interpretation)
        except BatchFormatError as rejected:
            raise BatchFormatError(rejected.reason, line) from None
        entries.append(
            BatchEntry(
                ordinal=ordinal,
                spelling=spelling,
                normalized_spelling=normalized,
                interpretation=interpretation,
                line=line,
            )
        )
    return tuple(entries)


def load_batch(path: Any) -> tuple[BatchEntry, ...]:
    """Read one small UTF-8 batch file and parse it. Never follows a directory."""
    try:
        resolved = Path(path)
        if resolved.is_dir() or resolved.stat().st_size > MAX_INPUT_BYTES:
            raise BatchFormatError("input-unreadable")
        document = resolved.read_text(encoding="utf-8")
    except BatchFormatError:
        raise
    except Exception:
        # The rejected path is never echoed: it can name private directories.
        raise BatchFormatError("input-unreadable") from None
    return parse_batch(document)


def batch_digest(entries: Sequence[BatchEntry]) -> str:
    """The ordered, id-free digest of the whole intended batch.

    It is stable across runs, safe to show and safe to persist, and it changes if
    any spelling, any interpretation, the order, the item count, the tags, the
    status, the host or the write path changes.
    """
    validate_contract()
    return _digest(
        {
            "operation": OPERATION,
            "host": harness.PRODUCTION_BASE_URL,
            "method": "POST",
            "path": CREATE_PATH,
            "tags": list(TAGS),
            "status": STATUS,
            "item_count": len(entries),
            "items": [
                {
                    "ordinal": entry.ordinal,
                    "spelling": entry.spelling,
                    "interpretation": entry.interpretation,
                }
                for entry in entries
            ],
        }
    )


# --------------------------------------------------------------------------- #
# The single documented CREATE body
# --------------------------------------------------------------------------- #


def create_body(vocabulary_id: str, interpretation: str) -> dict[str, Any]:
    """Build the one documented CREATE body from project-owned values only."""
    return {
        "interpretation": {
            "voc_id": harness._safe_record_id(vocabulary_id, "target vocabulary id"),
            "interpretation": _validate_interpretation_text(interpretation),
            "tags": list(TAGS),
            "status": STATUS,
        }
    }


def validate_create_body(body: Any, vocabulary_id: str, interpretation: str) -> None:
    """Reject anything that is not exactly the documented per-item payload."""
    if not isinstance(body, Mapping):
        raise harness.SafetyError("interpretation create body must be one reviewed object")
    thawed = harness._thaw_json(body)
    harness._assert_no_sensitive_keys(thawed, "interpretation create body")
    # The reviewed create contract does the structural work: exact top-level key,
    # exact field set, tags exactly MBA/BEC/GMAT, non-empty text, PUBLISHED
    # status, matching voc_id and the reviewed create path.
    harness._validate_operation_payload(
        "create_interpretation", CREATE_PATH, thawed, vocabulary_id
    )
    entity = thawed["interpretation"]
    if set(entity) != set(BODY_FIELDS) or entity["interpretation"] != interpretation:
        raise harness.SafetyError("interpretation create body is not the intended payload")


def verify_record(record: Mapping[str, Any], interpretation: str) -> str:
    """Return the record id only when it matches the intended write exactly.

    Tags are compared as a set-like API field: exactly three, each expected tag
    once, server ordering irrelevant, duplicates and extras rejected.
    """
    try:
        record_id = harness._safe_record_id(record.get("id"), "created interpretation id")
    except harness.SafetyError:
        raise harness.VerificationError("created record id is absent or unsafe") from None
    tags = record.get("tags")
    if (
        record.get("interpretation") != interpretation
        or not isinstance(tags, list)
        or len(tags) != len(TAGS)
        or not harness._tags_equal(list(TAGS), tags)
        or harness._read_only_record_status(record, COLLECTION_KEY) != STATUS
    ):
        raise harness.VerificationError("the readback record does not match the intended write")
    return record_id


# --------------------------------------------------------------------------- #
# The gated transport
# --------------------------------------------------------------------------- #


class _ItemError(harness.SafetyError):
    """One sanitized per-item failure: a closed class plus a numeric status."""

    def __init__(self, error_class: str, http_status: Any = None) -> None:
        super().__init__("a batch item failed safely; only sanitized fields are available")
        self.error_class = _pinned(ERROR_CLASSES, error_class)
        self.http_status = harness._plain_http_status(http_status)

    def __repr__(self) -> str:
        return f"_ItemError({self.error_class!r}, http_status={self.http_status!r})"

    def __str__(self) -> str:
        return "a batch item failed safely; only sanitized fields are available"


class BatchWriteGuard:
    """Structurally cap the run at the reviewed GET budget and one POST per item.

    The POST budget is consumed *before* the delegate is called, so once a POST
    invocation begins a second POST for that item is impossible in this process
    no matter how the first one ends — timeout, reset, TLS failure, malformed
    body, 4xx, 5xx, or an exception raised inside this module's own error
    handling. In dry-run mode ``posts_allowed`` is false and there is no code
    path that can arm or dispatch a POST at all.
    """

    def __init__(
        self,
        delegate: harness.Transport,
        *,
        max_gets: int,
        max_posts: int,
        sleep: Callable[[float], None] | None = None,
    ) -> None:
        validate_contract()
        if not _plain_count(max_gets, 3 * MAX_BATCH_ITEMS) or not _plain_count(
            max_posts, MAX_BATCH_ITEMS
        ):
            raise harness.SafetyError("the request budget is outside the fixed bounds")
        self._delegate = delegate
        self._sleep = sleep if sleep is not None else time.sleep
        self.max_gets = max_gets
        self.max_posts = max_posts
        self.get_count = 0
        self.post_count = 0
        self.posted_ordinals: set[int] = set()
        self._armed_ordinal: int | None = None
        self._armed_ordinals: set[int] = set()
        self._post_allowance = 0
        self._dispatched = False

    @property
    def posts_allowed(self) -> bool:
        return self.max_posts > 0

    def arm(self, ordinal: int) -> None:
        """Grant the single POST budget for exactly one item, exactly once."""
        if not self.posts_allowed:
            raise harness.SafetyError("this run is read-only; no POST can be armed")
        if not _plain_count(ordinal, MAX_BATCH_ITEMS) or ordinal < 1:
            raise harness.SafetyError("the armed item ordinal is outside the fixed bound")
        if ordinal in self._armed_ordinals or self.post_count >= self.max_posts:
            raise harness.SafetyError("this item was already armed or the budget is spent")
        self._armed_ordinals.add(ordinal)
        self._armed_ordinal = ordinal
        self._post_allowance = 1

    def send(
        self, request: harness.HttpRequest, credential: harness.TestAccountCredential
    ) -> harness.HttpResponse:
        validate_contract()
        if not isinstance(request, harness.HttpRequest):
            raise harness.SafetyError("this transport requires one reviewed request")
        if request.method == "GET":
            harness._documented_read_path(request.path)
            if (
                request.payload is not None
                or self.get_count >= self.max_gets
                or urlsplit(request.path).path not in READ_PATHS
            ):
                raise harness.SafetyError("GET is outside the reviewed endpoints or budget")
            self.get_count += 1
        elif request.method == "POST":
            ordinal = self._armed_ordinal
            if (
                request.path != CREATE_PATH
                or not self.posts_allowed
                or self._post_allowance <= 0
                or ordinal is None
                or self.post_count >= self.max_posts
            ):
                raise harness.SafetyError("POST is outside the reviewed path or item budget")
            # Consume first: from here a second POST for this item is impossible.
            self._post_allowance = 0
            self.post_count += 1
            self.posted_ordinals.add(ordinal)
        else:
            raise harness.SafetyError("this importer accepts only reviewed GET and POST")
        # Conservative fixed pacing, applied only between production requests.
        if self._dispatched:
            self._sleep(PACING_SECONDS)
        self._dispatched = True
        return self._delegate.send(request, credential)


def _read(
    guard: BatchWriteGuard,
    request: harness.HttpRequest,
    credential: harness.TestAccountCredential,
) -> tuple[harness.HttpResponse, int]:
    """Dispatch one reviewed GET and classify every failure mode it can have."""
    status: int | None = None
    try:
        response = guard.send(request, credential)
        status = harness._read_only_response_status(response)
        if status is None:
            raise harness.TransportError("no usable response status")
        harness._require_read_success(response)
        return response, status
    except harness.TransportResponseError as rejected:
        status = rejected.http_status
        reason = "transport"
    except harness.SafetyError:
        reason = "safety"
    except Exception:
        reason = "transport"
    if status is not None:
        reason = "schema" if 200 <= status < 300 else "http-status"
    raise _ItemError(reason, status) from None


# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #


@dataclass(frozen=True, repr=False)
class PreflightItem:
    """One item's whole-batch preflight verdict. The raw id never leaves."""

    ordinal: int
    spelling: str
    interpretation: str = field(repr=False)
    state: str = BLOCK_ERROR
    existing_count: int | None = None
    vocabulary_id: str | None = field(default=None, repr=False)
    returned_spelling: str | None = None
    error_class: str | None = None
    http_status: int | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "state", _pinned(PREFLIGHT_STATES, self.state))
        if self.error_class is not None:
            object.__setattr__(
                self, "error_class", _pinned(ERROR_CLASSES, self.error_class)
            )
        if self.vocabulary_id is not None:
            harness._safe_record_id(self.vocabulary_id, "target vocabulary id")
        if (self.state == BLOCK_ERROR) != (self.error_class is not None):
            raise harness.SafetyError("only a preflight error may carry an error class")
        if self.state == READY_CREATE and (
            self.existing_count != 0 or self.vocabulary_id is None
        ):
            raise harness.SafetyError("a ready item requires a resolved zero baseline")

    @property
    def ready(self) -> bool:
        return self.state == READY_CREATE

    @property
    def voc_id_fingerprint(self) -> str | None:
        if self.vocabulary_id is None:
            return None
        return _short_fingerprint(self.vocabulary_id)

    def __repr__(self) -> str:
        return (
            f"PreflightItem(ordinal={self.ordinal!r}, spelling={self.spelling!r}, "
            f"state={self.state!r}, existing_count={self.existing_count!r}, "
            f"voc_id_fingerprint={self.voc_id_fingerprint!r})"
        )


def preflight_item(
    guard: BatchWriteGuard,
    entry: BatchEntry,
    credential: harness.TestAccountCredential,
) -> PreflightItem:
    """GET vocabulary, GET the authenticated collection, classify. Never raises."""
    base = {
        "ordinal": entry.ordinal,
        "spelling": entry.spelling,
        "interpretation": entry.interpretation,
    }
    try:
        request = harness.HttpRequest(
            "GET", harness.build_query_path("vocabulary", {"spelling": entry.spelling})
        )
    except Exception:
        return PreflightItem(**base, state=BLOCK_ERROR, error_class="safety")
    try:
        response, status = _read(guard, request, credential)
    except _ItemError as failure:
        return PreflightItem(
            **base,
            state=BLOCK_ERROR,
            error_class=failure.error_class,
            http_status=failure.http_status,
        )
    try:
        vocabulary_id, returned = harness._validate_probe_vocabulary(
            harness._canonical_probe_vocabulary_body(response.body), entry.spelling
        )
        request = harness.HttpRequest(
            "GET", harness.build_query_path(COLLECTION_KEY, {"voc_id": vocabulary_id})
        )
    except Exception:
        return PreflightItem(
            **base, state=BLOCK_ERROR, error_class="schema", http_status=status
        )
    try:
        response, status = _read(guard, request, credential)
    except _ItemError as failure:
        return PreflightItem(
            **base,
            state=BLOCK_ERROR,
            error_class=failure.error_class,
            http_status=failure.http_status,
            returned_spelling=returned,
        )
    try:
        records = harness._interpretation_create_records(response)
    except Exception:
        return PreflightItem(
            **base,
            state=BLOCK_ERROR,
            error_class="schema",
            http_status=status,
            returned_spelling=returned,
        )
    # Exactly the reviewed classification: 0 may be created, 1 needs the
    # out-of-scope update path, and more than 1 is ambiguous. Neither blocked
    # state may fall back to a write or to a different word.
    state = (
        READY_CREATE
        if len(records) == 0
        else BLOCK_EXISTING
        if len(records) == 1
        else BLOCK_AMBIGUOUS
    )
    try:
        return PreflightItem(
            **base,
            state=state,
            existing_count=len(records),
            vocabulary_id=vocabulary_id,
            returned_spelling=returned,
            http_status=status,
        )
    except Exception:
        return PreflightItem(**base, state=BLOCK_ERROR, error_class="safety")


def preflight_batch(
    guard: BatchWriteGuard,
    entries: Sequence[BatchEntry],
    credential: harness.TestAccountCredential,
) -> tuple[PreflightItem, ...]:
    """Preflight the WHOLE batch, in input order, before any write is possible."""
    return tuple(preflight_item(guard, entry, credential) for entry in entries)


# --------------------------------------------------------------------------- #
# The immutable batch plan
# --------------------------------------------------------------------------- #


@dataclass(frozen=True, repr=False)
class PlannedItem:
    """One frozen, fully bound create item. Preview, digest and POST share it."""

    ordinal: int
    spelling: str
    returned_spelling: str
    vocabulary_id: str = field(repr=False)
    interpretation: str = field(repr=False)
    request_body: Mapping[str, Any] = field(repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "request_body", harness._freeze_json(self.request_body))
        self.revalidate()

    def revalidate(self) -> None:
        validate_contract()
        harness._safe_record_id(self.vocabulary_id, "target vocabulary id")
        if not _plain_count(self.ordinal, MAX_BATCH_ITEMS) or self.ordinal < 1:
            raise harness.SafetyError("planned item ordinal is outside the fixed bound")
        normalize = harness._normalize_probe_spelling
        if normalize(self.returned_spelling) != normalize(self.spelling):
            raise harness.SafetyError("returned spelling is not the intended spelling")
        validate_create_body(self.request_body, self.vocabulary_id, self.interpretation)

    @property
    def voc_id_fingerprint(self) -> str:
        return _short_fingerprint(self.vocabulary_id)

    @property
    def readback_path(self) -> str:
        return harness.build_query_path(COLLECTION_KEY, {"voc_id": self.vocabulary_id})

    def write_request(self) -> harness.HttpRequest:
        """Build the single POST from the frozen plan body, never from a copy."""
        self.revalidate()
        return harness.HttpRequest(
            "POST", CREATE_PATH, harness._thaw_json(self.request_body)
        )

    def bound_fields(self) -> dict[str, Any]:
        return {
            "ordinal": self.ordinal,
            "spelling": self.spelling,
            "interpretation": self.interpretation,
            "tags": list(TAGS),
            "status": STATUS,
            "voc_id_fingerprint": self.voc_id_fingerprint,
        }

    def __repr__(self) -> str:
        return (
            f"PlannedItem(ordinal={self.ordinal!r}, spelling={self.spelling!r}, "
            f"voc_id_fingerprint={self.voc_id_fingerprint!r})"
        )


@dataclass(frozen=True, repr=False)
class BatchPlan:
    """One frozen, fully bound batch-create plan behind ONE batch confirmation.

    Fifteen separate confirmations would be worse than useless, so the single
    confirmation digest binds *everything* that could change the outcome:
    operation, production host, write path, account label, Token fingerprint, the
    ordered batch digest, every spelling, every resolved raw ``voc_id``, every
    exact interpretation, the tags, the status, the item count and the
    pricing/terms gate. Mutating any item afterwards changes the digest, so the
    already-entered confirmation no longer matches and the send boundary rejects
    it.
    """

    account_label: str = field(repr=False)
    credential_fingerprint: str
    items: tuple[PlannedItem, ...] = field(repr=False)
    digest: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "items", tuple(self.items))
        self.revalidate()

    def revalidate(self) -> None:
        validate_contract()
        harness._validate_account_label_shape(self.account_label)
        if (
            not _valid_fingerprint(self.credential_fingerprint)
            or not self.items
            or not _plain_count(len(self.items), MAX_BATCH_ITEMS)
            or not re.fullmatch(r"[0-9a-f]{64}", self.digest or "")
        ):
            raise harness.SafetyError("the batch plan violates the fixed write policy")
        ordinals = [item.ordinal for item in self.items]
        if ordinals != list(range(1, len(self.items) + 1)):
            raise harness.SafetyError("the batch plan is not in original input order")
        spellings = [item.spelling for item in self.items]
        if len(set(spellings)) != len(spellings):
            raise harness.SafetyError("the batch plan contains a duplicate spelling")
        for item in self.items:
            item.revalidate()

    @property
    def item_count(self) -> int:
        return len(self.items)

    def bound_fields(self) -> dict[str, Any]:
        """The shared, id-free description behind preview, digest and report."""
        return {
            "operation": OPERATION,
            "mode": MODE_CREATE,
            "host": harness.PRODUCTION_BASE_URL,
            "method": "POST",
            "path": CREATE_PATH,
            "tags": list(TAGS),
            "status": STATUS,
            "item_count": self.item_count,
            "batch_digest": self.digest,
            "credential_fingerprint": self.credential_fingerprint,
            "items": [item.bound_fields() for item in self.items],
        }

    def confirmation_binding(self) -> dict[str, Any]:
        # The raw ids and the account label are bound here but never emitted.
        return dict(
            self.bound_fields(),
            account_label=self.account_label,
            vocabulary_ids=[item.vocabulary_id for item in self.items],
            request_bodies=[harness._thaw_json(item.request_body) for item in self.items],
            write_policy=WRITE_POLICY,
            pricing_and_terms_checked=True,
        )

    @property
    def expected_confirmation(self) -> str:
        self.revalidate()
        digest = _digest(self.confirmation_binding())[:16]
        return (
            f"{CONFIRMATION_PREFIX}: {digest} ITEMS: {self.item_count} "
            f"TOKEN-FP: {self.credential_fingerprint} "
            f"{harness.WRITE_PRICING_TERMS_CLAUSE} {BATCH_ONE_POST_CLAUSE}"
        )

    def validate(self, credential: harness.TestAccountCredential) -> None:
        """Rebind the plan to the exact manual secondary-account gate."""
        self.revalidate()
        _account_gate(self.account_label, self.credential_fingerprint).validate(credential)
        for item in self.items:
            if credential.token in (
                item.spelling,
                item.interpretation,
                item.vocabulary_id,
                item.returned_spelling,
            ) or harness._contains_credential_material(
                harness._thaw_json(item.request_body), credential.token
            ):
                raise harness.SafetyError("the batch plan contains forbidden credential material")

    def validate_confirmation(self, provided: Any) -> None:
        if not isinstance(provided, str) or provided != self.expected_confirmation:
            raise harness.ConfirmationError("batch write confirmation does not match exactly")

    def __repr__(self) -> str:
        return (
            f"BatchPlan(item_count={self.item_count!r}, digest={self.digest!r}, "
            f"credential_fingerprint={self.credential_fingerprint!r})"
        )


def build_plan(
    *,
    account_label: str,
    credential_fingerprint: str,
    entries: Sequence[BatchEntry],
    preflight: Sequence[PreflightItem],
) -> BatchPlan:
    """Build the frozen plan. Every item must already be READY_CREATE."""
    if len(entries) != len(preflight) or not entries:
        raise harness.SafetyError("the batch plan requires one preflight verdict per entry")
    items: list[PlannedItem] = []
    for entry, verdict in zip(entries, preflight):
        if (
            not verdict.ready
            or verdict.ordinal != entry.ordinal
            or verdict.spelling != entry.spelling
            or verdict.interpretation != entry.interpretation
            or verdict.vocabulary_id is None
            or verdict.returned_spelling is None
        ):
            raise harness.SafetyError("only a fully ready batch may become a write plan")
        items.append(
            PlannedItem(
                ordinal=entry.ordinal,
                spelling=entry.spelling,
                returned_spelling=verdict.returned_spelling,
                vocabulary_id=verdict.vocabulary_id,
                interpretation=entry.interpretation,
                request_body=create_body(verdict.vocabulary_id, entry.interpretation),
            )
        )
    return BatchPlan(
        account_label=account_label,
        credential_fingerprint=credential_fingerprint,
        items=tuple(items),
        digest=batch_digest(entries),
    )


# --------------------------------------------------------------------------- #
# The write phase
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class ItemOutcome:
    """One item's sanitized write outcome. Only closed fields ever leave."""

    ordinal: int
    spelling: str
    post_attempted: bool = False
    readback_attempted: bool = False
    outcome: str = NOT_ATTEMPTED
    failure_class: str | None = None
    post_http_status: int | None = None
    readback_http_status: int | None = None
    record_fingerprint: str | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "outcome", _pinned(OUTCOMES, self.outcome))
        if self.failure_class is not None:
            object.__setattr__(
                self, "failure_class", _pinned(ERROR_CLASSES, self.failure_class)
            )
        if (self.outcome == NOT_ATTEMPTED) != (not self.post_attempted):
            raise harness.SafetyError("the outcome contradicts whether a POST was attempted")
        if self.verified and (
            self.failure_class is not None
            or not self.readback_attempted
            or not _valid_fingerprint(self.record_fingerprint)
        ):
            raise harness.SafetyError("a verified item requires a clean readback fingerprint")
        if self.record_fingerprint is not None and not _valid_fingerprint(
            self.record_fingerprint
        ):
            raise harness.SafetyError("the record fingerprint is not a project fingerprint")

    @property
    def verified(self) -> bool:
        return self.outcome in (CONFIRMED, RECOVERED)


def _single_post(
    guard: BatchWriteGuard,
    request: harness.HttpRequest,
    credential: harness.TestAccountCredential,
) -> tuple[int | None, bool]:
    """Invoke the POST exactly once and classify its outcome.

    No exception path here — or anywhere downstream — can send a second POST for
    this item: the guard consumed the single per-item budget before delegating.
    """
    try:
        response = guard.send(request, credential)
    except harness.TransportResponseError as rejected:
        return rejected.http_status, True
    except Exception:
        return None, True
    status = harness._read_only_response_status(response)
    if status is None:
        return None, True
    return status, not 200 <= status < 300


def write_item(
    guard: BatchWriteGuard,
    item: PlannedItem,
    credential: harness.TestAccountCredential,
    provided_confirmation: str,
    plan: BatchPlan,
) -> ItemOutcome:
    """Create one item: at most one POST, then exactly one GET-only readback."""
    base = {"ordinal": item.ordinal, "spelling": item.spelling}
    try:
        plan.revalidate()
        if plan.expected_confirmation != provided_confirmation:
            raise harness.ConfirmationError("the confirmation changed before the send boundary")
        guard.arm(item.ordinal)
        request = item.write_request()
        if harness._contains_credential_material(
            harness._thaw_json(request.payload), credential.token
        ):
            raise harness.SafetyError("the request contains forbidden credential material")
    except Exception:
        return ItemOutcome(**base, outcome=NOT_ATTEMPTED, failure_class="safety")

    post_status, uncertain = _single_post(guard, request, credential)
    if item.ordinal not in guard.posted_ordinals:
        # The guard refused to dispatch, so nothing was written and there is
        # nothing to recover: no readback is performed for this item.
        return ItemOutcome(**base, outcome=NOT_ATTEMPTED, failure_class="safety")

    # Exactly one GET-only readback/recovery. This is never a write retry, and it
    # runs identically for a clean 2xx and for an uncertain POST outcome.
    try:
        readback = harness.HttpRequest("GET", item.readback_path)
    except Exception:
        return ItemOutcome(
            **base,
            post_attempted=True,
            outcome=NOT_VERIFIED,
            failure_class="safety",
            post_http_status=post_status,
        )
    partial = dict(
        base, post_attempted=True, readback_attempted=True, post_http_status=post_status
    )
    try:
        response, read_status = _read(guard, readback, credential)
    except _ItemError as failure:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class=failure.error_class,
            readback_http_status=failure.http_status,
        )
    try:
        records = harness._interpretation_create_records(response)
    except Exception:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="schema",
            readback_http_status=read_status,
        )
    if not records:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="unknown-write-outcome",
            readback_http_status=read_status,
        )
    if len(records) > 1:
        return ItemOutcome(
            **partial,
            outcome=AMBIGUOUS,
            failure_class="ambiguous",
            readback_http_status=read_status,
        )
    try:
        record_id = verify_record(records[0], item.interpretation)
    except Exception:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="mismatch",
            readback_http_status=read_status,
        )
    try:
        return ItemOutcome(
            **partial,
            outcome=RECOVERED if uncertain else CONFIRMED,
            readback_http_status=read_status,
            record_fingerprint=_short_fingerprint(record_id),
        )
    except Exception:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="safety",
            readback_http_status=read_status,
        )


def write_batch(
    guard: BatchWriteGuard,
    plan: BatchPlan,
    credential: harness.TestAccountCredential,
    provided_confirmation: str,
) -> tuple[ItemOutcome, ...]:
    """Process items sequentially in the original input order, stopping on failure.

    A runtime failure after earlier items were already verified stops the whole
    remaining batch immediately. Nothing is rolled back, nothing is deleted and
    no later item is attempted; the remaining items are reported as
    ``not-attempted``.
    """
    outcomes: list[ItemOutcome] = []
    stopped = False
    for item in plan.items:
        if stopped:
            outcomes.append(ItemOutcome(ordinal=item.ordinal, spelling=item.spelling))
            continue
        outcome = write_item(guard, item, credential, provided_confirmation, plan)
        outcomes.append(outcome)
        if not outcome.verified:
            stopped = True
    return tuple(outcomes)


# --------------------------------------------------------------------------- #
# The run
# --------------------------------------------------------------------------- #


@dataclass(frozen=True, repr=False)
class BatchResult:
    """The whole sanitized run outcome. No raw id or credential is reachable."""

    mode: str
    status: str
    digest: str
    preflight: tuple[PreflightItem, ...] = field(repr=False)
    outcomes: tuple[ItemOutcome, ...] = field(repr=False)
    get_count: int = 0
    post_count: int = 0
    report_path: Path | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "mode", _pinned(MODES, self.mode))
        object.__setattr__(self, "status", _pinned(RUN_STATUSES, self.status))
        if self.mode == MODE_DRY_RUN and (self.post_count or self.outcomes):
            raise harness.SafetyError("a dry-run can never carry a write outcome")

    @property
    def item_count(self) -> int:
        return len(self.preflight)

    @property
    def ready_count(self) -> int:
        return sum(1 for item in self.preflight if item.ready)

    @property
    def blocked_count(self) -> int:
        return self.item_count - self.ready_count

    @property
    def verified_count(self) -> int:
        return sum(1 for item in self.outcomes if item.verified)

    @property
    def not_attempted_count(self) -> int:
        return sum(1 for item in self.outcomes if not item.post_attempted)

    @property
    def stopped_on(self) -> ItemOutcome | None:
        """The first item that failed. Later items are merely not attempted."""
        return next(
            (
                item
                for item in self.outcomes
                if not item.verified
                and (item.post_attempted or item.failure_class is not None)
            ),
            None,
        )

    def __repr__(self) -> str:
        return (
            f"BatchResult(mode={self.mode!r}, status={self.status!r}, "
            f"items={self.item_count!r}, ready={self.ready_count!r}, "
            f"verified={self.verified_count!r}, posts={self.post_count!r})"
        )


def run_batch(
    *,
    mode: str,
    entries: Sequence[BatchEntry],
    transport: harness.Transport,
    credential: harness.TestAccountCredential,
    account_label: str,
    confirm: Callable[[BatchPlan], str] | None = None,
    emit: Callable[[str], None] | None = None,
    sleep: Callable[[float], None] | None = None,
    report: "BatchRunReport | None" = None,
    now: Callable[[], datetime] | None = None,
) -> BatchResult:
    """Run one dry-run or one create batch. Both preflight the WHOLE batch first."""
    validate_contract()
    chosen = _pinned(MODES, mode)
    if not entries or len(entries) > MAX_BATCH_ITEMS:
        raise harness.SafetyError("the batch size is outside the fixed bounds")
    label = harness._validate_account_label_shape(account_label)
    _account_gate(label, credential.fingerprint).validate(credential)
    write = emit if emit is not None else _print_line
    digest = batch_digest(entries)
    guard = BatchWriteGuard(
        transport,
        max_gets=(3 if chosen == MODE_CREATE else 2) * len(entries),
        max_posts=len(entries) if chosen == MODE_CREATE else 0,
        sleep=sleep,
    )

    preflight = preflight_batch(guard, entries, credential)
    for line in preview_lines(chosen, digest, credential.fingerprint, preflight):
        write(line)

    outcomes: tuple[ItemOutcome, ...] = ()
    if chosen == MODE_DRY_RUN or any(not item.ready for item in preflight):
        status = "ready" if all(item.ready for item in preflight) else "blocked"
        if chosen == MODE_CREATE and status == "blocked":
            write(
                "ABORTED BEFORE THE FIRST POST: the whole batch is blocked because at "
                "least one item is not ready to create."
            )
        return _finish(
            mode=chosen,
            status=status,
            digest=digest,
            preflight=preflight,
            outcomes=outcomes,
            guard=guard,
            emit=write,
            report=report,
            now=now,
        )

    plan = build_plan(
        account_label=label,
        credential_fingerprint=credential.fingerprint,
        entries=entries,
        preflight=preflight,
    )
    plan.validate(credential)
    for line in confirmation_lines(plan):
        write(line)
    try:
        provided = confirm(plan) if confirm is not None else ""
        plan.validate_confirmation(provided)
    except Exception:
        write(
            "ABORTED BEFORE THE FIRST POST: the batch confirmation did not match "
            "this run's exact string."
        )
        return _finish(
            mode=chosen,
            status="blocked",
            digest=digest,
            preflight=preflight,
            outcomes=outcomes,
            guard=guard,
            emit=write,
            report=report,
            now=now,
        )

    outcomes = write_batch(guard, plan, credential, provided)
    status = "verified" if all(item.verified for item in outcomes) else "stopped"
    return _finish(
        mode=chosen,
        status=status,
        digest=digest,
        preflight=preflight,
        outcomes=outcomes,
        guard=guard,
        emit=write,
        report=report,
        now=now,
    )


def _finish(
    *,
    mode: str,
    status: str,
    digest: str,
    preflight: tuple[PreflightItem, ...],
    outcomes: tuple[ItemOutcome, ...],
    guard: BatchWriteGuard,
    emit: Callable[[str], None],
    report: "BatchRunReport | None",
    now: Callable[[], datetime] | None,
) -> BatchResult:
    result = BatchResult(
        mode=mode,
        status=status,
        digest=digest,
        preflight=preflight,
        outcomes=outcomes,
        get_count=guard.get_count,
        post_count=guard.post_count,
    )
    path: Path | None = None
    if report is not None:
        try:
            path = report.write(report_document(result, now=now))
        except Exception:
            # A report failure never changes what happened on the server and never
            # authorizes another POST; it is reported and the run still returns.
            emit("NOTE: the local sanitized run report could not be written.")
    for line in result_lines(result, path):
        emit(line)
    return BatchResult(
        mode=result.mode,
        status=result.status,
        digest=result.digest,
        preflight=result.preflight,
        outcomes=result.outcomes,
        get_count=result.get_count,
        post_count=result.post_count,
        report_path=path,
    )


# --------------------------------------------------------------------------- #
# Owner-readable output
# --------------------------------------------------------------------------- #


def _print_line(line: str) -> None:
    print(line)


def _indented(text: str, prefix: str = "      ") -> list[str]:
    """Render the owner's interpretation for the terminal, preserving its breaks."""
    return [f"{prefix}{line}" for line in text.split("\n")]


_STATE_LABELS: Mapping[str, str] = {
    READY_CREATE: "READY_CREATE",
    BLOCK_EXISTING: "BLOCK_EXISTING",
    BLOCK_AMBIGUOUS: "BLOCK_AMBIGUOUS",
    BLOCK_ERROR: "BLOCK_ERROR",
}


def preview_lines(
    mode: str,
    digest: str,
    credential_fingerprint: str,
    preflight: Sequence[PreflightItem],
) -> list[str]:
    """The complete owner-readable batch preview. No raw voc_id, ever."""
    ready = sum(1 for item in preflight if item.ready)
    lines = [
        f"BATCH INTERPRETATION IMPORTER — mode {_pinned(MODES, mode)}",
        f"host {harness.PRODUCTION_BASE_URL}   path {CREATE_PATH}",
        "account [REDACTED] (secondary/test label accepted)   "
        f"token fp {credential_fingerprint}",
        f"tags {' '.join(TAGS)}   status {STATUS}   items {len(preflight)}"
        f" (typical {TYPICAL_BATCH_ITEMS[0]}–{TYPICAL_BATCH_ITEMS[1]}, max {MAX_BATCH_ITEMS})",
        f"batch digest {digest}",
        f"write policy {WRITE_POLICY}",
        "",
    ]
    for item in preflight:
        detail = _STATE_LABELS[item.state]
        if item.state == BLOCK_ERROR:
            detail = f"{detail} ({item.error_class}"
            detail += f", http {item.http_status})" if item.http_status else ")"
        elif item.existing_count:
            detail = f"{detail} (existing custom interpretations: {item.existing_count})"
        lines.append(f"{item.ordinal:>3}  {item.spelling}  —  {detail}")
        lines.extend(_indented(item.interpretation))
        if item.voc_id_fingerprint is not None:
            lines.append(f"      voc fp {item.voc_id_fingerprint}")
        lines.append("")
    lines.append(f"READY {ready}")
    lines.append(f"BLOCKED {len(preflight) - ready}")
    if mode == MODE_DRY_RUN:
        lines.append("WRITES 0")
    return lines


def confirmation_lines(plan: BatchPlan) -> list[str]:
    """The ONE batch-level confirmation block shown before any write."""
    return [
        f"CREATE CONFIRMATION — {plan.item_count} items, one POST each, no retry",
        f"batch digest {plan.digest}",
        f"MANUAL GATE: {PRICING_TERMS_GATE}",
        "Copy this run's confirmation exactly into the hidden prompt:",
        f"  {plan.expected_confirmation}",
        "",
    ]


def result_lines(result: BatchResult, report_path: Path | None = None) -> list[str]:
    """The short, obvious owner-facing verdict."""
    lines: list[str] = []
    if result.mode == MODE_CREATE and result.status not in ("verified", "stopped"):
        lines.append("WRITES 0")
    elif result.mode == MODE_CREATE:
        lines.append(f"VERIFIED {result.verified_count}/{result.item_count}")
        stopped = result.stopped_on
        if stopped is not None:
            lines.append(f"STOPPED ON {stopped.ordinal}: {stopped.spelling}")
            lines.append(
                f"  outcome {stopped.outcome}"
                + (f" / {stopped.failure_class}" if stopped.failure_class else "")
            )
            lines.append(
                f"REMAINING NOT ATTEMPTED {result.item_count - stopped.ordinal}"
            )
            lines.append(
                "Nothing was rolled back or deleted. Do not re-POST any item; a rerun "
                "will block the already-created items during preflight."
            )
    lines.append(
        f"requests: GET {result.get_count}  POST {result.post_count}  retries 0"
    )
    if report_path is not None:
        lines.append(f"local sanitized report: {report_path}")
    return lines


# --------------------------------------------------------------------------- #
# The small local sanitized run report
# --------------------------------------------------------------------------- #


def report_document(
    result: BatchResult, *, now: Callable[[], datetime] | None = None
) -> dict[str, Any]:
    """Build the small sanitized report. Fingerprints only — never a raw id."""
    validate_contract()
    clock = now if now is not None else (lambda: datetime.now(timezone.utc))
    outcomes = {item.ordinal: item for item in result.outcomes}
    items: list[dict[str, Any]] = []
    for verdict in result.preflight:
        outcome = outcomes.get(verdict.ordinal)
        items.append(
            {
                "ordinal": verdict.ordinal,
                "spelling": verdict.spelling,
                "interpretation": verdict.interpretation,
                "tags": list(TAGS),
                "status": STATUS,
                "preflight": verdict.state,
                "preflight_error_class": verdict.error_class,
                "preflight_http_status": verdict.http_status,
                "existing_count": verdict.existing_count,
                "voc_id_fingerprint": verdict.voc_id_fingerprint,
                "post_attempted": bool(outcome and outcome.post_attempted),
                "readback_attempted": bool(outcome and outcome.readback_attempted),
                "outcome": outcome.outcome if outcome else NOT_ATTEMPTED,
                "failure_class": outcome.failure_class if outcome else None,
                "post_http_status": outcome.post_http_status if outcome else None,
                "readback_http_status": outcome.readback_http_status if outcome else None,
                "record_fingerprint": outcome.record_fingerprint if outcome else None,
            }
        )
    stopped = result.stopped_on
    document = {
        "version": REPORT_VERSION,
        "operation": OPERATION,
        "mode": result.mode,
        "status": result.status,
        "host": harness.PRODUCTION_BASE_URL,
        "path": CREATE_PATH,
        "created_at": clock().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "batch_digest": result.digest,
        "intended_tags": list(TAGS),
        "intended_status": STATUS,
        "item_count": result.item_count,
        "ready_count": result.ready_count,
        "blocked_count": result.blocked_count,
        "verified_count": result.verified_count,
        "not_attempted_count": (
            result.not_attempted_count if result.outcomes else result.item_count
        ),
        "stopped_on_ordinal": stopped.ordinal if stopped else None,
        "get_count": result.get_count,
        "post_count": result.post_count,
        "retries": 0,
        "rollback": "none; manual review only",
        "items": items,
    }
    harness._assert_no_sensitive_keys(document, "batch run report")
    return document


class BatchRunReport:
    """One small ignored local report below ``artifacts/private/``.

    It is not a replay state machine and not a database: nothing in this module
    ever reads it back to decide whether to write.
    """

    def __init__(self, root: Path = harness.PRIVATE_STATE_ROOT) -> None:
        resolved = Path(root).resolve()
        private_root = harness.PRIVATE_STATE_ROOT.resolve()
        if resolved != private_root and private_root not in resolved.parents:
            raise harness.SafetyError("the run report must remain below artifacts/private")
        self.root = resolved

    def path_for(self, document: Mapping[str, Any]) -> Path:
        mode = _pinned(MODES, document.get("mode"))
        stamp = document.get("created_at")
        digest = document.get("batch_digest")
        if (
            not isinstance(stamp, str)
            or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", stamp) is None
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        ):
            raise harness.SafetyError("the report name fields are outside the fixed policy")
        compact = stamp.replace("-", "").replace(":", "")
        return self.root / f"{REPORT_PREFIX}-{mode}-{compact}-{digest[:16]}.json"

    def write(self, document: Mapping[str, Any]) -> Path:
        """Write the report privately, or fail closed without partial output."""
        harness._assert_no_sensitive_keys(document, "batch run report")
        _assert_no_raw_identifiers(document)
        path = self.path_for(document)
        serialized = (
            json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags, 0o600)
        except OSError:
            raise harness.SafetyError("the run report could not be written safely") from None
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, 0o600)
        return path


_FINGERPRINT_KEYS = frozenset({"voc_id_fingerprint", "record_fingerprint"})
_RAW_ID_KEYS = frozenset({"id", "voc_id", "vocabulary_id", "record_id"})


def _assert_no_raw_identifiers(value: Any, path: str = "report") -> None:
    """Fail closed if a raw vocabulary/record id key ever reaches the report."""
    if isinstance(value, Mapping):
        for raw_key, item in value.items():
            key = str(raw_key)
            if key in _RAW_ID_KEYS:
                raise harness.SafetyError(f"{path} carries a raw identifier field")
            if key in _FINGERPRINT_KEYS and item is not None and not _valid_fingerprint(item):
                raise harness.SafetyError(f"{path} carries a non-fingerprint identifier")
            _assert_no_raw_identifiers(item, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            _assert_no_raw_identifiers(item, f"{path}[{index}]")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


CLI_PROGRAM_NAME = "interpretation_batch_importer.py"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """One command, two modes, no subcommands, and never a Token on argv."""
    parser = harness.SanitizedArgumentParser(
        prog=CLI_PROGRAM_NAME,
        description=(
            "Issue #32 small-batch interpretation importer. Tags and status are "
            "fixed by this project and are never accepted from the command line."
        ),
    )
    parser.add_argument("--mode", choices=MODES, default=MODE_DRY_RUN)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--account-label", required=True)
    parser.add_argument(
        "--allow-network",
        action="store_true",
        help="explicitly acknowledge that this command may create the locked transport",
    )
    return parser.parse_args(argv)


def _cli_confirm(plan: BatchPlan, prompt: Callable[[str], str]) -> str:
    return harness._hidden_prompt(prompt, CONFIRMATION_PROMPT)


def main(
    argv: list[str] | None = None,
    *,
    token_prompt: Callable[[str], str] | None = None,
    confirmation_prompt: Callable[[str], str] | None = None,
    transport_factory: Callable[[], harness.Transport] | None = None,
    stdin_isatty: Callable[[], bool] | None = None,
    report_factory: Callable[[], BatchRunReport] | None = None,
    sleep: Callable[[float], None] | None = None,
    now: Callable[[], datetime] | None = None,
) -> int:
    args = parse_args(argv)
    try:
        validate_contract()
        if not args.allow_network:
            raise harness.SafetyError("network access was not explicitly enabled")
        mode = _pinned(MODES, args.mode)
        account_label = harness._validate_account_label_shape(args.account_label)
        entries = load_batch(args.input)
        if not (stdin_isatty or sys.stdin.isatty)():
            raise harness.SafetyError("an interactive terminal is required")
        report = report_factory() if report_factory is not None else BatchRunReport()
        transport = (transport_factory or harness.ProductionHttpTransport)()
    except BatchFormatError as rejected:
        print(f"BLOCKED: {rejected.message}")
        return 3
    except Exception:
        print(BLOCKED_GATE_MESSAGE)
        return 3
    try:
        credential = harness.TestAccountCredential(
            harness._hidden_prompt(token_prompt or getpass.getpass, TOKEN_PROMPT),
            account_label,
        )
    except Exception:
        print(BLOCKED_CREDENTIAL_MESSAGE)
        return 3
    try:
        result = run_batch(
            mode=mode,
            entries=entries,
            transport=transport,
            credential=credential,
            account_label=account_label,
            confirm=lambda plan: _cli_confirm(
                plan, confirmation_prompt or getpass.getpass
            ),
            sleep=sleep,
            report=report,
            now=now,
        )
    except Exception:
        # Nothing server-provided, nothing external and no credential material can
        # travel out here: only this fixed project-owned sentence is printed.
        print(BLOCKED_INTERNAL_MESSAGE)
        return 4
    if result.status in ("ready", "verified"):
        return 0
    return 3 if result.status == "blocked" else 4


if __name__ == "__main__":
    raise SystemExit(main())
