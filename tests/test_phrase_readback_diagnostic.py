"""Issue #30 — the GET-only sanitized phrase readback schema diagnostic.

Every test here runs offline against an injected fake transport, under the
process-level no-network guard, with an obviously fake credential. No real
Maimemo request is possible and no real Token is read.

The suite is organized around the diagnostic contract rather than around
functions: the request set is exactly two GETs and no write method can even be
built; the first incompatibility is localized in the same order the strict
parser applies its checkpoints; and every emitted field is a project-owned
closed enum, a bounded count, a boolean or a fingerprint — so a hostile
production response can never escape through stdout, stderr, a repr or an
exception.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import socket
import sys
import traceback
import unittest
from unittest import mock
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import issue9_live_harness as harness  # noqa: E402
import phrase_create_probe as probe  # noqa: E402
import phrase_readback_diagnostic as diagnostic  # noqa: E402


FAKE_TOKEN = "FAKE_ISSUE30_CREDENTIAL_NOT_VALID"
ACCOUNT_LABEL = "issue30-secondary-fixture"
VOCABULARY_ID = "INVALID_ISSUE30_VOCABULARY_ID"
RECORD_ID = "INVALID_ISSUE30_PHRASE_RECORD_ID"
OTHER_RECORD_ID = "INVALID_ISSUE30_OTHER_PHRASE_ID"

# Hostile values a production response, a server key name or an external library
# exception could carry. None may appear in stdout, stderr, the report, a
# repr/str or a formatted traceback.
SERVER_KEY = "PRIVATE-ISSUE30-UNKNOWN-SERVER-KEY-SENTINEL"
SERVER_VALUE = "PRIVATE ISSUE30 SERVER VALUE SENTINEL"
TRANSPORT_SENTINEL = "PRIVATE-ISSUE30-TRANSPORT-EXCEPTION-SENTINEL"
UNSAFE_ID = "PRIVATE.ISSUE30/RECORD ID+SENTINEL"
FOREIGN_PHRASE = "PRIVATE ISSUE30 FOREIGN PHRASE SENTINEL"
SENTINELS = (
    FAKE_TOKEN, ACCOUNT_LABEL, VOCABULARY_ID, RECORD_ID, OTHER_RECORD_ID,
    SERVER_KEY, SERVER_VALUE, TRANSPORT_SENTINEL, UNSAFE_ID, FOREIGN_PHRASE,
)

VOCABULARY_PATH = "/open/api/v1/vocabulary?spelling=acquisition"
PHRASES_PATH = f"/open/api/v1/phrases?voc_id={VOCABULARY_ID}"
EXPECTED_SEQUENCE = [("GET", VOCABULARY_PATH), ("GET", PHRASES_PATH)]
PHRASE_LENGTH = len(probe.PHRASE_TEXT)
# A valid non-target range whose coordinates cannot collide with a count, a
# status or the project-owned expected span.
OTHER_SPAN = [17, 41]
OUT_OF_BOUNDS_SPAN = [4, PHRASE_LENGTH + 37]


class FakeTransport:
    """Queued in-memory transport. It never touches a socket."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def send(self, request, _credential):
        self.requests.append(request)
        if not self.responses:
            raise AssertionError("the fake transport received an unexpected request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response

    def calls(self):
        return [(request.method, request.path) for request in self.requests]


def _string_constants(code):
    """Every string constant compiled into a module, including nested scopes."""
    for const in code.co_consts:
        if isinstance(const, str):
            yield const
        elif hasattr(const, "co_consts"):
            yield from _string_constants(const)


class DiagnosticFixtures:
    """Shared fixtures for every Issue #30 case."""

    def credential(self):
        return harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL)

    # --- response builders -------------------------------------------------

    def vocabulary(self, *, wrapped=False, **overrides):
        record = {"id": VOCABULARY_ID, "spelling": "acquisition", SERVER_KEY: SERVER_VALUE}
        record.update(overrides)
        body = {"data": {"voc": record}} if wrapped else {"voc": record}
        body[SERVER_KEY] = SERVER_VALUE
        return harness.HttpResponse(200, body)

    def record(self, **overrides):
        record = {
            "id": RECORD_ID, "phrase": probe.PHRASE_TEXT, "interpretation": probe.TRANSLATION,
            "tags": ["MBA", "BEC", "GMAT"], "origin": probe.ORIGIN, "status": "PUBLISHED",
            "highlight": [[4, 15]], SERVER_KEY: SERVER_VALUE,
        }
        record.update(overrides)
        return record

    def collection(self, records, *, wrapped=False, status=200):
        body = {"data": {"phrases": records}} if wrapped else {"phrases": records}
        body[SERVER_KEY] = SERVER_VALUE
        return harness.HttpResponse(status, body)

    def responses(self, *, wrapped=False, records=None, record=None):
        if records is None:
            records = [self.record() if record is None else record]
        return [self.vocabulary(wrapped=wrapped), self.collection(records, wrapped=wrapped)]

    # --- drivers -----------------------------------------------------------

    def drive(self, responses, *, label=ACCOUNT_LABEL):
        transport = FakeTransport(responses)
        report = diagnostic.run_diagnostic(transport, self.credential(), label)
        return report, transport

    def report_for(self, **kwargs):
        return self.drive(self.responses(**kwargs))[0]

    def rendered(self, report):
        return json.dumps(report, ensure_ascii=False, sort_keys=True)


