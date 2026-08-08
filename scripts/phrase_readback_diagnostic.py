#!/usr/bin/env python3
"""Issue #30 — GET-only sanitized phrase readback schema diagnostic."""

# Why this exists: the first real phrase CREATE run (Issue #29) reached
# `failure_stage = readback`, `failure_class = schema` on an HTTP 200 readback.
# That is a *local parser* rejection of a complete response, so the next step is
# to learn which checkpoint the response actually fails — without writing again
# and without letting any server content escape.
#
# This is a deliberately small, disposable, procedural diagnostic; not a schema
# inspection framework and not a phrase subsystem. It is structurally read-only:
# the guard accepts exactly one method, the reviewed GET paths come from
# `phrase_create_probe.READ_PATHS`, and no write-method literal exists anywhere
# in this module. It reads at most the two reviewed GETs, with zero retries and
# zero concurrency, and it never consults or modifies the Issue #27 write-once
# marker, because there is nothing here to replay.
#
# Everything it emits is a project-owned closed enum, a bounded local count, a
# boolean or a fingerprint; `_assert_sanitized` re-checks that field by field
# before the report can leave the process.

from __future__ import annotations

import argparse
import getpass
import json
from pathlib import Path
import sys
from typing import Any, Callable, Mapping
from urllib.parse import urlsplit

_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

import issue9_live_harness as harness  # noqa: E402
import phrase_create_probe as probe  # noqa: E402


MODE = "phrase-readback-diagnostic"
# Every read target and every expected value is imported, never restated.
SPELLING = probe.SPELLING
COLLECTION_KEY = probe.COLLECTION_KEY
READ_PATHS: tuple[str, ...] = probe.READ_PATHS
TARGET_SPAN = probe.TARGET_SPAN
VOC_KEY = harness.RESPONSE_ENVELOPE_VOC_KEY
DATA_KEY = harness.READ_ONLY_COMPATIBILITY_CONTAINER_KEY
# The only two key names ever read out of a server object for range analysis.
RANGE_START, RANGE_END = "start", "end"
# The whole request budget: two GETs, one method, no retry, no concurrency.
MAX_GETS = 2
ALLOWED_METHODS: tuple[str, ...] = ("GET",)
READ_ONLY_POLICY = "GET-ONLY / AT MOST TWO READS / NO WRITE / NO RETRY"

STATUS_COMPLETED, STATUS_FAILED = "completed", "failed"

# --- the closed, project-owned diagnostic enums ----------------------------
WRAPPER_DOCUMENTED, WRAPPER_DATA, WRAPPER_NOT_ACCEPTED = (
    "documented-top-level", "data-wrapper", "not-accepted")
WRAPPERS: tuple[str, ...] = (WRAPPER_DOCUMENTED, WRAPPER_DATA, WRAPPER_NOT_ACCEPTED)

VALUE_LIST, VALUE_NOT_LIST, VALUE_ABSENT = "list", "not-list", "absent"
VALUE_CLASSES: tuple[str, ...] = (VALUE_LIST, VALUE_NOT_LIST, VALUE_ABSENT)

COUNT_ZERO, COUNT_ONE, COUNT_MULTIPLE = "zero", "one", "multiple"
COUNT_CLASSES: tuple[str, ...] = (COUNT_ZERO, COUNT_ONE, COUNT_MULTIPLE)

RECORD_MAPPING, RECORD_MALFORMED = "mapping", "malformed"
RECORD_STRUCTURES: tuple[str, ...] = (RECORD_MAPPING, RECORD_MALFORMED)

ID_SAFE, ID_INVALID, ID_MISSING = "safe", "invalid-local-policy", "missing-or-not-string"
ID_CLASSES: tuple[str, ...] = (ID_SAFE, ID_INVALID, ID_MISSING)

STATUS_INVALID = "invalid-or-missing"
# The two documented phrase statuses are owned by the frozen harness enum.
STATUS_CLASSES: tuple[str, ...] = (
    *harness.READ_ONLY_STATUS_ENUMS[COLLECTION_KEY], STATUS_INVALID)

