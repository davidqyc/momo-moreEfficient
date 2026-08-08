"""Issue #27 — the one-shot secondary-account phrase CREATE probe.

Every test here runs offline against an injected fake transport, under the
process-level no-network guard, with an obviously fake credential. No real
Maimemo request is possible and no real Token is read.

The suite is organized around the safety contract rather than around functions:
preflight must reach the preview only from an exactly-zero baseline; the exact
write confirmation is bound to every input; the request set is locked to three
GETs and one POST; one POST is attempted at most once under every failure mode;
the outcome is decided by the readback, never by the POST response body; the
highlight is observed but never sent; and nothing server-provided escapes.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import sys
import tempfile
import traceback
import unittest
from unittest import mock
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import issue9_live_harness as harness  # noqa: E402
import phrase_create_probe as probe  # noqa: E402


FAKE_TOKEN = "FAKE_ISSUE27_CREDENTIAL_NOT_VALID"
ACCOUNT_LABEL = "issue27-secondary-fixture"
VOCABULARY_ID = "INVALID_ISSUE27_VOCABULARY_ID"
RECORD_ID = "INVALID_ISSUE27_PHRASE_RECORD_ID"
OTHER_RECORD_ID = "INVALID_ISSUE27_OTHER_PHRASE_ID"

# Hostile values a production response, a server key name or an external library
# exception could carry. None may appear in stdout, a sanitized summary, a
# repr/str, a formatted traceback or the private attempt marker.
SERVER_KEY = "PRIVATE-ISSUE27-UNKNOWN-SERVER-KEY-SENTINEL"
SERVER_VALUE = "PRIVATE ISSUE27 SERVER VALUE SENTINEL"
POST_BODY_SENTINEL = "PRIVATE ISSUE27 POST RESPONSE BODY SENTINEL"
TRANSPORT_SENTINEL = "PRIVATE-ISSUE27-TRANSPORT-EXCEPTION-SENTINEL"
UNSAFE_ID = "PRIVATE.ISSUE27/RECORD ID+SENTINEL"
FOREIGN_PHRASE = "PRIVATE ISSUE27 FOREIGN PHRASE SENTINEL"
SENTINELS = (
    FAKE_TOKEN, ACCOUNT_LABEL, VOCABULARY_ID, RECORD_ID, OTHER_RECORD_ID, SERVER_KEY,
    SERVER_VALUE, POST_BODY_SENTINEL, TRANSPORT_SENTINEL, UNSAFE_ID, FOREIGN_PHRASE,
)

VOCABULARY_PATH = "/open/api/v1/vocabulary?spelling=acquisition"
PHRASES_PATH = f"/open/api/v1/phrases?voc_id={VOCABULARY_ID}"
CREATE_PATH = "/open/api/v1/phrases"
EXPECTED_SEQUENCE = [
    ("GET", VOCABULARY_PATH), ("GET", PHRASES_PATH),
    ("POST", CREATE_PATH), ("GET", PHRASES_PATH),
]
EXPECTED_BODY = {
    "phrase": {
        "voc_id": VOCABULARY_ID,
        "phrase": "The acquisition strengthened the company's position in the market.",
        "interpretation": "这次收购加强了公司在市场中的地位。",
        "tags": ["MBA", "BEC", "GMAT"],
        "origin": "自编",
    }
}


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

    def posts(self):
        return [request for request in self.requests if request.method == "POST"]


class ProbeFixtures:
    """Shared fixtures for every Issue #27 case."""

    def setUp(self):  # noqa: N802 - unittest hook
        super().setUp()
        harness.PRIVATE_STATE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(harness.PRIVATE_STATE_ROOT, 0o700)

    # --- credentials, markers, plans ---------------------------------------

    def credential(self):
        return harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL)

    def marker(self):
        root = Path(tempfile.mkdtemp(prefix="issue27-", dir=harness.PRIVATE_STATE_ROOT))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        return probe.PhraseAttemptMarker(root)

    def plan(self, **overrides):
        fields = dict(
            account_label=ACCOUNT_LABEL, credential_fingerprint=self.credential().fingerprint,
            returned_spelling="acquisition", vocabulary_id=VOCABULARY_ID,
            preflight_phrase_count=0, request_body=probe.fixed_request_body(VOCABULARY_ID),
        )
        fields.update(overrides)
        return probe.PhraseCreatePlan(**fields)

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

    def post_response(self, status=201):
        """A 2xx acknowledgement whose body is deliberately never trusted."""
        return harness.HttpResponse(status, {
            "phrase": {"id": UNSAFE_ID, SERVER_KEY: POST_BODY_SENTINEL},
            SERVER_KEY: POST_BODY_SENTINEL,
        })

    def success_responses(self, *, wrapped=False, record=None, post=None):
        return [
            self.vocabulary(wrapped=wrapped),
            self.collection([], wrapped=wrapped),
            self.post_response() if post is None else post,
            self.collection([self.record() if record is None else record], wrapped=wrapped),
        ]

    # --- drivers -----------------------------------------------------------

    def drive(self, responses, *, confirmation=None, marker=None, label=ACCOUNT_LABEL):
        """Drive one full run and return everything a test may assert on."""
        transport = FakeTransport(responses)
        marker = marker or self.marker()
        seen = {}

        def confirm(plan):
            seen["plan"] = plan
            seen["preview"] = plan.safe_preview()
            seen["marker_before_confirmation"] = marker.path.exists()
            return plan.expected_confirmation if confirmation is None else confirmation(plan)

        outcome = {"transport": transport, "marker": marker, "seen": seen,
                   "summary": None, "failure": None}
        try:
            outcome["summary"] = probe.run_probe(
                transport, self.credential(), label, confirm, marker)
        except probe.PhraseCreateFailure as failure:
            outcome["failure"] = failure
        return outcome

    def expect_failure(self, responses, **kwargs):
        outcome = self.drive(responses, **kwargs)
        self.assertIsNone(outcome["summary"])
        self.assertIsInstance(outcome["failure"], probe.PhraseCreateFailure)
        return outcome

    def assert_no_post(self, outcome):
        self.assertEqual(outcome["transport"].posts(), [])
        self.assertEqual(outcome["failure"].post_count, 0)
        self.assertFalse(outcome["failure"].post_attempted)
        self.assertEqual(outcome["failure"].write_outcome, "not-attempted")

    def assert_single_post(self, outcome):
        posts = outcome["transport"].posts()
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0].path, CREATE_PATH)

    def rendered(self, error):
        return "".join((
            str(error), repr(error),
            *traceback.format_exception(type(error), error, error.__traceback__),
            repr(getattr(error, "__cause__", None)), repr(getattr(error, "__context__", None)),
            json.dumps(getattr(error, "safe_summary", dict)(), ensure_ascii=False, sort_keys=True),
        ))