# ---------------------------------------------------------------------------
# A. The read-only contract and the locked request set
# ---------------------------------------------------------------------------


class ReadOnlyContractTests(DiagnosticFixtures, unittest.TestCase):
    def test_no_write_method_can_be_named_anywhere_in_the_module(self):
        source = Path(diagnostic.__file__).read_text(encoding="utf-8")
        constants = set(_string_constants(compile(source, "<diagnostic>", "exec")))
        for method in ("POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"):
            self.assertNotIn(method, constants)
        self.assertEqual(diagnostic.ALLOWED_METHODS, ("GET",))
        self.assertEqual(diagnostic.MAX_GETS, 2)

    def test_the_fixed_contract_is_imported_and_drift_fails_closed(self):
        self.assertEqual(diagnostic.SPELLING, "acquisition")
        self.assertEqual(diagnostic.COLLECTION_KEY, "phrases")
        self.assertEqual(diagnostic.TARGET_SPAN, (4, 15))
        self.assertEqual(diagnostic.READ_PATHS,
                         ("/open/api/v1/vocabulary", "/open/api/v1/phrases"))
        for name, value in {"MAX_GETS": 3, "ALLOWED_METHODS": ("GET", "TRACE"),
                            "TARGET_SPAN": (0, 11), "RANGE_END": "finish"}.items():
            with self.subTest(constant=name):
                with mock.patch.object(diagnostic, name, value):
                    with self.assertRaises(harness.SafetyError):
                        diagnostic.validate_contract()

    def test_the_frozen_harness_and_the_probe_own_every_reused_primitive(self):
        for module, names in (
            (harness, ("TestAccountCredential", "ProductionHttpTransport", "HttpRequest",
                       "build_query_path", "_documented_read_path", "_require_read_success",
                       "_canonical_probe_vocabulary_body", "_canonical_probe_collection_body",
                       "_validate_probe_vocabulary", "_safe_record_id", "_tags_equal",
                       "_read_only_record_status", "_read_only_phrase_length",
                       "SanitizedArgumentParser")),
            (probe, ("SPELLING", "PHRASE_TEXT", "TRANSLATION", "TAGS", "ORIGIN", "PUBLISHED",
                     "TARGET_SPAN", "READ_PATHS", "SHAPES", "_pinned", "_short_fingerprint",
                     "_account_gate")),
        ):
            for name in names:
                self.assertTrue(hasattr(module, name), name)

    def test_a_successful_run_sends_exactly_two_gets(self):
        report, transport = self.drive(self.responses())
        self.assertEqual(transport.calls(), EXPECTED_SEQUENCE)
        self.assertEqual(report["get_count"], 2)
        self.assertEqual(report["requests_attempted"], 2)
        self.assertEqual(report["requests_completed"], 2)
        self.assertEqual(report["write_requests_attempted"], 0)
        self.assertTrue(report["read_only"])
        self.assertEqual(report["status"], "completed")
        self.assertEqual(report["first_incompatibility"], "none")

    def test_the_guard_refuses_a_third_read_and_every_non_get_request(self):
        guard = diagnostic.GetOnlyGuard(FakeTransport([self.collection([]) for _ in range(3)]))
        request = harness.HttpRequest("GET", PHRASES_PATH)
        for _ in range(diagnostic.MAX_GETS):
            guard.send(request, self.credential())
        with self.assertRaises(harness.SafetyError):
            guard.send(request, self.credential())
        self.assertEqual(guard.get_count, diagnostic.MAX_GETS)

        write = harness.HttpRequest("POST", "/open/api/v1/phrases", {"phrase": {}})
        with self.assertRaises(harness.SafetyError):
            diagnostic.GetOnlyGuard(FakeTransport([])).send(write, self.credential())
        for method in ("PUT", "PATCH", "DELETE", "HEAD"):
            with self.subTest(method=method):
                with self.assertRaises(harness.SafetyError):
                    harness.HttpRequest(method, "/open/api/v1/phrases", {"phrase": {}})

    def test_the_guard_counts_a_refused_write_and_never_dispatches_it(self):
        delegate = FakeTransport([])
        guard = diagnostic.GetOnlyGuard(delegate)
        with self.assertRaises(harness.SafetyError):
            guard.send(harness.HttpRequest("POST", "/open/api/v1/phrases", {"phrase": {}}),
                       self.credential())
        self.assertEqual((guard.get_count, guard.rejected_methods), (0, 1))
        self.assertEqual(delegate.calls(), [])

    def test_main_and_production_account_labels_are_rejected_before_any_read(self):
        for label in ("main account", "primary", "prod-account", "主账号", "生产"):
            with self.subTest(label=label):
                report, transport = self.drive(self.responses(), label=label)
                self.assertEqual(transport.calls(), [])
                self.assertEqual(report["first_incompatibility"], "local-safety")
                self.assertEqual(report["status"], "failed")