# `highlight` is never sent by this project, so this is a pure observation of
# what the authenticated readback returns. The enum is closed: an unreviewed
# structure collapses into one of the coarse `*-other` members and an internally
# unclassifiable one fails closed, so no arbitrary server key or value is ever
# enumerated, copied or emitted.
HIGHLIGHT_MISSING, HIGHLIGHT_NULL, HIGHLIGHT_EMPTY = "missing", "null", "empty-array"
HIGHLIGHT_PAIR_ARRAY, HIGHLIGHT_OBJECT_ARRAY = "integer-pair-array", "object-range-array"
HIGHLIGHT_SINGLE_OBJECT, HIGHLIGHT_FLAT_PAIR = "single-object-range", "flat-integer-pair"
HIGHLIGHT_ARRAY_OTHER, HIGHLIGHT_OBJECT_OTHER = "array-other", "object-other"
HIGHLIGHT_SCALAR_OTHER, HIGHLIGHT_UNCLASSIFIABLE = "scalar-other", "unclassifiable"
HIGHLIGHT_PRESENCES: tuple[str, ...] = (
    HIGHLIGHT_MISSING, HIGHLIGHT_NULL, HIGHLIGHT_EMPTY, HIGHLIGHT_PAIR_ARRAY,
    HIGHLIGHT_OBJECT_ARRAY, HIGHLIGHT_SINGLE_OBJECT, HIGHLIGHT_FLAT_PAIR,
    HIGHLIGHT_ARRAY_OTHER, HIGHLIGHT_OBJECT_OTHER, HIGHLIGHT_SCALAR_OTHER,
    HIGHLIGHT_UNCLASSIFIABLE,
)
# Only these three are what the current strict parser already accepts.
ACCEPTED_HIGHLIGHTS: tuple[str, ...] = probe.SHAPES

# The single most useful output: the first checkpoint an authoritative response
# fails, in the same order the strict parser applies them.
CHECK_NONE = "none"
CHECK_VOC_TRANSPORT, CHECK_VOC_HTTP = "vocabulary-transport", "vocabulary-http-status"
CHECK_VOC_SCHEMA = "vocabulary-schema"
CHECK_COL_TRANSPORT, CHECK_COL_HTTP = "collection-transport", "collection-http-status"
CHECK_COL_BODY, CHECK_COL_WRAPPER = "collection-body-not-object", "collection-wrapper"
CHECK_COL_NOT_ARRAY, CHECK_COL_EMPTY = "collection-not-array", "collection-empty"
CHECK_COL_MULTIPLE = "collection-multiple"
CHECK_RECORD_OBJECT, CHECK_RECORD_ID = "record-not-object", "record-id"
CHECK_RECORD_STATUS, CHECK_RECORD_CONTENT = "record-status", "record-content"
CHECK_RECORD_DUPLICATE_ID = "record-duplicate-id"
CHECK_HIGHLIGHT_SHAPE, CHECK_HIGHLIGHT_RANGE = "highlight-shape", "highlight-range"
CHECK_LOCAL_SAFETY = "local-safety"
CHECKPOINTS: tuple[str, ...] = (
    CHECK_NONE, CHECK_VOC_TRANSPORT, CHECK_VOC_HTTP, CHECK_VOC_SCHEMA,
    CHECK_COL_TRANSPORT, CHECK_COL_HTTP, CHECK_COL_BODY, CHECK_COL_WRAPPER,
    CHECK_COL_NOT_ARRAY, CHECK_COL_EMPTY, CHECK_COL_MULTIPLE, CHECK_RECORD_OBJECT,
    CHECK_RECORD_ID, CHECK_RECORD_STATUS, CHECK_RECORD_DUPLICATE_ID,
    CHECK_RECORD_CONTENT, CHECK_HIGHLIGHT_SHAPE, CHECK_HIGHLIGHT_RANGE,
    CHECK_LOCAL_SAFETY,
)
# The diagnostic only *completed* when it actually read an authoritative
# response. A refused transport, a non-2xx status or a contained local failure
# localizes nothing about the schema, so it stays a failed run.
INCONCLUSIVE_CHECKPOINTS: tuple[str, ...] = (
    CHECK_VOC_TRANSPORT, CHECK_VOC_HTTP, CHECK_COL_TRANSPORT, CHECK_COL_HTTP,
    CHECK_LOCAL_SAFETY,
)
# `_read` classifies one GET coarsely; each stage maps that to its checkpoint.
VOC_FAILURES: Mapping[str, str] = {
    "transport": CHECK_VOC_TRANSPORT, "http-status": CHECK_VOC_HTTP,
    "schema": CHECK_VOC_SCHEMA,
}
COL_FAILURES: Mapping[str, str] = {
    "transport": CHECK_COL_TRANSPORT, "http-status": CHECK_COL_HTTP,
    "schema": CHECK_COL_BODY,
}
CONTENT_FIELDS: tuple[str, ...] = (
    "phrase_matches_expected", "interpretation_matches_expected",
    "tags_match_expected", "origin_matches_expected", "status_is_published",
)
# Every string a report may legally contain, so nothing server-provided can be
# smuggled through a field even if it happens to compare equal to a constant.
CLOSED_VALUES: frozenset[str] = frozenset((
    MODE, STATUS_COMPLETED, STATUS_FAILED, SPELLING, *WRAPPERS, *VALUE_CLASSES,
    *COUNT_CLASSES, *RECORD_STRUCTURES, *ID_CLASSES, *STATUS_CLASSES,
    *HIGHLIGHT_PRESENCES, *CHECKPOINTS, *harness.READ_ONLY_SCHEMA_REASONS,
))
BLOCKED_MESSAGE = "the GET-only readback diagnostic stopped safely; nothing was written"