# ---------------------------------------------------------------------------
# A. Fixed content and preflight
# ---------------------------------------------------------------------------


class FixedContractTests(ProbeFixtures, unittest.TestCase):
    def test_the_fixed_content_matches_the_issue_contract(self):
        self.assertEqual(probe.SPELLING, "acquisition")
        self.assertEqual(
            probe.PHRASE_TEXT,
            "The acquisition strengthened the company's position in the market.")
        self.assertEqual(probe.TRANSLATION, "这次收购加强了公司在市场中的地位。")
        self.assertEqual(probe.TAGS, ("MBA", "BEC", "GMAT"))
        self.assertEqual(probe.ORIGIN, "自编")
        self.assertEqual(probe.TARGET_SPAN, (4, 15))
        self.assertEqual(probe.PHRASE_TEXT[4:15], "acquisition")
        self.assertEqual(probe.PHRASE_TEXT.count("acquisition"), 1)
        self.assertEqual((probe.MAX_GETS, probe.MAX_POSTS), (3, 1))

    def test_contract_drift_fails_closed(self):
        drifts = {
            "PHRASE_TEXT": "The acquisition helped.", "TRANSLATION": "收购。",
            "TAGS": ("MBA", "BEC"), "ORIGIN": "other", "TARGET_SPAN": (0, 11),
            "CREATE_PATH": "/open/api/v1/interpretations", "MAX_POSTS": 2,
            "CONFIRMATION_PREFIX": harness.WRITE_CONFIRMATION_PREFIX,
        }
        for name, value in drifts.items():
            with self.subTest(constant=name):
                with mock.patch.object(probe, name, value):
                    with self.assertRaises(harness.SafetyError):
                        probe.validate_contract()

    def test_the_frozen_harness_owns_every_reused_primitive(self):
        for name in (
            "TestAccountCredential", "ManualAccountGate", "ProductionHttpTransport",
            "HttpRequest", "build_query_path", "_canonical_probe_vocabulary_body",
            "_canonical_probe_collection_body", "_validate_probe_vocabulary",
            "_safe_record_id", "_read_only_record_status", "_read_only_highlight_shape",
            "_read_only_phrase_length", "_tags_equal", "SanitizedArgumentParser",
        ):
            self.assertTrue(hasattr(harness, name), name)