# ---------------------------------------------------------------------------
# B. Wrappers, transport and HTTP status
# ---------------------------------------------------------------------------


class EnvelopeTests(DiagnosticFixtures, unittest.TestCase):
    def test_documented_and_data_wrapped_responses_are_both_read(self):
        documented = self.report_for()
        wrapped = self.report_for(wrapped=True)
        self.assertEqual(documented["vocabulary_wrapper"], "documented-top-level")
        self.assertEqual(documented["collection_wrapper"], "documented-top-level")
        self.assertEqual(wrapped["vocabulary_wrapper"], "data-wrapper")
        self.assertEqual(wrapped["collection_wrapper"], "data-wrapper")
        for key in ("first_incompatibility", "phrase_count_class", "highlight_presence"):
            self.assertEqual(documented[key], wrapped[key])

    def test_an_unreviewed_collection_wrapper_is_localized_without_naming_keys(self):
        report, _transport = self.drive([
            self.vocabulary(),
            harness.HttpResponse(200, {"result": {"phrases": [self.record()]},
                                       SERVER_KEY: SERVER_VALUE}),
        ])
        self.assertEqual(report["collection_wrapper"], "not-accepted")
        self.assertEqual(report["phrases_value"], "absent")
        self.assertEqual(report["first_incompatibility"], "collection-wrapper")
        self.assertNotIn(SERVER_KEY, self.rendered(report))

    def test_transport_and_http_status_failures_are_localized_per_stage(self):
        # An unread response localizes nothing, so the run stays `failed`; a
        # response that was read and then rejected is a real localization.
        cases = {
            "vocabulary-transport": ([harness.TransportError(TRANSPORT_SENTINEL)],
                                     "vocabulary-transport", 0, "failed"),
            "vocabulary-403": ([harness.HttpResponse(403, {SERVER_KEY: SERVER_VALUE})],
                               "vocabulary-http-status", 1, "failed"),
            "vocabulary-rejected-body": ([harness.TransportResponseError(200, None)],
                                         "vocabulary-schema", 1, "completed"),
            "vocabulary-missing-voc": ([harness.HttpResponse(200, {SERVER_KEY: SERVER_VALUE})],
                                       "vocabulary-schema", 1, "completed"),
            "vocabulary-unsafe-id": ([self.vocabulary(id=UNSAFE_ID)],
                                     "vocabulary-schema", 1, "completed"),
            "vocabulary-mismatch": ([self.vocabulary(spelling="acquisitions")],
                                    "vocabulary-schema", 1, "completed"),
            "collection-transport": ([self.vocabulary(),
                                      harness.TransportError(TRANSPORT_SENTINEL)],
                                     "collection-transport", 1, "failed"),
            "collection-500": ([self.vocabulary(), self.collection([], status=500)],
                               "collection-http-status", 2, "failed"),
            "collection-body-not-object": ([self.vocabulary(),
                                            harness.HttpResponse(200, [SERVER_VALUE])],
                                           "collection-body-not-object", 2, "completed"),
        }
        for name, (responses, checkpoint, completed, status) in cases.items():
            with self.subTest(case=name):
                report, _transport = self.drive(responses)
                self.assertEqual(report["first_incompatibility"], checkpoint)
                self.assertEqual(report["requests_completed"], completed)
                self.assertEqual(report["status"], status)
                self.assertEqual(report["write_requests_attempted"], 0)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, self.rendered(report))

    def test_a_vocabulary_schema_reason_stays_inside_the_frozen_enum(self):
        report = self.drive([harness.HttpResponse(200, {SERVER_KEY: SERVER_VALUE})])[0]
        self.assertIn(report["vocabulary_schema_reason"], harness.READ_ONLY_SCHEMA_REASONS)
        self.assertIsNone(report["voc_id_fingerprint"])

    def test_a_resolved_vocabulary_id_only_ever_leaves_as_a_fingerprint(self):
        report = self.report_for()
        self.assertEqual(report["voc_id_fingerprint"],
                         harness._fingerprint(VOCABULARY_ID)["sha256"][:16])
        self.assertNotIn(VOCABULARY_ID, self.rendered(report))