def validate_contract() -> None:
    """Fail closed if the fixed GET-only diagnostic contract ever drifts."""
    probe.validate_contract()
    if (
        MAX_GETS != 2 or ALLOWED_METHODS != ("GET",) or SPELLING != "acquisition"
        or COLLECTION_KEY != "phrases" or TARGET_SPAN != (4, 15)
        or READ_PATHS != ("/open/api/v1/vocabulary", "/open/api/v1/phrases")
        or (VOC_KEY, DATA_KEY, RANGE_START, RANGE_END) != ("voc", "data", "start", "end")
        or ACCEPTED_HIGHLIGHTS != probe.SHAPES
    ):
        raise harness.SafetyError("the fixed GET-only diagnostic contract changed")


# The guard counts before delegating and accepts exactly one method, so no
# failure path anywhere below can turn into a write or into a third read.
class GetOnlyGuard:
    """Structurally cap this diagnostic at the two reviewed GETs."""

    def __init__(self, delegate: harness.Transport) -> None:
        validate_contract()
        self._delegate, self.get_count, self.rejected_methods = delegate, 0, 0

    def send(
        self, request: harness.HttpRequest, credential: harness.TestAccountCredential
    ) -> harness.HttpResponse:
        validate_contract()
        if not isinstance(request, harness.HttpRequest):
            raise harness.SafetyError("this diagnostic requires one reviewed request")
        if request.method not in ALLOWED_METHODS:
            self.rejected_methods += 1
            raise harness.SafetyError("this diagnostic can only read")
        harness._documented_read_path(request.path)
        if (
            request.payload is not None or self.get_count >= MAX_GETS
            or urlsplit(request.path).path not in READ_PATHS
        ):
            raise harness.SafetyError("GET is outside the reviewed endpoints or budget")
        self.get_count += 1
        return self._delegate.send(request, credential)


# --- sanitized primitives ---------------------------------------------------
_ABSENT = object()


def _member(container: Any, key: str) -> Any:
    """Read one allowlisted key; a hostile container is simply absent."""
    try:
        if isinstance(container, Mapping) and key in container:
            return container[key]
    except Exception:
        return _ABSENT
    return _ABSENT


def _equal(value: Any, expected: Any) -> bool:
    """Compare against a project-owned constant; a hostile ``__eq__`` is False."""
    try:
        return bool(value == expected)
    except Exception:
        return False


def _plain_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _range_pair(start: Any, end: Any) -> tuple[int, int] | None:
    """Accept a plain integer pair. Bounds are judged separately, never here."""
    return (start, end) if _plain_int(start) and _plain_int(end) else None