class PreflightTests(ProbeFixtures, unittest.TestCase):
    def test_documented_and_data_wrapped_previews_are_field_for_field_identical(self):
        documented = self.drive(self.success_responses())
        wrapped = self.drive(self.success_responses(wrapped=True))
        self.assertEqual(documented["seen"]["preview"], wrapped["seen"]["preview"])
        self.assertEqual(documented["summary"], wrapped["summary"])
        self.assertEqual(documented["transport"].calls(), EXPECTED_SEQUENCE)
        self.assertEqual(wrapped["transport"].calls(), EXPECTED_SEQUENCE)

    def test_a_zero_baseline_preview_states_the_whole_write(self):
        preview = self.drive(self.success_responses())["seen"]["preview"]
        self.assertTrue(preview["write"])
        self.assertEqual(preview["operation"], "phrase-create")
        self.assertEqual(preview["method"], "POST")
        self.assertEqual(preview["path"], CREATE_PATH)
        self.assertEqual(preview["requested_spelling"], "acquisition")
        self.assertEqual(preview["phrase"], probe.PHRASE_TEXT)
        self.assertEqual(preview["interpretation"], probe.TRANSLATION)
        self.assertEqual(preview["tags"], ["MBA", "BEC", "GMAT"])
        self.assertEqual(preview["origin"], "自编")
        self.assertEqual(preview["preflight_phrase_count"], 0)
        self.assertEqual(preview["omitted_request_fields"], ["highlight", "status", "id"])
        self.assertEqual(preview["write_policy"],
                         "EXACTLY ONE POST / NO RETRY / IMMEDIATE READBACK")
        self.assertEqual(preview["account_label"], "[REDACTED]")
        self.assertRegex(preview["voc_id_fingerprint"], r"^[0-9a-f]{16}$")
        self.assertRegex(preview["credential_fingerprint"], r"^[0-9a-f]{16}$")
        self.assertRegex(preview["request_body_digest"], r"^[0-9a-f]{64}$")
        self.assertNotIn("vocabulary_id", preview)

    def test_a_nonzero_baseline_blocks_with_zero_posts(self):
        cases = {
            "safety": [self.record()],
            "ambiguous": [self.record(), self.record(id=OTHER_RECORD_ID, phrase=FOREIGN_PHRASE)],
        }
        for failure_class, records in cases.items():
            with self.subTest(existing=len(records)):
                outcome = self.expect_failure([
                    self.vocabulary(), self.collection(records)])
                self.assertEqual(outcome["failure"].failure_class, failure_class)
                self.assertEqual(outcome["failure"].failure_stage, "preflight-phrases")
                self.assert_no_post(outcome)
                self.assertFalse(outcome["marker"].path.exists())
                self.assertEqual(len(outcome["transport"].calls()), 2)

    def test_every_preflight_failure_mode_sends_zero_posts(self):
        cases = {
            "vocabulary-transport": [harness.TransportError(TRANSPORT_SENTINEL)],
            "vocabulary-403": [harness.HttpResponse(403, {"voc": {}})],
            "vocabulary-rejected-body": [harness.TransportResponseError(200, "body-not-object")],
            "vocabulary-missing-voc": [harness.HttpResponse(200, {SERVER_KEY: SERVER_VALUE})],
            "vocabulary-unsafe-id": [self.vocabulary(id=UNSAFE_ID)],
            "vocabulary-mismatch": [self.vocabulary(spelling="acquisitions")],
            "vocabulary-not-object": [harness.HttpResponse(200, {"voc": [SERVER_VALUE]})],
            "phrases-transport": [self.vocabulary(), harness.TransportError(TRANSPORT_SENTINEL)],
            "phrases-500": [self.vocabulary(), self.collection([], status=500)],
            "phrases-not-array": [self.vocabulary(),
                                  harness.HttpResponse(200, {"phrases": SERVER_VALUE})],
            "phrases-bad-status": [self.vocabulary(),
                                   self.collection([self.record(status="DRAFT")])],
            "phrases-duplicate-ids": [self.vocabulary(),
                                      self.collection([self.record(), self.record()])],
            "phrases-unsafe-id": [self.vocabulary(),
                                  self.collection([self.record(id=UNSAFE_ID)])],
        }
        for name, responses in cases.items():
            with self.subTest(case=name):
                outcome = self.expect_failure(responses)
                self.assert_no_post(outcome)
                self.assertFalse(outcome["marker"].path.exists())
                self.assertNotIn("plan", outcome["seen"])
                rendered = self.rendered(outcome["failure"])
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_main_and_production_account_labels_are_rejected(self):
        for label in ("main account", "primary", "prod-account", "主账号", "生产", "owner"):
            with self.subTest(label=label):
                outcome = self.expect_failure(self.success_responses(), label=label)
                self.assert_no_post(outcome)
                self.assertEqual(outcome["transport"].calls(), [])

    def test_no_run_ever_touches_an_interpretation_endpoint(self):
        for outcome in (self.drive(self.success_responses()),
                        self.expect_failure([self.vocabulary(), self.collection([self.record()])])):
            for _method, path in outcome["transport"].calls():
                self.assertNotIn("interpretations", path)
        self.assertNotIn("/open/api/v1/interpretations", str(probe.READ_PATHS))


# ---------------------------------------------------------------------------
# B. The exact write confirmation
# ---------------------------------------------------------------------------