# ---------------------------------------------------------------------------
# C. The collection and the record
# ---------------------------------------------------------------------------


class CollectionTests(DiagnosticFixtures, unittest.TestCase):
    def test_every_record_count_is_classified(self):
        cases = {
            "zero": ([], "collection-empty"),
            "one": ([self.record()], "none"),
            "multiple": ([self.record(), self.record(id=OTHER_RECORD_ID,
                                                     phrase=FOREIGN_PHRASE)],
                         "collection-multiple"),
        }
        for expected, (records, checkpoint) in cases.items():
            with self.subTest(count=expected):
                report = self.report_for(records=records)
                self.assertEqual(report["phrases_value"], "list")
                self.assertEqual(report["phrase_count_class"], expected)
                self.assertEqual(report["first_incompatibility"], checkpoint)
                self.assertEqual(report["status"], "completed")

    def test_a_collection_that_is_not_an_array_is_localized(self):
        report = self.drive([self.vocabulary(),
                             harness.HttpResponse(200, {"phrases": SERVER_VALUE})])[0]
        self.assertEqual(report["phrases_value"], "not-list")
        self.assertEqual(report["first_incompatibility"], "collection-not-array")
        self.assertIsNone(report["phrase_count_class"])
        self.assertNotIn(SERVER_VALUE, self.rendered(report))

    def test_a_record_that_is_not_an_object_is_localized(self):
        for malformed in (SERVER_VALUE, [SERVER_VALUE], 7, None):
            with self.subTest(record=type(malformed).__name__):
                report = self.report_for(records=[malformed])
                self.assertEqual(report["record_structure"], "malformed")
                self.assertEqual(report["first_incompatibility"], "record-not-object")
                self.assertIsNone(report["record_id_class"])
                self.assertNotIn(SERVER_VALUE, self.rendered(report))

    def test_duplicate_ids_are_detected_through_fingerprints_only(self):
        duplicated = self.report_for(records=[self.record(), self.record()])
        self.assertTrue(duplicated["duplicate_record_ids"])
        self.assertEqual(duplicated["first_incompatibility"], "collection-multiple")
        distinct = self.report_for(records=[self.record(),
                                            self.record(id=OTHER_RECORD_ID)])
        self.assertFalse(distinct["duplicate_record_ids"])
        for report in (duplicated, distinct):
            for sentinel in (RECORD_ID, OTHER_RECORD_ID):
                self.assertNotIn(sentinel, self.rendered(report))

    def test_every_record_id_class_is_reported_without_the_id(self):
        cases = {UNSAFE_ID: "invalid-local-policy", "": "invalid-local-policy",
                 7: "missing-or-not-string", None: "missing-or-not-string",
                 RECORD_ID: "safe"}
        for value, expected in cases.items():
            with self.subTest(id=repr(value)[:24]):
                report = self.report_for(record=self.record(id=value))
                self.assertEqual(report["record_id_class"], expected)
                self.assertEqual(report["first_incompatibility"],
                                 "none" if expected == "safe" else "record-id")
                self.assertNotIn(UNSAFE_ID, self.rendered(report))

    def test_every_record_status_class_is_reported(self):
        cases = {"PUBLISHED": ("PUBLISHED", "none"), "DELETED": ("DELETED", "record-content"),
                 "DRAFT": ("invalid-or-missing", "record-status"),
                 SERVER_VALUE: ("invalid-or-missing", "record-status")}
        for value, (expected, checkpoint) in cases.items():
            with self.subTest(status=value[:24]):
                report = self.report_for(record=self.record(status=value))
                self.assertEqual(report["record_status_class"], expected)
                self.assertEqual(report["first_incompatibility"], checkpoint)
                self.assertNotIn(SERVER_VALUE, self.rendered(report))
        missing = self.record()
        missing.pop("status")
        self.assertEqual(self.report_for(record=missing)["record_status_class"],
                         "invalid-or-missing")