def _blank_report() -> dict[str, Any]:
    """One report shape, always fully populated, unreached fields left None."""
    return {
        "mode": MODE, "status": STATUS_FAILED, "read_only": True,
        "requested_spelling": SPELLING, "read_policy": None,
        "get_count": 0, "max_gets": MAX_GETS, "write_requests_attempted": 0,
        "requests_attempted": 0, "requests_completed": 0,
        "vocabulary_http_status": None, "vocabulary_wrapper": None,
        "vocabulary_schema_reason": None, "voc_id_fingerprint": None,
        "readback_http_status": None, "collection_wrapper": None,
        "phrases_value": None, "phrase_count_class": None,
        "duplicate_record_ids": None, "record_structure": None,
        "record_id_class": None, "record_status_class": None,
        "phrase_matches_expected": None, "interpretation_matches_expected": None,
        "tags_match_expected": None, "origin_matches_expected": None,
        "status_is_published": None, "highlight_presence": None,
        "highlight_range_count": None, "highlight_bounds_valid": None,
        "highlight_exact_target_span": None,
        "expected_target_span": [TARGET_SPAN[0], TARGET_SPAN[1]],
        "first_incompatibility": CHECK_LOCAL_SAFETY,
    }


def _assert_sanitized(report: Mapping[str, Any]) -> None:
    """Re-check every emitted field before the report can leave the process."""
    if set(report) != set(_blank_report()):
        raise harness.SafetyError("the diagnostic report shape changed")
    harness._assert_no_sensitive_keys(report, "diagnostic report")
    for value in report.values():
        if value is None or isinstance(value, bool) or _plain_int(value):
            continue
        if isinstance(value, list) and value == [TARGET_SPAN[0], TARGET_SPAN[1]]:
            continue
        if isinstance(value, str) and (
            value in CLOSED_VALUES or probe._valid_fingerprint(value)
            or value == READ_ONLY_POLICY
        ):
            continue
        raise harness.SafetyError("the diagnostic report is not fully sanitized")


# --- classification ---------------------------------------------------------


def classify_wrapper(body: Any, canonical_key: str) -> str:
    """Say which of the two reviewed locations holds the canonical key."""
    if _member(body, canonical_key) is not _ABSENT:
        return WRAPPER_DOCUMENTED
    if _member(_member(body, DATA_KEY), canonical_key) is not _ABSENT:
        return WRAPPER_DATA
    return WRAPPER_NOT_ACCEPTED


def classify_record_id(value: Any) -> str:
    """Classify the record id against the unchanged local policy, never echoing it."""
    if not isinstance(value, str):
        return ID_MISSING
    try:
        harness._safe_record_id(value, "phrase record id")
    except harness.SafetyError:
        return ID_INVALID
    return ID_SAFE


def classify_status(record: Any) -> str:
    """Return a documented status constant, or the closed rejection constant."""
    try:
        return probe._pinned(
            STATUS_CLASSES, harness._read_only_record_status(record, COLLECTION_KEY))
    except Exception:
        return STATUS_INVALID


def classify_highlight(record: Any) -> tuple[str, list[tuple[int, int]] | None]:
    """Classify ``highlight`` into one closed enum plus its ranges, if any."""
    value = _member(record, "highlight")
    if value is _ABSENT:
        return HIGHLIGHT_MISSING, None
    if value is None:
        return HIGHLIGHT_NULL, None
    try:
        return _highlight_shape(value)
    except Exception:
        # An internally unclassifiable structure must still leave as a closed
        # constant rather than as a crash or an echoed value.
        return HIGHLIGHT_UNCLASSIFIABLE, None