class ConfirmationTests(ProbeFixtures, unittest.TestCase):
    def test_the_confirmation_is_a_phrase_specific_write_confirmation(self):
        confirmation = self.plan().expected_confirmation
        self.assertTrue(confirmation.startswith("CONFIRM ONE REAL PHRASE WRITE: "))
        self.assertIn("WRITE", confirmation)
        self.assertIn("PRICING-TERMS-CHECKED: YES", confirmation)
        self.assertIn("EXACTLY-ONE-POST-NO-RETRY-IMMEDIATE-READBACK", confirmation)
        self.assertIn(f"TOKEN-FP: {self.credential().fingerprint}", confirmation)
        self.assertNotIn(VOCABULARY_ID, confirmation)
        self.assertNotIn(FAKE_TOKEN, confirmation)

    def test_earlier_project_confirmations_can_never_satisfy_this_gate(self):
        plan = self.plan()
        for prefix in (harness.READ_ONLY_CONFIRMATION_PREFIX, harness.WRITE_CONFIRMATION_PREFIX):
            self.assertFalse(plan.expected_confirmation.startswith(prefix))
        for stale in (
            harness._read_only_confirmation_for(
                ACCOUNT_LABEL, self.credential().fingerprint, "acquisition"),
            f"{harness.WRITE_CONFIRMATION_PREFIX}: deadbeefdeadbeef",
        ):
            with self.assertRaises(harness.ConfirmationError):
                plan.validate_confirmation(stale)

    def test_every_bound_input_changes_the_confirmation(self):
        base = self.plan().expected_confirmation
        variants = (
            self.plan(account_label="another-secondary-test").expected_confirmation,
            self.plan(credential_fingerprint="0" * 16).expected_confirmation,
            self.plan(vocabulary_id="INVALID_ISSUE27_OTHER_VOC",
                      request_body=probe.fixed_request_body(
                          "INVALID_ISSUE27_OTHER_VOC")).expected_confirmation,
        )
        self.assertEqual(len({base, *variants}), 1 + len(variants))

    def test_a_body_that_disagrees_with_the_bound_vocabulary_id_is_rejected(self):
        with self.assertRaises(harness.SafetyError):
            self.plan(vocabulary_id="INVALID_ISSUE27_OTHER_VOC")

    def test_one_character_or_type_mismatch_blocks_the_write(self):
        plan = self.plan()
        exact = plan.expected_confirmation
        for wrong in (exact + " ", " " + exact, exact[:-1], exact.upper(), None, 3, b"x"):
            with self.subTest(confirmation=repr(wrong)[:32]):
                with self.assertRaises(harness.ConfirmationError):
                    plan.validate_confirmation(wrong)
        plan.validate_confirmation(exact)

    def test_a_wrong_confirmation_sends_zero_posts_and_arms_no_marker(self):
        outcome = self.expect_failure(
            self.success_responses(), confirmation=lambda plan: "CONFIRM ONE REAL PHRASE WRITE: x")
        self.assertEqual(outcome["failure"].failure_class, "confirmation")
        self.assert_no_post(outcome)
        self.assertFalse(outcome["marker"].path.exists())

    def test_a_tampered_plan_can_never_be_constructed(self):
        tampered = {
            "highlight": dict(EXPECTED_BODY["phrase"], highlight=[[4, 15]]),
            "status": dict(EXPECTED_BODY["phrase"], status="PUBLISHED"),
            "other-phrase": dict(EXPECTED_BODY["phrase"], phrase=FOREIGN_PHRASE),
            "other-origin": dict(EXPECTED_BODY["phrase"], origin="other"),
            "two-tags": dict(EXPECTED_BODY["phrase"], tags=["MBA", "BEC"]),
        }
        for name, entity in tampered.items():
            with self.subTest(body=name):
                with self.assertRaises(harness.SafetyError):
                    self.plan(request_body={"phrase": entity})
        for count in (1, 2, True):
            with self.subTest(preflight_count=count):
                with self.assertRaises(harness.SafetyError):
                    self.plan(preflight_phrase_count=count)


# ---------------------------------------------------------------------------
# C. The locked request contract and the single POST
# ---------------------------------------------------------------------------


class RequestContractTests(ProbeFixtures, unittest.TestCase):
    def test_the_exact_sequence_and_post_body_are_locked(self):
        outcome = self.drive(self.success_responses())
        self.assertEqual(outcome["transport"].calls(), EXPECTED_SEQUENCE)
        sent = harness._thaw_json(outcome["transport"].posts()[0].payload)
        self.assertEqual(sent, EXPECTED_BODY)
        self.assertEqual(list(sent), ["phrase"])
        self.assertEqual(set(sent["phrase"]), set(probe.BODY_FIELDS))

    def test_the_post_body_omits_highlight_status_and_every_undocumented_key(self):
        sent = harness._thaw_json(
            self.drive(self.success_responses())["transport"].posts()[0].payload)
        for forbidden in ("highlight", "status", "id", "voc", "range", "chinese_range"):
            self.assertNotIn(forbidden, sent["phrase"])
            self.assertNotIn(forbidden, sent)

    def test_the_sent_body_is_the_same_frozen_body_as_the_preview_digest(self):
        outcome = self.drive(self.success_responses())
        plan = outcome["seen"]["plan"]
        sent = harness._thaw_json(outcome["transport"].posts()[0].payload)
        digest = harness._fingerprint(probe._canonical(sent))["sha256"]
        self.assertEqual(digest, plan.request_body_digest)
        self.assertEqual(digest, outcome["seen"]["preview"]["request_body_digest"])
        with self.assertRaises(TypeError):
            plan.request_body["phrase"]["origin"] = "mutated"

    def test_the_guard_refuses_every_non_reviewed_request(self):
        guard = probe.SinglePhraseWriteGuard(FakeTransport([]))
        rejected = [
            harness.HttpRequest("POST", "/open/api/v1/interpretations", EXPECTED_BODY),
            harness.HttpRequest("POST", f"{CREATE_PATH}/{RECORD_ID}", EXPECTED_BODY),
            harness.HttpRequest("GET", "/open/api/v1/interpretations?voc_id=x"),
        ]
        for request in rejected:
            with self.subTest(path=request.path):
                with self.assertRaises(harness.SafetyError):
                    guard.send(request, self.credential())
        for method in ("PUT", "PATCH", "DELETE", "HEAD"):
            with self.subTest(method=method):
                with self.assertRaises(harness.SafetyError):
                    harness.HttpRequest(method, CREATE_PATH, EXPECTED_BODY)
        self.assertEqual((guard.get_count, guard.post_count), (0, 0))

    def test_the_guard_caps_gets_at_three_and_posts_at_one(self):
        delegate = FakeTransport([self.collection([]) for _ in range(4)])
        guard = probe.SinglePhraseWriteGuard(delegate)
        request = harness.HttpRequest("GET", PHRASES_PATH)
        for _ in range(probe.MAX_GETS):
            guard.send(request, self.credential())
        with self.assertRaises(harness.SafetyError):
            guard.send(request, self.credential())
        self.assertEqual(guard.get_count, probe.MAX_GETS)

    def test_a_second_post_is_structurally_impossible(self):
        delegate = FakeTransport([self.post_response(), self.post_response()])
        guard = probe.SinglePhraseWriteGuard(delegate)
        write = harness.HttpRequest("POST", CREATE_PATH, EXPECTED_BODY)
        guard.send(write, self.credential())
        with self.assertRaises(harness.SafetyError):
            guard.send(write, self.credential())
        self.assertEqual(guard.post_count, 1)
        self.assertEqual(len(delegate.posts()), 1)

    def test_the_post_budget_is_consumed_before_the_delegate_runs(self):
        class Exploding:
            def __init__(self, guard):
                self.guard, self.attempts = guard, 0

            def send(self, _request, _credential):
                self.attempts += 1
                assert self.guard["guard"].post_count == 1, "the budget must be spent first"
                raise harness.TransportError(TRANSPORT_SENTINEL)

        holder = {}
        delegate = Exploding(holder)
        guard = probe.SinglePhraseWriteGuard(delegate)
        holder["guard"] = guard
        with self.assertRaises(harness.TransportError):
            guard.send(harness.HttpRequest("POST", CREATE_PATH, EXPECTED_BODY), self.credential())
        self.assertEqual((guard.post_count, delegate.attempts), (1, 1))
        with self.assertRaises(harness.SafetyError):
            guard.send(harness.HttpRequest("POST", CREATE_PATH, EXPECTED_BODY), self.credential())
        self.assertEqual(delegate.attempts, 1)