class ContentMatchTests(DiagnosticFixtures, unittest.TestCase):
    def test_an_exact_record_matches_every_expected_constant(self):
        report = self.report_for()
        for field in diagnostic.CONTENT_FIELDS:
            self.assertTrue(report[field], field)
        self.assertEqual(report["record_structure"], "mapping")
        self.assertEqual(report["first_incompatibility"], "none")

    def test_server_tag_order_is_compared_as_a_set(self):
        for tags in (["GMAT", "MBA", "BEC"], ["BEC", "GMAT", "MBA"]):
            with self.subTest(tags=tags):
                self.assertTrue(self.report_for(record=self.record(tags=tags))
                                ["tags_match_expected"])

    def test_every_content_mismatch_is_one_boolean_and_never_the_value(self):
        cases = {
            "phrase_matches_expected": {"phrase": FOREIGN_PHRASE},
            "interpretation_matches_expected": {"interpretation": SERVER_VALUE},
            "tags_match_expected": {"tags": ["MBA", "BEC"]},
            "origin_matches_expected": {"origin": SERVER_VALUE},
            "status_is_published": {"status": "DELETED"},
        }
        for field, overrides in cases.items():
            with self.subTest(field=field):
                report = self.report_for(record=self.record(**overrides))
                self.assertFalse(report[field])
                self.assertEqual(report["first_incompatibility"], "record-content")
                others = [name for name in diagnostic.CONTENT_FIELDS if name != field]
                self.assertTrue(all(report[name] for name in others))
                rendered = self.rendered(report)
                for sentinel in (FOREIGN_PHRASE, SERVER_VALUE):
                    self.assertNotIn(sentinel, rendered)

    def test_hostile_and_missing_content_fields_stay_false(self):
        class Hostile:
            def __eq__(self, _other):
                raise RuntimeError(TRANSPORT_SENTINEL)

            def __hash__(self):
                return 0

        for overrides in ({"phrase": Hostile()}, {"tags": Hostile()}, {"origin": None}):
            with self.subTest(overrides=list(overrides)):
                record = self.record(**overrides)
                report = self.report_for(record=record)
                self.assertEqual(report["first_incompatibility"], "record-content")
                self.assertNotIn(TRANSPORT_SENTINEL, self.rendered(report))


# ---------------------------------------------------------------------------
# D. The highlight classification
# ---------------------------------------------------------------------------