def _highlight_shape(value: Any) -> tuple[str, list[tuple[int, int]] | None]:
    """Coarse shape only. No key beyond ``start``/``end`` is ever inspected."""
    if isinstance(value, Mapping):
        pair = _range_pair(_member(value, RANGE_START), _member(value, RANGE_END))
        return (HIGHLIGHT_SINGLE_OBJECT, [pair]) if pair else (HIGHLIGHT_OBJECT_OTHER, None)
    if not isinstance(value, list):
        return HIGHLIGHT_SCALAR_OTHER, None
    if not value:
        return HIGHLIGHT_EMPTY, []
    if all(isinstance(item, Mapping) for item in value):
        pairs = [_range_pair(_member(item, RANGE_START), _member(item, RANGE_END))
                 for item in value]
        return (HIGHLIGHT_OBJECT_ARRAY, pairs) if all(pairs) else (HIGHLIGHT_ARRAY_OTHER, None)
    if all(isinstance(item, (list, tuple)) and len(item) == 2 for item in value):
        pairs = [_range_pair(item[0], item[1]) for item in value]
        return (HIGHLIGHT_PAIR_ARRAY, pairs) if all(pairs) else (HIGHLIGHT_ARRAY_OTHER, None)
    flat = _range_pair(value[0], value[1]) if len(value) == 2 else None
    return (HIGHLIGHT_FLAT_PAIR, [flat]) if flat else (HIGHLIGHT_ARRAY_OTHER, None)


def phrase_length(record: Any) -> int | None:
    """Measure the phrase in memory only; it is never printed or persisted."""
    try:
        return harness._read_only_phrase_length(record)
    except Exception:
        return None


def bounds_valid(ranges: list[tuple[int, int]], length: int | None) -> bool | None:
    """Judge every returned range against the measured phrase, values unexposed."""
    if not ranges:
        return None
    if length is None:
        return False
    return all(0 <= start < end <= length for start, end in ranges)


def content_matches(record: Any, status_class: str) -> dict[str, bool]:
    """Emit booleans only; the returned phrase/translation/origin never leave."""
    tags = _member(record, "tags")
    try:
        tags_match = (isinstance(tags, list) and len(tags) == len(probe.TAGS)
                      and harness._tags_equal(list(probe.TAGS), tags))
    except Exception:
        tags_match = False
    return {
        "phrase_matches_expected": _equal(_member(record, "phrase"), probe.PHRASE_TEXT),
        "interpretation_matches_expected": _equal(
            _member(record, "interpretation"), probe.TRANSLATION),
        "tags_match_expected": bool(tags_match),
        "origin_matches_expected": _equal(_member(record, "origin"), probe.ORIGIN),
        "status_is_published": status_class == probe.PUBLISHED,
    }


def duplicate_record_ids(records: list[Any]) -> bool:
    """Detect duplicate ids through fingerprints, so no raw id is ever held."""
    seen = [probe._short_fingerprint(value) for value in
            (_member(record, "id") for record in records) if isinstance(value, str)]
    return len(seen) != len(set(seen))


def first_record_checkpoint(report: Mapping[str, Any]) -> str:
    """Name the first checkpoint the strict parser would fail, in its own order."""
    if report["record_id_class"] != ID_SAFE:
        return CHECK_RECORD_ID
    if report["record_status_class"] == STATUS_INVALID:
        return CHECK_RECORD_STATUS
    if not all(report[field] for field in CONTENT_FIELDS):
        return CHECK_RECORD_CONTENT
    if report["highlight_presence"] not in ACCEPTED_HIGHLIGHTS:
        return CHECK_HIGHLIGHT_SHAPE
    if report["highlight_bounds_valid"] is False:
        return CHECK_HIGHLIGHT_RANGE
    return CHECK_NONE


# --- the two-request sequence ----------------------------------------------


def run_diagnostic(transport: harness.Transport, credential: harness.TestAccountCredential,
                   account_label: str) -> dict[str, Any]:
    """Run the whole GET-only sequence and contain every failure it can produce."""
    report, guard = _blank_report(), GetOnlyGuard(transport)
    try:
        _sequence(report, guard, credential, account_label)
    except Exception:
        report["first_incompatibility"] = CHECK_LOCAL_SAFETY
    report["get_count"] = guard.get_count
    report["write_requests_attempted"] = guard.rejected_methods
    report["read_policy"] = READ_ONLY_POLICY
    report["status"] = (
        STATUS_FAILED if report["first_incompatibility"] in INCONCLUSIVE_CHECKPOINTS
        else STATUS_COMPLETED
    )
    _assert_sanitized(report)
    if harness._contains_credential_material(report, credential.token):
        raise harness.SafetyError("the diagnostic report contains credential material")
    return report