# ---------------------------------------------------------------------------
# D. Success, uncertain-POST recovery and fail-closed readback
# ---------------------------------------------------------------------------


class OutcomeTests(ProbeFixtures, unittest.TestCase):
    def test_a_clear_success_reports_only_sanitized_project_fields(self):
        summary = self.drive(self.success_responses())["summary"]
        self.assertEqual(summary["mode"], "phrase-create-probe")
        self.assertEqual(summary["status"], "succeeded")
        self.assertEqual(summary["write_outcome"], "confirmed-success")
        self.assertEqual(summary["operation"], "create")
        self.assertEqual(summary["requested_spelling"], "acquisition")
        self.assertEqual(summary["preflight_count"], 0)
        self.assertEqual(summary["post_write_count"], 1)
        self.assertEqual(summary["intended_tags"], ["MBA", "BEC", "GMAT"])
        self.assertEqual(summary["origin"], "自编")
        self.assertEqual(summary["post_http_status"], 201)
        self.assertEqual(summary["readback_http_status"], 200)
        self.assertEqual(summary["post_count"], 1)
        self.assertTrue(summary["readback_attempted"])
        self.assertEqual(summary["requests_attempted"], 4)
        self.assertEqual(summary["requests_completed"], 4)
        self.assertEqual(
            summary["voc_id_fingerprint"], harness._fingerprint(VOCABULARY_ID)["sha256"][:16])
        self.assertEqual(
            summary["phrase_record_id_fingerprint"],
            harness._fingerprint(RECORD_ID)["sha256"][:16])

    def test_server_tag_order_is_accepted_as_a_set(self):
        for tags in (["MBA", "BEC", "GMAT"], ["GMAT", "MBA", "BEC"], ["BEC", "GMAT", "MBA"]):
            with self.subTest(tags=tags):
                outcome = self.drive(self.success_responses(record=self.record(tags=tags)))
                self.assertEqual(outcome["summary"]["status"], "succeeded")

    def test_the_post_response_body_is_never_trusted_or_echoed(self):
        outcome = self.drive(self.success_responses())
        rendered = json.dumps(outcome["summary"], ensure_ascii=False, sort_keys=True)
        rendered += outcome["marker"].path.read_text(encoding="utf-8")
        for sentinel in (UNSAFE_ID, POST_BODY_SENTINEL, SERVER_KEY, SERVER_VALUE):
            self.assertNotIn(sentinel, rendered)

    def test_every_uncertain_post_recovers_through_exactly_one_readback(self):
        cases = {
            "timeout": harness.TransportError(TRANSPORT_SENTINEL),
            "rejected-body": harness.TransportResponseError(200, "body-invalid-json"),
            "server-error": harness.HttpResponse(500, {SERVER_KEY: POST_BODY_SENTINEL}),
            "client-error": harness.HttpResponse(409, {SERVER_KEY: POST_BODY_SENTINEL}),
            "unusable-response": object(),
        }
        for name, post in cases.items():
            with self.subTest(case=name):
                outcome = self.drive(self.success_responses(post=post))
                summary = outcome["summary"]
                self.assertEqual(summary["status"], "recovered-succeeded")
                self.assertEqual(summary["write_outcome"], "recovered-success")
                self.assertEqual(summary["post_count"], 1)
                self.assertEqual(outcome["transport"].calls(), EXPECTED_SEQUENCE)
                self.assert_single_post(outcome)

    def test_readback_shape_failures_are_fail_closed_after_exactly_one_post(self):
        cases = {
            "empty": (self.collection([]), "unknown-write-outcome", "not-verified"),
            "multiple": (self.collection([self.record(), self.record(id=OTHER_RECORD_ID)]),
                         "ambiguous", "ambiguous"),
            "transport": (harness.TransportError(TRANSPORT_SENTINEL), "transport", "not-verified"),
            "non-2xx": (self.collection([self.record()], status=503),
                        "http-status", "not-verified"),
            "not-an-array": (harness.HttpResponse(200, {"phrases": SERVER_VALUE}),
                             "schema", "not-verified"),
        }
        for name, (readback, failure_class, outcome_name) in cases.items():
            with self.subTest(case=name):
                responses = self.success_responses()
                responses[-1] = readback
                outcome = self.expect_failure(responses)
                failure = outcome["failure"]
                self.assertEqual(failure.failure_stage, "readback")
                self.assertEqual(failure.failure_class, failure_class)
                self.assertEqual(failure.write_outcome, outcome_name)
                self.assertEqual(failure.post_count, 1)
                self.assertTrue(failure.readback_attempted)
                self.assert_single_post(outcome)

    def test_every_field_mismatch_fails_closed(self):
        cases = {
            "phrase": {"phrase": FOREIGN_PHRASE},
            "phrase-whitespace": {"phrase": probe.PHRASE_TEXT + " "},
            "translation": {"interpretation": "收购加强了地位。"},
            "origin": {"origin": "other"},
            "origin-missing": {"origin": None},
            "status-deleted": {"status": "DELETED"},
            "tags-two": {"tags": ["MBA", "BEC"]},
            "tags-four": {"tags": ["MBA", "BEC", "GMAT", "TOEFL"]},
            "tags-duplicate": {"tags": ["MBA", "MBA", "BEC"]},
            "tags-extra": {"tags": ["MBA", "BEC", "TOEFL"]},
            "tags-not-a-list": {"tags": "MBA"},
            "unsafe-id": {"id": UNSAFE_ID},
        }
        for name, overrides in cases.items():
            with self.subTest(case=name):
                responses = self.success_responses(record=self.record(**overrides))
                outcome = self.expect_failure(responses)
                failure = outcome["failure"]
                self.assertEqual(failure.failure_stage, "readback")
                self.assertIn(failure.failure_class, ("mismatch", "schema"))
                self.assertEqual(failure.write_outcome, "not-verified")
                self.assertEqual(failure.post_count, 1)
                self.assert_single_post(outcome)

    def test_an_uncertain_post_plus_a_failed_readback_stays_fail_closed(self):
        responses = self.success_responses(post=harness.TransportError(TRANSPORT_SENTINEL))
        responses[-1] = self.collection([])
        outcome = self.expect_failure(responses)
        self.assertEqual(outcome["failure"].write_outcome, "not-verified")
        self.assertEqual(outcome["failure"].post_count, 1)
        self.assert_single_post(outcome)

    def test_no_failure_path_ever_sends_a_second_post(self):
        for post in (harness.TransportError(TRANSPORT_SENTINEL),
                     harness.HttpResponse(502, {SERVER_KEY: POST_BODY_SENTINEL})):
            for readback in (self.collection([]), harness.TransportError(TRANSPORT_SENTINEL)):
                with self.subTest(post=type(post).__name__):
                    responses = self.success_responses(post=post)
                    responses[-1] = readback
                    outcome = self.expect_failure(responses)
                    self.assertEqual(len(outcome["transport"].posts()), 1)
                    self.assertEqual(
                        [call for call in outcome["transport"].calls()
                         if call[0] == "POST"], [("POST", CREATE_PATH)])