class HighlightTests(DiagnosticFixtures, unittest.TestCase):
    def observed(self, highlight, *, remove=False):
        record = self.record()
        if remove:
            record.pop("highlight")
        else:
            record["highlight"] = highlight
        return self.report_for(record=record)

    def test_every_presence_member_is_classified(self):
        cases = {
            "missing": (None, True),
            "null": (None, False),
            "empty-array": ([], False),
            "integer-pair-array": ([[4, 15]], False),
            "object-range-array": ([{"start": 4, "end": 15}], False),
            "single-object-range": ({"start": 4, "end": 15}, False),
            "flat-integer-pair": ([4, 15], False),
            "array-other": ([[4, 15], {"start": 4, "end": 15}], False),
            "object-other": ({SERVER_KEY: SERVER_VALUE}, False),
            "scalar-other": (SERVER_VALUE, False),
        }
        for expected, (highlight, remove) in cases.items():
            with self.subTest(presence=expected):
                report = self.observed(highlight, remove=remove)
                self.assertEqual(report["highlight_presence"], expected)
                self.assertIn(report["highlight_presence"], diagnostic.HIGHLIGHT_PRESENCES)
                self.assertNotIn(SERVER_KEY, self.rendered(report))
                self.assertNotIn(SERVER_VALUE, self.rendered(report))

    def test_an_internally_unclassifiable_highlight_fails_closed(self):
        class Hostile(list):
            def __len__(self):
                raise RuntimeError(TRANSPORT_SENTINEL)

        report = self.observed(Hostile())
        self.assertEqual(report["highlight_presence"], "unclassifiable")
        self.assertIsNone(report["highlight_range_count"])
        self.assertEqual(report["first_incompatibility"], "highlight-shape")
        self.assertNotIn(TRANSPORT_SENTINEL, self.rendered(report))

    def test_only_the_currently_accepted_shapes_reach_the_none_checkpoint(self):
        accepted = {"integer-pair-array": [[4, 15]],
                    "object-range-array": [{"start": 4, "end": 15}],
                    "empty-array": []}
        self.assertEqual(set(accepted), set(diagnostic.ACCEPTED_HIGHLIGHTS))
        for name, highlight in accepted.items():
            with self.subTest(shape=name):
                self.assertEqual(self.observed(highlight)["first_incompatibility"], "none")
        for name, highlight in (("single-object-range", {"start": 4, "end": 15}),
                                ("flat-integer-pair", [4, 15]),
                                ("missing", None), ("null", None)):
            with self.subTest(shape=name):
                report = self.observed(highlight, remove=name == "missing")
                self.assertEqual(report["first_incompatibility"], "highlight-shape")

    def test_the_exact_target_span_is_reported_in_every_range_shape(self):
        for highlight in ([[4, 15]], [{"start": 4, "end": 15}], {"start": 4, "end": 15},
                          [4, 15]):
            with self.subTest(highlight=str(highlight)):
                report = self.observed(highlight)
                self.assertEqual(report["highlight_range_count"], 1)
                self.assertTrue(report["highlight_bounds_valid"])
                self.assertTrue(report["highlight_exact_target_span"])
        self.assertEqual(self.report_for()["expected_target_span"], [4, 15])

    def test_an_empty_highlight_reports_a_zero_count_and_no_range_verdict(self):
        report = self.observed([])
        self.assertEqual(report["highlight_range_count"], 0)
        self.assertIsNone(report["highlight_bounds_valid"])
        self.assertFalse(report["highlight_exact_target_span"])

    def test_a_different_valid_range_never_leaks_its_coordinates(self):
        report = self.observed([OTHER_SPAN])
        self.assertEqual(report["highlight_presence"], "integer-pair-array")
        self.assertEqual(report["highlight_range_count"], 1)
        self.assertTrue(report["highlight_bounds_valid"])
        self.assertFalse(report["highlight_exact_target_span"])
        self.assertEqual(report["first_incompatibility"], "none")
        rendered = self.rendered(report)
        for coordinate in OTHER_SPAN:
            self.assertNotIn(str(coordinate), rendered)

    def test_multiple_ranges_are_counted_but_never_enumerated(self):
        report = self.observed([[4, 15], OTHER_SPAN])
        self.assertEqual(report["highlight_range_count"], 2)
        self.assertTrue(report["highlight_bounds_valid"])
        self.assertFalse(report["highlight_exact_target_span"])
        for coordinate in OTHER_SPAN:
            self.assertNotIn(str(coordinate), self.rendered(report))

    def test_out_of_bounds_and_malformed_ranges_are_classified_not_crashed(self):
        cases = {
            "out-of-bounds": ([OUT_OF_BOUNDS_SPAN], "integer-pair-array", "highlight-range"),
            "negative": ([[-1, 15]], "integer-pair-array", "highlight-range"),
            "inverted": ([[15, 4]], "integer-pair-array", "highlight-range"),
            "empty-range": ([[4, 4]], "integer-pair-array", "highlight-range"),
            "object-out-of-bounds": ([{"start": 0, "end": PHRASE_LENGTH + 37}],
                                     "object-range-array", "highlight-range"),
            "string-range": ([["4", "15"]], "array-other", "highlight-shape"),
            "booleans": ([[True, False]], "array-other", "highlight-shape"),
            "triple": ([[4, 15, 20]], "array-other", "highlight-shape"),
        }
        for name, (highlight, presence, checkpoint) in cases.items():
            with self.subTest(case=name):
                report = self.observed(highlight)
                self.assertEqual(report["highlight_presence"], presence)
                self.assertEqual(report["first_incompatibility"], checkpoint)
                if checkpoint == "highlight-range":
                    self.assertFalse(report["highlight_bounds_valid"])
                self.assertNotIn(str(PHRASE_LENGTH + 37), self.rendered(report))

    def test_bounds_cannot_be_judged_without_a_measurable_phrase(self):
        report = self.report_for(record=self.record(phrase=None, highlight=[[4, 15]]))
        self.assertEqual(report["highlight_presence"], "integer-pair-array")
        self.assertFalse(report["highlight_bounds_valid"])
        self.assertEqual(report["first_incompatibility"], "record-content")

    def test_only_start_and_end_are_ever_read_out_of_a_range_object(self):
        self.assertEqual((diagnostic.RANGE_START, diagnostic.RANGE_END), ("start", "end"))
        report = self.observed([{"start": 4, "end": 15, SERVER_KEY: SERVER_VALUE}])
        self.assertEqual(report["highlight_presence"], "object-range-array")
        self.assertTrue(report["highlight_exact_target_span"])
        self.assertNotIn(SERVER_KEY, self.rendered(report))