def _sequence(report: dict[str, Any], guard: GetOnlyGuard,
              credential: harness.TestAccountCredential, account_label: str) -> None:
    validate_contract()
    label = harness._validate_account_label_shape(account_label)
    probe._account_gate(label, credential.fingerprint).validate(credential)

    request = harness.HttpRequest(
        "GET", harness.build_query_path("vocabulary", {"spelling": SPELLING}))
    response, status, failure = _read(report, guard, request, credential)
    report["vocabulary_http_status"] = status
    if response is not None:
        report["vocabulary_wrapper"] = classify_wrapper(response.body, VOC_KEY)
    if failure is not None:
        report["first_incompatibility"] = probe._pinned(CHECKPOINTS, VOC_FAILURES[failure])
        return
    try:
        vocabulary_id, _returned = harness._validate_probe_vocabulary(
            harness._canonical_probe_vocabulary_body(response.body), SPELLING)
    except Exception as rejected:
        report["vocabulary_schema_reason"] = harness._schema_reason_of(rejected)
        report["first_incompatibility"] = CHECK_VOC_SCHEMA
        return
    report["voc_id_fingerprint"] = probe._short_fingerprint(vocabulary_id)

    request = harness.HttpRequest(
        "GET", harness.build_query_path(COLLECTION_KEY, {"voc_id": vocabulary_id}))
    response, status, failure = _read(report, guard, request, credential)
    report["readback_http_status"] = status
    if response is not None:
        report["collection_wrapper"] = classify_wrapper(response.body, COLLECTION_KEY)
    if failure is not None:
        report["first_incompatibility"] = probe._pinned(CHECKPOINTS, COL_FAILURES[failure])
        return
    _classify_collection(report, response.body)


def _read(report: dict[str, Any], guard: GetOnlyGuard, request: harness.HttpRequest,
          credential: harness.TestAccountCredential
          ) -> tuple[harness.HttpResponse | None, int | None, str | None]:
    """Send exactly one reviewed GET and classify its result coarsely."""
    report["requests_attempted"] += 1
    try:
        response = guard.send(request, credential)
    except harness.TransportResponseError as rejected:
        # A complete response the transport itself refused to hand over.
        status = rejected.http_status
        if status is None:
            return None, None, "transport"
        report["requests_completed"] += 1
        return None, status, "schema" if 200 <= status < 300 else "http-status"
    except Exception:
        return None, None, "transport"
    status = harness._read_only_response_status(response)
    if status is None:
        return None, None, "transport"
    report["requests_completed"] += 1
    if not 200 <= status < 300:
        return None, status, "http-status"
    try:
        harness._require_read_success(response)
    except Exception:
        return response, status, "schema"
    return response, status, None


def _classify_collection(report: dict[str, Any], body: Any) -> None:
    """Localize the first incompatibility inside one authoritative collection."""
    try:
        canonical = harness._canonical_probe_collection_body(body, COLLECTION_KEY)
    except Exception:
        canonical = body
    records = _member(canonical, COLLECTION_KEY)
    if records is _ABSENT:
        report["phrases_value"] = VALUE_ABSENT
        report["first_incompatibility"] = CHECK_COL_WRAPPER
        return
    if not isinstance(records, list):
        report["phrases_value"] = VALUE_NOT_LIST
        report["first_incompatibility"] = CHECK_COL_NOT_ARRAY
        return
    report["phrases_value"] = VALUE_LIST
    report["phrase_count_class"] = (
        COUNT_ZERO if not records else COUNT_ONE if len(records) == 1 else COUNT_MULTIPLE)
    report["duplicate_record_ids"] = duplicate_record_ids(records)
    if not records:
        report["first_incompatibility"] = CHECK_COL_EMPTY
        return
    if len(records) == 1:
        _classify_record(report, records[0])
        return
    # A multi-record collection is only *ambiguous* once every record is
    # structurally accepted: the strict parser reaches its own count check after
    # phrase_records() has already validated the whole list. Reporting
    # `collection-multiple` first would hide exactly the schema checkpoint the
    # Issue #29 readback failed on.
    structural = _first_structural_checkpoint(records)
    report["first_incompatibility"] = probe._pinned(
        CHECKPOINTS, CHECK_COL_MULTIPLE if structural is None else structural)