# ---------------------------------------------------------------------------
# E. The highlight observation
# ---------------------------------------------------------------------------


class HighlightTests(ProbeFixtures, unittest.TestCase):
    def observed(self, highlight):
        outcome = self.drive(self.success_responses(record=self.record(highlight=highlight)))
        self.assertIsNotNone(outcome["summary"], highlight)
        return outcome["summary"]["highlight_shape"], outcome["summary"]["highlight_verdict"]

    def test_the_exact_target_span_is_reported_in_both_reviewed_shapes(self):
        self.assertEqual(self.observed([[4, 15]]), ("integer-pair-array", "exact-target-span"))
        self.assertEqual(self.observed([{"start": 4, "end": 15}]),
                         ("object-range-array", "exact-target-span"))

    def test_an_empty_highlight_is_reported_as_empty(self):
        self.assertEqual(self.observed([]), ("empty-array", "empty"))

    def test_other_reviewed_ranges_are_reported_as_other(self):
        cases = {
            "different-pair": [[0, 3]],
            "two-pairs": [[4, 15], [16, 28]],
            "different-object": [{"start": 0, "end": 3}],
            "whole-sentence": [[0, len(probe.PHRASE_TEXT)]],
        }
        for name, highlight in cases.items():
            with self.subTest(case=name):
                shape, verdict = self.observed(highlight)
                self.assertIn(shape, probe.SHAPES)
                self.assertEqual(verdict, "other-reviewed-range")

    def test_malformed_or_out_of_bounds_highlight_fails_closed(self):
        cases = {
            "missing": None,
            "not-a-list": {"start": 4, "end": 15},
            "negative": [[-1, 15]],
            "inverted": [[15, 4]],
            "empty-range": [[4, 4]],
            "out-of-bounds": [[4, len(probe.PHRASE_TEXT) + 1]],
            "mixed-shapes": [[4, 15], {"start": 4, "end": 15}],
            "booleans": [[True, False]],
            "triple": [[4, 15, 20]],
            "string-range": [["4", "15"]],
        }
        for name, highlight in cases.items():
            with self.subTest(case=name):
                record = self.record()
                if highlight is None:
                    record.pop("highlight")
                else:
                    record["highlight"] = highlight
                outcome = self.expect_failure(self.success_responses(record=record))
                self.assertEqual(outcome["failure"].failure_stage, "readback")
                self.assertEqual(outcome["failure"].failure_class, "schema")
                self.assertEqual(outcome["failure"].write_outcome, "not-verified")
                self.assert_single_post(outcome)

    def test_the_verdict_enum_stays_closed(self):
        self.assertEqual(probe.VERDICTS, ("exact-target-span", "empty", "other-reviewed-range"))
        self.assertNotIn("invalid", probe.VERDICTS)
        self.assertEqual(probe.SHAPES,
                         ("integer-pair-array", "object-range-array", "empty-array"))