# ---------------------------------------------------------------------------
# E. Containment, the CLI and the process-level network guard
# ---------------------------------------------------------------------------


class ContainmentTests(DiagnosticFixtures, unittest.TestCase):
    def test_the_report_shape_and_every_value_stay_closed(self):
        report = self.report_for()
        self.assertEqual(report["mode"], "phrase-readback-diagnostic")
        self.assertIn(report["first_incompatibility"], diagnostic.CHECKPOINTS)
        self.assertIn(report["vocabulary_wrapper"], diagnostic.WRAPPERS)
        self.assertIn(report["phrases_value"], diagnostic.VALUE_CLASSES)
        self.assertIn(report["phrase_count_class"], diagnostic.COUNT_CLASSES)
        self.assertIn(report["record_structure"], diagnostic.RECORD_STRUCTURES)
        self.assertIn(report["record_id_class"], diagnostic.ID_CLASSES)
        self.assertIn(report["record_status_class"], diagnostic.STATUS_CLASSES)
        diagnostic._assert_sanitized(report)

    def test_an_unsanitized_report_can_never_be_returned(self):
        report = self.report_for()
        for field, value in (("first_incompatibility", SERVER_VALUE),
                             ("highlight_presence", SERVER_KEY),
                             ("record_id_class", RECORD_ID)):
            with self.subTest(field=field):
                with self.assertRaises(harness.SafetyError):
                    diagnostic._assert_sanitized(dict(report, **{field: value}))
        with self.assertRaises(harness.SafetyError):
            diagnostic._assert_sanitized(dict(report, extra_field=1))

    def test_no_sentinel_escapes_any_run_or_its_traceback(self):
        runs = [
            self.responses(),
            self.responses(record=self.record(id=UNSAFE_ID, phrase=FOREIGN_PHRASE,
                                              status=SERVER_VALUE, highlight=[OTHER_SPAN])),
            self.responses(records=[SERVER_VALUE]),
            [self.vocabulary(), harness.TransportError(TRANSPORT_SENTINEL)],
            [harness.HttpResponse(200, {SERVER_KEY: SERVER_VALUE})],
        ]
        for index, responses in enumerate(runs):
            with self.subTest(run=index):
                report, _transport = self.drive(responses)
                rendered = self.rendered(report) + repr(report)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_a_local_failure_leaves_one_sanitized_report_and_no_leak(self):
        with mock.patch.object(diagnostic, "_classify_collection",
                               side_effect=RuntimeError(TRANSPORT_SENTINEL)):
            report, transport = self.drive(self.responses())
        self.assertEqual(report["first_incompatibility"], "local-safety")
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(transport.calls()), 2)
        self.assertNotIn(TRANSPORT_SENTINEL, self.rendered(report))

    def test_a_credential_can_never_travel_inside_a_report(self):
        with mock.patch.object(harness, "_contains_credential_material", return_value=True):
            with self.assertRaises(harness.SafetyError):
                self.drive(self.responses())