def _first_structural_checkpoint(records: list[Any]) -> str | None:
    """Mirror ``phrase_records()``: per record Mapping/id/status, then duplicates.

    Only the first failing checkpoint is named. No per-record detail and no raw
    id is emitted, so a duplicate is reported without saying which id repeated.
    """
    for record in records:
        if not isinstance(record, Mapping):
            return CHECK_RECORD_OBJECT
        if classify_record_id(_member(record, "id")) != ID_SAFE:
            return CHECK_RECORD_ID
        if classify_status(record) == STATUS_INVALID:
            return CHECK_RECORD_STATUS
    return CHECK_RECORD_DUPLICATE_ID if duplicate_record_ids(records) else None


def _classify_record(report: dict[str, Any], record: Any) -> None:
    if not isinstance(record, Mapping):
        report["record_structure"] = RECORD_MALFORMED
        report["first_incompatibility"] = CHECK_RECORD_OBJECT
        return
    report["record_structure"] = RECORD_MAPPING
    report["record_id_class"] = classify_record_id(_member(record, "id"))
    report["record_status_class"] = classify_status(record)
    report.update(content_matches(record, report["record_status_class"]))
    presence, ranges = classify_highlight(record)
    report["highlight_presence"] = probe._pinned(HIGHLIGHT_PRESENCES, presence)
    if ranges is not None:
        report["highlight_range_count"] = len(ranges)
        report["highlight_bounds_valid"] = bounds_valid(ranges, phrase_length(record))
        report["highlight_exact_target_span"] = len(ranges) == 1 and ranges[0] == TARGET_SPAN
    report["first_incompatibility"] = probe._pinned(CHECKPOINTS, first_record_checkpoint(report))


# --- the single command -----------------------------------------------------

CLI_PROGRAM_NAME = "phrase_readback_diagnostic.py"
TOKEN_PROMPT = "Secondary/test-account Maimemo Token (hidden): "


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """One command, no subcommands, and no caller-supplied content at all."""
    parser = harness.SanitizedArgumentParser(
        prog=CLI_PROGRAM_NAME,
        description=("Issue #30 GET-only phrase readback diagnostic; the read target is "
                     "fixed by this project and nothing is ever written"),
    )
    parser.add_argument("--account-label", required=True)
    parser.add_argument("--allow-network", action="store_true",
                        help="explicitly acknowledge that this command may create the transport")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, *, token_prompt: Callable[[str], str] | None = None,
         transport_factory: Callable[[], harness.Transport] | None = None,
         stdin_isatty: Callable[[], bool] | None = None) -> int:
    args = parse_args(argv)
    try:
        if not args.allow_network:
            raise harness.SafetyError("network access was not explicitly enabled")
        account_label = harness._validate_account_label_shape(args.account_label)
        validate_contract()
        if not (stdin_isatty or sys.stdin.isatty)():
            raise harness.SafetyError("an interactive terminal is required")
        transport = (transport_factory or harness.ProductionHttpTransport)()
    except Exception:
        print("BLOCKED: --allow-network, the account label, the fixed GET-only contract, an "
              "interactive terminal or the locked transport was rejected.")
        return 3
    try:
        credential = harness.TestAccountCredential(
            harness._hidden_prompt(token_prompt or getpass.getpass, TOKEN_PROMPT), account_label)
    except Exception:
        print("BLOCKED: the hidden secondary-account credential was not accepted.")
        return 3
    print(f"PHRASE READBACK DIAGNOSTIC — READ-ONLY — {READ_ONLY_POLICY}")
    try:
        report = run_diagnostic(transport, credential, account_label)
    except Exception:
        print(BLOCKED_MESSAGE)
        return 4
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if report["status"] == STATUS_COMPLETED else 4


if __name__ == "__main__":
    raise SystemExit(main())