# ---------------------------------------------------------------------------
# F. The write-once attempt marker
# ---------------------------------------------------------------------------


class AttemptMarkerTests(ProbeFixtures, unittest.TestCase):
    def test_the_marker_is_armed_between_confirmation_and_the_post(self):
        outcome = self.drive(self.success_responses())
        self.assertFalse(outcome["seen"]["marker_before_confirmation"])
        self.assertTrue(outcome["marker"].path.is_file())
        document = json.loads(outcome["marker"].path.read_text(encoding="utf-8"))
        self.assertTrue(document["armed"])
        self.assertEqual(document["operation"], "phrase-create")
        self.assertEqual(document["requested_spelling"], "acquisition")
        self.assertEqual(document["path"], CREATE_PATH)
        self.assertEqual(document["voc_id_fingerprint"],
                         harness._fingerprint(VOCABULARY_ID)["sha256"][:16])
        self.assertRegex(document["request_body_digest"], r"^[0-9a-f]{64}$")

    def test_the_marker_carries_no_secret_raw_id_or_response(self):
        outcome = self.drive(self.success_responses())
        text = outcome["marker"].path.read_text(encoding="utf-8")
        for sentinel in (FAKE_TOKEN, ACCOUNT_LABEL, VOCABULARY_ID, RECORD_ID,
                         SERVER_KEY, SERVER_VALUE, POST_BODY_SENTINEL, UNSAFE_ID):
            self.assertNotIn(sentinel, text)
        document = json.loads(text)
        harness._assert_no_sensitive_keys(document, "marker")
        for key in document:
            self.assertNotIn("authorization", key.casefold())
            self.assertNotIn("token", key.casefold())

    def test_marker_permissions_stay_restrictive(self):
        outcome = self.drive(self.success_responses())
        marker = outcome["marker"]
        self.assertEqual(stat.S_IMODE(marker.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(marker.root.stat().st_mode), 0o700)
        self.assertFalse(marker.path.is_symlink())

    def test_an_existing_marker_blocks_replay_before_any_request(self):
        marker = self.marker()
        first = self.drive(self.success_responses(), marker=marker)
        self.assertIsNotNone(first["summary"])
        second = self.expect_failure(self.success_responses(), marker=marker)
        self.assert_no_post(second)
        self.assertEqual(second["transport"].calls(), [])
        self.assertEqual(second["failure"].failure_class, "safety")

    def test_a_symlinked_marker_path_blocks_the_write(self):
        marker = self.marker()
        os.symlink(marker.root / "elsewhere.json", marker.path)
        outcome = self.expect_failure(self.success_responses(), marker=marker)
        self.assert_no_post(outcome)
        self.assertEqual(outcome["transport"].calls(), [])

    def test_a_marker_that_cannot_be_created_blocks_the_post(self):
        marker = self.marker()
        with mock.patch.object(probe.os, "open", side_effect=OSError("no space")):
            outcome = self.expect_failure(self.success_responses(), marker=marker)
        self.assert_no_post(outcome)
        self.assertEqual(outcome["failure"].failure_stage, "write")
        self.assertEqual(outcome["failure"].failure_class, "safety")
        self.assertEqual(outcome["transport"].calls(), EXPECTED_SEQUENCE[:2])
        self.assertFalse(marker.path.exists())

    def test_the_marker_must_stay_below_artifacts_private(self):
        for outside in (ROOT, ROOT / "scripts", Path(tempfile.gettempdir())):
            with self.subTest(root=str(outside)):
                with self.assertRaises(harness.SafetyError):
                    probe.PhraseAttemptMarker(outside)
        self.assertTrue(str(self.marker().root).startswith(str(harness.PRIVATE_STATE_ROOT)))

    def test_the_marker_never_transitions_after_the_write(self):
        outcome = self.drive(self.success_responses())
        document = json.loads(outcome["marker"].path.read_text(encoding="utf-8"))
        self.assertEqual(document["statement"], probe.MARKER_STATEMENT)
        self.assertNotIn("status", document)
        self.assertNotIn("write_outcome", document)
        with self.assertRaises(harness.SafetyError):
            outcome["marker"].arm(document)


# ---------------------------------------------------------------------------
# G. Containment, the CLI and the process-level network guard
# ---------------------------------------------------------------------------


class ContainmentTests(ProbeFixtures, unittest.TestCase):
    def test_no_sentinel_escapes_a_successful_run(self):
        outcome = self.drive(self.success_responses())
        rendered = json.dumps(outcome["summary"], ensure_ascii=False, sort_keys=True)
        rendered += repr(outcome["seen"]["plan"]) + str(outcome["seen"]["plan"])
        rendered += json.dumps(outcome["seen"]["preview"], ensure_ascii=False, sort_keys=True)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)

    def test_no_sentinel_escapes_a_failing_run_or_its_traceback(self):
        responses = self.success_responses(post=harness.TransportError(TRANSPORT_SENTINEL))
        responses[-1] = self.collection([self.record(phrase=FOREIGN_PHRASE)])
        failure = self.expect_failure(responses)["failure"]
        rendered = self.rendered(failure)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        self.assertIsNone(failure.__cause__)
        self.assertIsNone(failure.__context__)

    def test_the_failure_summary_only_carries_closed_enums_and_counters(self):
        failure = self.expect_failure([self.vocabulary(), self.collection([self.record()])])["failure"]
        summary = failure.safe_summary()
        self.assertEqual(set(summary), {
            "mode", "status", "operation", "failure_stage", "failure_class", "http_status",
            "post_attempted", "post_count", "readback_attempted", "write_outcome",
            "requests_attempted", "requests_completed"})
        self.assertIn(summary["failure_stage"], probe.STAGES)
        self.assertIn(summary["failure_class"], probe.CLASSES)
        self.assertIn(summary["write_outcome"], probe.OUTCOMES)

    def test_a_failure_can_never_claim_a_successful_write(self):
        progress = probe.Progress(probe.SinglePhraseWriteGuard(FakeTransport([])))
        for outcome in ("confirmed-success", "recovered-success"):
            with self.subTest(outcome=outcome):
                with self.assertRaises(harness.SafetyError):
                    probe.PhraseCreateFailure(progress, "readback", "schema", 200, outcome)