class CliTests(DiagnosticFixtures, unittest.TestCase):
    def cli(self, argv, *, responses=None, token=FAKE_TOKEN, isatty=True):
        transport = FakeTransport(responses if responses is not None else self.responses())
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = diagnostic.main(argv, token_prompt=lambda _m: token,
                                   transport_factory=lambda: transport,
                                   stdin_isatty=lambda: isatty)
        return code, out.getvalue(), err.getvalue(), transport

    def test_the_documented_command_prints_one_sanitized_report(self):
        argv = ["--account-label", ACCOUNT_LABEL, "--allow-network"]
        code, out, err, transport = self.cli(argv)
        self.assertEqual(code, 0)
        self.assertIn("PHRASE READBACK DIAGNOSTIC — READ-ONLY —", out)
        self.assertIn('"first_incompatibility": "none"', out)
        self.assertEqual(transport.calls(), EXPECTED_SEQUENCE)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, out + err)

    def test_a_hostile_response_never_reaches_stdout_or_stderr(self):
        code, out, err, _transport = self.cli(
            ["--account-label", ACCOUNT_LABEL, "--allow-network"],
            responses=self.responses(record=self.record(
                id=UNSAFE_ID, phrase=FOREIGN_PHRASE, origin=SERVER_VALUE,
                highlight={SERVER_KEY: SERVER_VALUE})))
        self.assertEqual(code, 0)
        report = json.loads(out[out.index("{"):])
        self.assertEqual(report["first_incompatibility"], "record-id")
        self.assertEqual(report["highlight_presence"], "object-other")
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, out + err)

    def test_local_gates_block_before_any_read(self):
        cases = {
            "no-allow-network": (["--account-label", ACCOUNT_LABEL], {}),
            "main-account": (["--account-label", "main", "--allow-network"], {}),
            "not-a-terminal": (["--account-label", ACCOUNT_LABEL, "--allow-network"],
                               {"isatty": False}),
            "empty-token": (["--account-label", ACCOUNT_LABEL, "--allow-network"],
                            {"token": ""}),
        }
        for name, (argv, kwargs) in cases.items():
            with self.subTest(case=name):
                code, out, _err, transport = self.cli(argv, **kwargs)
                self.assertEqual(code, 3)
                self.assertTrue(out.startswith("BLOCKED: "))
                self.assertEqual(transport.calls(), [])

    def test_a_stage_failure_exits_non_zero_with_a_sanitized_report(self):
        code, out, err, _transport = self.cli(
            ["--account-label", ACCOUNT_LABEL, "--allow-network"],
            responses=[harness.TransportError(TRANSPORT_SENTINEL)])
        self.assertEqual(code, 4)
        report = json.loads(out[out.index("{"):])
        self.assertEqual(report["first_incompatibility"], "vocabulary-transport")
        self.assertEqual(report["write_requests_attempted"], 0)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, out + err)

    def test_the_cli_accepts_no_content_arguments_and_never_echoes_argv(self):
        stream = io.StringIO()
        rejected = [
            ["--account-label", ACCOUNT_LABEL, "--allow-network", "--token", FAKE_TOKEN],
            ["--account-label", ACCOUNT_LABEL, "--word", FOREIGN_PHRASE],
            ["--account-label", ACCOUNT_LABEL, "--voc-id", VOCABULARY_ID],
            ["phrase-readback", "--account-label", ACCOUNT_LABEL],
            [],
        ]
        for argv in rejected:
            with self.subTest(argv=argv[:2]):
                with mock.patch("sys.stderr", stream):
                    with self.assertRaises(SystemExit) as context:
                        diagnostic.parse_args(argv)
                self.assertEqual(context.exception.code, 2)
        printed = stream.getvalue()
        for sentinel in (FAKE_TOKEN, FOREIGN_PHRASE, VOCABULARY_ID):
            self.assertNotIn(sentinel, printed)
        self.assertIn("never accepts a Token on the command line", printed)

    def test_an_internal_failure_prints_no_server_content(self):
        with mock.patch.object(diagnostic, "run_diagnostic",
                               side_effect=RuntimeError(TRANSPORT_SENTINEL)):
            code, out, err, _transport = self.cli(
                ["--account-label", ACCOUNT_LABEL, "--allow-network"])
        self.assertEqual(code, 4)
        self.assertIn(diagnostic.BLOCKED_MESSAGE, out)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, out + err)


class NoWriteMarkerTests(DiagnosticFixtures, unittest.TestCase):
    def test_the_diagnostic_never_touches_the_issue_27_write_once_marker(self):
        source = Path(diagnostic.__file__).read_text(encoding="utf-8")
        self.assertNotIn("PhraseAttemptMarker", source)
        self.assertNotIn(probe.MARKER_NAME, source)
        with mock.patch.object(probe, "PhraseAttemptMarker",
                               side_effect=AssertionError("the marker was consulted")):
            report, transport = self.drive(self.responses())
        self.assertEqual(report["first_incompatibility"], "none")
        self.assertEqual(transport.calls(), EXPECTED_SEQUENCE)

    def test_an_existing_marker_does_not_block_this_read_only_diagnostic(self):
        with mock.patch.object(probe.PhraseAttemptMarker, "assert_absent",
                               side_effect=harness.SafetyError("marker present")):
            report, _transport = self.drive(self.responses())
        self.assertEqual(report["status"], "completed")
        self.assertEqual(report["first_incompatibility"], "none")


class NoNetworkGuardTests(unittest.TestCase):
    def test_the_process_level_network_guard_is_active(self):
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        for call in (lambda: socket.socket(),
                     lambda: socket.create_connection(("open.maimemo.com", 443)),
                     lambda: urllib.request.urlopen("https://open.maimemo.com/")):
            with self.subTest(call=call):
                with self.assertRaises(RuntimeError) as context:
                    call()
                self.assertNotIn("open.maimemo.com", "".join(
                    traceback.format_exception_only(type(context.exception),
                                                    context.exception)))


if __name__ == "__main__":
    unittest.main()