class CliTests(ProbeFixtures, unittest.TestCase):
    def cli(self, argv, *, responses=None, token=FAKE_TOKEN, confirmation=None,
            isatty=True, marker=None):
        marker = marker or self.marker()
        transport = FakeTransport(responses or self.success_responses())
        stream = io.StringIO()

        def confirm_prompt(_message):
            return confirmation if confirmation is not None else self.plan().expected_confirmation

        with mock.patch("sys.stdout", stream):
            code = probe.main(
                argv, token_prompt=lambda _m: token, confirmation_prompt=confirm_prompt,
                transport_factory=lambda: transport, stdin_isatty=lambda: isatty,
                marker_factory=lambda: marker)
        return code, stream.getvalue(), transport, marker

    def test_the_documented_command_succeeds_and_prints_a_sanitized_summary(self):
        argv = ["--account-label", ACCOUNT_LABEL, "--allow-network"]
        code, output, transport, _marker = self.cli(argv)
        self.assertEqual(code, 0)
        self.assertIn("PHRASE CREATE PROBE — WRITE —", output)
        self.assertIn('"status": "succeeded"', output)
        self.assertIn('"highlight_verdict": "exact-target-span"', output)
        self.assertEqual(transport.calls(), EXPECTED_SEQUENCE)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, output)

    def test_local_gates_block_before_any_request(self):
        cases = {
            "no-allow-network": (["--account-label", ACCOUNT_LABEL], {}),
            "main-account": (["--account-label", "main", "--allow-network"], {}),
            "not-a-terminal": (["--account-label", ACCOUNT_LABEL, "--allow-network"],
                               {"isatty": False}),
            "empty-token": (["--account-label", ACCOUNT_LABEL, "--allow-network"], {"token": ""}),
        }
        for name, (argv, kwargs) in cases.items():
            with self.subTest(case=name):
                code, output, transport, marker = self.cli(argv, **kwargs)
                self.assertEqual(code, 3)
                self.assertTrue(output.startswith("BLOCKED: "))
                self.assertEqual(transport.calls(), [])
                self.assertFalse(marker.path.exists())

    def test_an_existing_marker_blocks_the_command(self):
        marker = self.marker()
        marker.arm({"armed": True, "mode": probe.MODE})
        code, output, transport, _marker = self.cli(
            ["--account-label", ACCOUNT_LABEL, "--allow-network"], marker=marker)
        self.assertEqual(code, 3)
        self.assertIn("BLOCKED", output)
        self.assertEqual(transport.calls(), [])

    def test_a_failing_run_prints_one_sanitized_diagnostic(self):
        code, output, transport, _marker = self.cli(
            ["--account-label", ACCOUNT_LABEL, "--allow-network"],
            responses=[self.vocabulary(), self.collection([self.record()])])
        self.assertEqual(code, 4)
        diagnostic = json.loads(output[output.index("{"):])
        self.assertEqual(diagnostic["status"], "failed")
        self.assertEqual(diagnostic["post_count"], 0)
        self.assertEqual(diagnostic["write_outcome"], "not-attempted")
        self.assertEqual(transport.posts(), [])
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, output)

    def test_the_cli_accepts_no_content_arguments_and_never_echoes_argv(self):
        stream = io.StringIO()
        rejected = [
            ["--account-label", ACCOUNT_LABEL, "--allow-network", "--token", FAKE_TOKEN],
            ["--account-label", ACCOUNT_LABEL, "--phrase", FOREIGN_PHRASE],
            ["--account-label", ACCOUNT_LABEL, "--voc-id", VOCABULARY_ID],
            ["read-only-probe", "--account-label", ACCOUNT_LABEL],
            [],
        ]
        for argv in rejected:
            with self.subTest(argv=argv[:2]):
                with mock.patch("sys.stderr", stream):
                    with self.assertRaises(SystemExit) as context:
                        probe.parse_args(argv)
                self.assertEqual(context.exception.code, 2)
        printed = stream.getvalue()
        for sentinel in (FAKE_TOKEN, FOREIGN_PHRASE, VOCABULARY_ID):
            self.assertNotIn(sentinel, printed)
        self.assertIn("never accepts a Token on the command line", printed)


class NoNetworkGuardTests(unittest.TestCase):
    def test_the_process_level_network_guard_is_active(self):
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        for call in (lambda: socket.socket(),
                     lambda: socket.create_connection(("open.maimemo.com", 443)),
                     lambda: urllib.request.urlopen("https://open.maimemo.com/")):
            with self.subTest(call=call):
                with self.assertRaises(RuntimeError):
                    call()


if __name__ == "__main__":
    unittest.main()
