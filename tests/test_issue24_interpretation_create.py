"""Issue #24 — the one-shot secondary-account interpretation CREATE probe.

Every test here runs offline against an injected fake transport, under the
process-level no-network guard, with an obviously fake credential. No real
Maimemo request is possible and no real Token is read.

The suite is organized around the safety contract rather than around functions:

* preflight must reach the preview only from an exactly-zero baseline;
* the exact write confirmation must be bound to every input;
* the reviewed request set is locked to three GETs and one POST;
* one POST is attempted at most once, ever, under every failure mode;
* the write outcome is decided by the post-write readback, never by the POST
  response body;
* nothing server-provided may escape into output, journals or tracebacks.
"""

from __future__ import annotations

from collections.abc import Mapping
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import stat
import sys
import tempfile
import traceback
import unittest
from unittest import mock
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import issue9_live_harness as harness  # noqa: E402


FAKE_TOKEN = "FAKE_ISSUE24_CREDENTIAL_NOT_VALID"
ACCOUNT_LABEL = "issue24-secondary-fixture"
VOCABULARY_ID = "INVALID_ISSUE24_VOCABULARY_ID"
CREATED_RECORD_ID = "INVALID_ISSUE24_CREATED_INTERPRETATION_ID"
OTHER_RECORD_ID = "INVALID_ISSUE24_OTHER_INTERPRETATION_ID"

# Hostile values a production response, a server key name or an external library
# exception could carry. None of them may appear in stdout, stderr, a sanitized
# diagnostic, a repr/str, a formatted traceback or the private journal.
SERVER_KEY_SENTINEL = "PRIVATE-ISSUE24-UNKNOWN-SERVER-KEY-SENTINEL"
SERVER_VALUE_SENTINEL = "PRIVATE ISSUE24 SERVER VALUE SENTINEL"
POST_RESPONSE_SENTINEL = "PRIVATE ISSUE24 POST RESPONSE BODY SENTINEL"
TRANSPORT_EXCEPTION_SENTINEL = "PRIVATE-ISSUE24-TRANSPORT-EXCEPTION-SENTINEL"
PRODUCTION_IO_SENTINEL = "PRIVATE-ISSUE24-PRODUCTION-IO-SENTINEL"
UNSAFE_RECORD_ID_SENTINEL = "PRIVATE.ISSUE24/RECORD ID+SENTINEL"
FOREIGN_INTERPRETATION_SENTINEL = "PRIVATE ISSUE24 FOREIGN INTERPRETATION SENTINEL"
SENTINELS = (
    FAKE_TOKEN,
    ACCOUNT_LABEL,
    VOCABULARY_ID,
    CREATED_RECORD_ID,
    OTHER_RECORD_ID,
    SERVER_KEY_SENTINEL,
    SERVER_VALUE_SENTINEL,
    POST_RESPONSE_SENTINEL,
    TRANSPORT_EXCEPTION_SENTINEL,
    PRODUCTION_IO_SENTINEL,
    UNSAFE_RECORD_ID_SENTINEL,
    FOREIGN_INTERPRETATION_SENTINEL,
)

VOCABULARY_PATH = "/open/api/v1/vocabulary?spelling=acquisition"
INTERPRETATIONS_PATH = f"/open/api/v1/interpretations?voc_id={VOCABULARY_ID}"
CREATE_PATH = "/open/api/v1/interpretations"
EXPECTED_BODY = {
    "interpretation": {
        "voc_id": VOCABULARY_ID,
        "interpretation": "n. 收购；购置；获得",
        "tags": ["MBA", "BEC", "GMAT"],
        "status": "PUBLISHED",
    }
}


class FakeTransport:
    """Queued in-memory transport. It never touches a socket."""

    def __init__(self, responses: list[object]) -> None:
        self.responses = list(responses)
        self.requests: list[harness.HttpRequest] = []

    def send(
        self,
        request: harness.HttpRequest,
        _credential: harness.TestAccountCredential,
    ) -> object:
        self.requests.append(request)
        if not self.responses:
            raise AssertionError("the fake transport received an unexpected request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response

    def calls(self) -> list[tuple[str, str]]:
        return [(request.method, request.path) for request in self.requests]

    def posts(self) -> list[harness.HttpRequest]:
        return [request for request in self.requests if request.method == "POST"]


class InterpretationCreateFixtures:
    """Shared fixtures for every Issue #24 case."""

    def setUp(self) -> None:  # noqa: N802 - unittest hook
        super().setUp()
        harness.PRIVATE_STATE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(harness.PRIVATE_STATE_ROOT, 0o700)

    # --- credentials and stores -------------------------------------------

    def credential(self) -> harness.TestAccountCredential:
        return harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL)

    def make_store(self) -> tuple[Path, harness.PrivateStateStore]:
        root = Path(
            tempfile.mkdtemp(prefix="issue24-", dir=harness.PRIVATE_STATE_ROOT)
        )
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        return root, harness.PrivateStateStore(
            root, journal_prefix=harness.INTERPRETATION_CREATE_JOURNAL_PREFIX
        )

    # --- response builders -------------------------------------------------

    def vocabulary_body(self, *, wrapped: bool = False, **overrides: object) -> dict:
        record: dict[str, object] = {
            "id": VOCABULARY_ID,
            "spelling": "acquisition",
            SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL,
        }
        record.update(overrides)
        if wrapped:
            return {"data": {"voc": record}, SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL}
        return {"voc": record, SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL}

    def vocabulary_response(self, **kwargs: object) -> harness.HttpResponse:
        return harness.HttpResponse(200, self.vocabulary_body(**kwargs))

    def created_record(self, **overrides: object) -> dict:
        record: dict[str, object] = {
            "id": CREATED_RECORD_ID,
            "interpretation": harness.INTERPRETATION_CREATE_TEXT,
            "tags": ["MBA", "BEC", "GMAT"],
            "status": "PUBLISHED",
            SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL,
        }
        record.update(overrides)
        return record

    def foreign_record(self, **overrides: object) -> dict:
        fields: dict[str, object] = {
            "id": OTHER_RECORD_ID,
            "interpretation": FOREIGN_INTERPRETATION_SENTINEL,
        }
        fields.update(overrides)
        return self.created_record(**fields)

    def collection_response(
        self,
        records: object,
        *,
        wrapped: bool = False,
        status: int = 200,
    ) -> harness.HttpResponse:
        if wrapped:
            body: dict[str, object] = {
                "data": {"interpretations": records},
                SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL,
            }
        else:
            body = {
                "interpretations": records,
                SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL,
            }
        return harness.HttpResponse(status, body)

    def post_response(self, status: int = 200) -> harness.HttpResponse:
        """A 2xx acknowledgement whose body is deliberately never trusted."""
        return harness.HttpResponse(
            status,
            {
                "interpretation": {
                    "id": UNSAFE_RECORD_ID_SENTINEL,
                    SERVER_KEY_SENTINEL: POST_RESPONSE_SENTINEL,
                },
                SERVER_KEY_SENTINEL: POST_RESPONSE_SENTINEL,
            },
        )

    def success_responses(self, *, wrapped: bool = False) -> list[object]:
        return [
            self.vocabulary_response(wrapped=wrapped),
            self.collection_response([], wrapped=wrapped),
            self.post_response(),
            self.collection_response([self.created_record()], wrapped=wrapped),
        ]

    # --- drivers -----------------------------------------------------------

    def preflight(
        self, responses: list[object]
    ) -> tuple[harness.InterpretationCreateExecutor, FakeTransport, object]:
        transport = FakeTransport(responses)
        executor = harness.InterpretationCreateExecutor(transport)
        plan = executor.preflight(self.credential(), ACCOUNT_LABEL)
        return executor, transport, plan

    def expect_preflight_failure(
        self, responses: list[object]
    ) -> tuple[harness.InterpretationCreateFailure, FakeTransport]:
        transport = FakeTransport(responses)
        executor = harness.InterpretationCreateExecutor(transport)
        with self.assertRaises(harness.InterpretationCreateFailure) as context:
            executor.preflight(self.credential(), ACCOUNT_LABEL)
        self.assertEqual(executor.post_count, 0)
        self.assertEqual(transport.posts(), [])
        return context.exception, transport

    def run_probe(
        self,
        responses: list[object],
        *,
        confirmation: object = None,
        tamper: object = None,
        store: harness.PrivateStateStore | None = None,
    ) -> dict[str, object]:
        """Drive preflight + commit and return everything a test may assert on."""
        transport = FakeTransport(responses)
        executor = harness.InterpretationCreateExecutor(transport)
        test_credential = self.credential()
        if store is None:
            _root, store = self.make_store()
        plan = executor.preflight(test_credential, ACCOUNT_LABEL)
        if callable(tamper):
            tamper(plan)
        provided = plan.expected_confirmation if confirmation is None else confirmation
        outcome: dict[str, object] = {
            "transport": transport,
            "executor": executor,
            "plan": plan,
            "store": store,
        }
        try:
            outcome["result"] = executor.commit(
                plan, provided, test_credential, state_store=store
            )
            outcome["failure"] = None
        except harness.InterpretationCreateFailure as failure:
            outcome["result"] = None
            outcome["failure"] = failure
        try:
            outcome["journal"] = store.read(
                harness.INTERPRETATION_CREATE_JOURNAL_SEQUENCE
            )
        except harness.SafetyError:
            outcome["journal"] = None
        return outcome

    def assert_single_post(self, outcome: Mapping[str, object]) -> None:
        transport = outcome["transport"]
        self.assertEqual(len(transport.posts()), 1)
        self.assertEqual(outcome["executor"].post_count, 1)
        self.assertEqual(transport.posts()[0].path, CREATE_PATH)

    def assert_no_post(self, outcome: Mapping[str, object]) -> None:
        self.assertEqual(outcome["transport"].posts(), [])
        self.assertEqual(outcome["executor"].post_count, 0)

    def rendered(self, error: BaseException) -> str:
        return "".join(
            (
                str(error),
                repr(error),
                *traceback.format_exception(type(error), error, error.__traceback__),
                repr(getattr(error, "__cause__", None)),
                repr(getattr(error, "__context__", None)),
                json.dumps(
                    getattr(error, "safe_summary", dict)(),
                    ensure_ascii=False,
                    sort_keys=True,
                ),
            )
        )

    def cli_args(self) -> list[str]:
        return [
            "interpretation-create-probe",
            "--account-label",
            ACCOUNT_LABEL,
            "--allow-network",
        ]


# ---------------------------------------------------------------------------
# A. Preflight
# ---------------------------------------------------------------------------


class PreflightTests(InterpretationCreateFixtures, unittest.TestCase):
    def test_zero_baseline_reaches_the_preview_with_zero_posts(self) -> None:
        executor, transport, plan = self.preflight(
            [self.vocabulary_response(), self.collection_response([])]
        )
        self.assertEqual(
            transport.calls(),
            [("GET", VOCABULARY_PATH), ("GET", INTERPRETATIONS_PATH)],
        )
        self.assertEqual(executor.post_count, 0)
        self.assertEqual(plan.preflight_interpretation_count, 0)
        self.assertEqual(plan.requested_spelling, "acquisition")

    def test_documented_and_data_wrapped_previews_are_field_for_field_identical(
        self,
    ) -> None:
        """Issue #20/#22 wrapper compatibility still holds on the write path."""
        _executor, _transport, documented = self.preflight(
            [self.vocabulary_response(), self.collection_response([])]
        )
        _executor, wrapped_transport, wrapped = self.preflight(
            [
                self.vocabulary_response(wrapped=True),
                self.collection_response([], wrapped=True),
            ]
        )
        self.assertEqual(documented.safe_preview(), wrapped.safe_preview())
        self.assertEqual(
            documented.expected_confirmation, wrapped.expected_confirmation
        )
        self.assertEqual(
            wrapped_transport.calls(),
            [("GET", VOCABULARY_PATH), ("GET", INTERPRETATIONS_PATH)],
        )

    def test_one_existing_interpretation_blocks_and_never_updates(self) -> None:
        failure, transport = self.expect_preflight_failure(
            [
                self.vocabulary_response(),
                self.collection_response([self.foreign_record()]),
            ]
        )
        self.assertEqual(
            failure.safe_summary()["failure_stage"], "preflight-interpretations"
        )
        self.assertEqual(failure.safe_summary()["failure_class"], "safety")
        self.assertEqual(failure.safe_summary()["write_outcome"], "not-attempted")
        self.assertEqual(
            transport.calls(),
            [("GET", VOCABULARY_PATH), ("GET", INTERPRETATIONS_PATH)],
        )

    def test_multiple_existing_interpretations_are_ambiguous(self) -> None:
        failure, _transport = self.expect_preflight_failure(
            [
                self.vocabulary_response(),
                self.collection_response(
                    [
                        self.foreign_record(),
                        self.foreign_record(id="INVALID_ISSUE24_THIRD_ID"),
                    ]
                ),
            ]
        )
        summary = failure.safe_summary()
        self.assertEqual(summary["failure_stage"], "preflight-interpretations")
        self.assertEqual(summary["failure_class"], "ambiguous")
        self.assertEqual(summary["write_outcome"], "not-attempted")
        self.assertEqual(summary["post_count"], 0)

    def test_every_preflight_failure_mode_sends_zero_posts(self) -> None:
        good_vocabulary = self.vocabulary_response()
        cases: tuple[tuple[str, list[object], str, str], ...] = (
            (
                "vocabulary-transport",
                [harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)],
                "preflight-vocabulary",
                "transport",
            ),
            (
                "vocabulary-http-401",
                [harness.HttpResponse(401, {})],
                "preflight-vocabulary",
                "http-status",
            ),
            (
                "vocabulary-http-500",
                [harness.HttpResponse(500, {})],
                "preflight-vocabulary",
                "http-status",
            ),
            (
                "vocabulary-rejected-response",
                [harness.TransportResponseError(200, "body-invalid-json")],
                "preflight-vocabulary",
                "schema",
            ),
            (
                "vocabulary-missing-voc",
                [harness.HttpResponse(200, {SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL})],
                "preflight-vocabulary",
                "schema",
            ),
            (
                "vocabulary-unsafe-id",
                [
                    harness.HttpResponse(
                        200, {"voc": {"id": UNSAFE_RECORD_ID_SENTINEL, "spelling": "acquisition"}}
                    )
                ],
                "preflight-vocabulary",
                "schema",
            ),
            (
                "vocabulary-spelling-mismatch",
                [
                    harness.HttpResponse(
                        200, {"voc": {"id": VOCABULARY_ID, "spelling": "acquire"}}
                    )
                ],
                "preflight-vocabulary",
                "schema",
            ),
            (
                "interpretations-transport",
                [good_vocabulary, harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)],
                "preflight-interpretations",
                "transport",
            ),
            (
                "interpretations-http-403",
                [good_vocabulary, harness.HttpResponse(403, {})],
                "preflight-interpretations",
                "http-status",
            ),
            (
                "interpretations-not-an-array",
                [good_vocabulary, self.collection_response({"unexpected": True})],
                "preflight-interpretations",
                "schema",
            ),
            (
                "interpretations-missing-key",
                [good_vocabulary, harness.HttpResponse(200, {SERVER_KEY_SENTINEL: 1})],
                "preflight-interpretations",
                "schema",
            ),
            (
                "interpretations-unsafe-record-id",
                [
                    good_vocabulary,
                    self.collection_response(
                        [self.created_record(id=UNSAFE_RECORD_ID_SENTINEL)]
                    ),
                ],
                "preflight-interpretations",
                "schema",
            ),
            (
                "interpretations-duplicate-ids",
                [
                    good_vocabulary,
                    self.collection_response(
                        [self.created_record(), self.created_record()]
                    ),
                ],
                "preflight-interpretations",
                "schema",
            ),
            (
                "interpretations-status-outside-enum",
                [
                    good_vocabulary,
                    self.collection_response(
                        [self.created_record(status=SERVER_VALUE_SENTINEL)]
                    ),
                ],
                "preflight-interpretations",
                "schema",
            ),
            (
                "interpretations-malformed-item",
                [good_vocabulary, self.collection_response([SERVER_VALUE_SENTINEL])],
                "preflight-interpretations",
                "schema",
            ),
        )
        for name, responses, stage, failure_class in cases:
            with self.subTest(case=name):
                failure, transport = self.expect_preflight_failure(list(responses))
                summary = failure.safe_summary()
                self.assertEqual(summary["failure_stage"], stage)
                self.assertEqual(summary["failure_class"], failure_class)
                self.assertFalse(summary["post_attempted"])
                self.assertEqual(summary["post_count"], 0)
                self.assertFalse(summary["readback_attempted"])
                self.assertEqual(summary["write_outcome"], "not-attempted")
                self.assertNotIn("POST", [call[0] for call in transport.calls()])
                rendered = self.rendered(failure)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_preflight_never_requests_phrases(self) -> None:
        _executor, transport, _plan = self.preflight(
            [self.vocabulary_response(), self.collection_response([])]
        )
        for _method, path in transport.calls():
            self.assertNotIn("phrases", path)

    def test_preflight_runs_at_most_once_per_executor(self) -> None:
        executor, _transport, _plan = self.preflight(
            [self.vocabulary_response(), self.collection_response([])]
        )
        with self.assertRaises(harness.InterpretationCreateFailure):
            executor.preflight(self.credential(), ACCOUNT_LABEL)

    def test_main_and_production_account_labels_are_rejected(self) -> None:
        for label in (
            "main account",
            "primary",
            "owner",
            "prod",
            "production test",
            "主账号",
            "主号测试",
            "生产测试",
            "no-marker-label",
        ):
            with self.subTest(label=label):
                transport = FakeTransport([])
                executor = harness.InterpretationCreateExecutor(transport)
                with self.assertRaises(harness.InterpretationCreateFailure):
                    executor.preflight(
                        harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL),
                        label,
                    )
                self.assertEqual(transport.requests, [])


# ---------------------------------------------------------------------------
# B. Exact write confirmation
# ---------------------------------------------------------------------------


class ConfirmationTests(InterpretationCreateFixtures, unittest.TestCase):
    def plan_for(self, **overrides: object) -> harness.InterpretationCreatePlan:
        arguments: dict[str, object] = {
            "account_label": ACCOUNT_LABEL,
            "credential_fingerprint": self.credential().fingerprint,
            "returned_spelling": "acquisition",
            "vocabulary_id": VOCABULARY_ID,
            "preflight_interpretation_count": 0,
        }
        arguments.update(overrides)
        return harness.build_interpretation_create_plan(**arguments)  # type: ignore[arg-type]

    def test_the_write_confirmation_is_unmistakably_a_write(self) -> None:
        confirmation = self.plan_for().expected_confirmation
        self.assertIn("WRITE", confirmation)
        self.assertTrue(confirmation.startswith(harness.WRITE_CONFIRMATION_PREFIX))
        self.assertIn(harness.WRITE_ONE_POST_CLAUSE, confirmation)
        self.assertIn(harness.WRITE_PRICING_TERMS_CLAUSE, confirmation)
        self.assertNotIn(harness.READ_ONLY_CONFIRMATION_PREFIX, confirmation)
        self.assertNotEqual(
            harness.WRITE_CONFIRMATION_PREFIX, harness.READ_ONLY_CONFIRMATION_PREFIX
        )

    def test_a_read_only_confirmation_can_never_satisfy_the_write_gate(self) -> None:
        read_only = harness._read_only_confirmation_for(
            ACCOUNT_LABEL, self.credential().fingerprint, "acquisition"
        )
        plan = self.plan_for()
        with self.assertRaises(harness.ConfirmationError):
            plan.validate_confirmation(read_only)

    def test_exact_confirmation_passes_and_one_character_mismatch_blocks(self) -> None:
        plan = self.plan_for()
        expected = plan.expected_confirmation
        plan.validate_confirmation(expected)
        variants = (
            expected[:-1],
            expected + "X",
            expected[:-1] + ("Y" if expected[-1] != "Y" else "Z"),
            expected.replace(" ", "  ", 1),
            expected.lower(),
            expected.strip() + " ",
            "",
        )
        for variant in variants:
            with self.subTest(variant=variant[-12:]):
                with self.assertRaises(harness.ConfirmationError):
                    plan.validate_confirmation(variant)
        for non_string in (None, 1, b"bytes", ["list"]):
            with self.subTest(variant=repr(non_string)):
                with self.assertRaises(harness.ConfirmationError):
                    plan.validate_confirmation(non_string)

    def test_every_bound_input_changes_the_confirmation(self) -> None:
        base = self.plan_for().expected_confirmation
        variants = {
            "token-fingerprint": self.plan_for(
                credential_fingerprint="0123456789abcdef"
            ),
            "account-label": self.plan_for(account_label="issue24-secondary-other"),
            "voc-id": self.plan_for(vocabulary_id="INVALID_ISSUE24_OTHER_VOC_ID"),
        }
        for name, plan in variants.items():
            with self.subTest(bound_input=name):
                self.assertNotEqual(base, plan.expected_confirmation)

    def test_tampering_with_any_bound_field_invalidates_the_confirmation(self) -> None:
        """A plan mutated after preview can never satisfy its own confirmation."""
        tampered_bodies = {
            "interpretation-text": {
                "interpretation": {
                    **EXPECTED_BODY["interpretation"],
                    "interpretation": "n. 收购；购置",
                }
            },
            "tag-order": {
                "interpretation": {
                    **EXPECTED_BODY["interpretation"],
                    "tags": ["BEC", "MBA", "GMAT"],
                }
            },
            "tag-set": {
                "interpretation": {
                    **EXPECTED_BODY["interpretation"],
                    "tags": ["MBA", "BEC", "TOEFL"],
                }
            },
            "status": {
                "interpretation": {
                    **EXPECTED_BODY["interpretation"],
                    "status": "UNPUBLISHED",
                }
            },
            "voc-id": {
                "interpretation": {
                    **EXPECTED_BODY["interpretation"],
                    "voc_id": "INVALID_ISSUE24_OTHER_VOC_ID",
                }
            },
            "extra-field": {
                "interpretation": {
                    **EXPECTED_BODY["interpretation"],
                    "origin": SERVER_VALUE_SENTINEL,
                }
            },
            "top-level-id": {
                "id": CREATED_RECORD_ID,
                "interpretation": EXPECTED_BODY["interpretation"],
            },
        }
        for name, body in tampered_bodies.items():
            with self.subTest(mutation=name):
                plan = self.plan_for()
                object.__setattr__(plan, "request_body", harness._freeze_json(body))
                with self.assertRaises(harness.SafetyError):
                    plan.revalidate()
                with self.assertRaises(harness.SafetyError):
                    _ = plan.expected_confirmation

        scalar_mutations = {
            "spelling": {"requested_spelling": "acquire"},
            "returned-spelling": {"returned_spelling": "acquire"},
            "preflight-count": {"preflight_interpretation_count": 1},
            "vocabulary-id": {"vocabulary_id": UNSAFE_RECORD_ID_SENTINEL},
            "account-label": {"account_label": "main account"},
            "fingerprint": {"credential_fingerprint": "not-a-fingerprint"},
        }
        for name, fields in scalar_mutations.items():
            with self.subTest(mutation=name):
                plan = self.plan_for()
                for key, value in fields.items():
                    object.__setattr__(plan, key, value)
                with self.assertRaises(harness.SafetyError):
                    plan.revalidate()

    def test_a_digest_only_mutation_still_invalidates_the_confirmation(self) -> None:
        plan = self.plan_for()
        captured = plan.expected_confirmation
        # Same shape, different bound voc_id: only the digest changes.
        other = self.plan_for(vocabulary_id="INVALID_ISSUE24_OTHER_VOC_ID")
        self.assertNotEqual(plan.request_body_digest, other.request_body_digest)
        with self.assertRaises(harness.ConfirmationError):
            other.validate_confirmation(captured)

    def test_confirmation_failure_sends_zero_posts(self) -> None:
        plan = self.plan_for()
        wrong = plan.expected_confirmation[:-1] + "0"
        outcome = self.run_probe(self.success_responses(), confirmation=wrong)
        self.assert_no_post(outcome)
        summary = outcome["failure"].safe_summary()
        self.assertEqual(summary["failure_stage"], "confirmation")
        self.assertEqual(summary["failure_class"], "confirmation")
        self.assertEqual(summary["write_outcome"], "not-attempted")
        self.assertIsNone(summary["http_status"])
        self.assertIsNone(outcome["journal"])

    def test_payload_tampering_between_preview_and_commit_sends_zero_posts(self) -> None:
        def tamper(plan: harness.InterpretationCreatePlan) -> None:
            object.__setattr__(
                plan,
                "request_body",
                harness._freeze_json(
                    {
                        "interpretation": {
                            **EXPECTED_BODY["interpretation"],
                            "interpretation": FOREIGN_INTERPRETATION_SENTINEL,
                        }
                    }
                ),
            )

        transport = FakeTransport(self.success_responses())
        executor = harness.InterpretationCreateExecutor(transport)
        test_credential = self.credential()
        _root, store = self.make_store()
        plan = executor.preflight(test_credential, ACCOUNT_LABEL)
        captured = plan.expected_confirmation
        tamper(plan)
        with self.assertRaises(harness.InterpretationCreateFailure) as context:
            executor.commit(plan, captured, test_credential, state_store=store)
        self.assertEqual(executor.post_count, 0)
        self.assertEqual(transport.posts(), [])
        self.assertEqual(
            context.exception.safe_summary()["write_outcome"], "not-attempted"
        )

    def test_commit_requires_a_completed_preflight_and_runs_once(self) -> None:
        transport = FakeTransport(self.success_responses())
        executor = harness.InterpretationCreateExecutor(transport)
        _root, store = self.make_store()
        plan = self.plan_for()
        with self.assertRaises(harness.InterpretationCreateFailure):
            executor.commit(
                plan, plan.expected_confirmation, self.credential(), state_store=store
            )
        self.assertEqual(executor.post_count, 0)

        outcome = self.run_probe(self.success_responses())
        self.assertIsNotNone(outcome["result"])
        with self.assertRaises(harness.InterpretationCreateFailure):
            outcome["executor"].commit(
                outcome["plan"],
                outcome["plan"].expected_confirmation,
                self.credential(),
                state_store=outcome["store"],
            )
        self.assert_single_post(outcome)

    def test_commit_requires_the_reviewed_private_journal(self) -> None:
        transport = FakeTransport(self.success_responses())
        executor = harness.InterpretationCreateExecutor(transport)
        test_credential = self.credential()
        plan = executor.preflight(test_credential, ACCOUNT_LABEL)
        for store in (None, harness.PrivateStateStore(journal_prefix="issue9-step")):
            with self.subTest(store=type(store).__name__):
                with self.assertRaises(harness.InterpretationCreateFailure):
                    executor.commit(
                        plan,
                        plan.expected_confirmation,
                        test_credential,
                        state_store=store,
                    )
                self.assertEqual(executor.post_count, 0)


# ---------------------------------------------------------------------------
# C. Request lock
# ---------------------------------------------------------------------------


class RequestLockTests(InterpretationCreateFixtures, unittest.TestCase):
    def test_the_exact_request_sequence_and_body_are_locked(self) -> None:
        outcome = self.run_probe(self.success_responses())
        self.assertIsNotNone(outcome["result"])
        transport = outcome["transport"]
        self.assertEqual(
            transport.calls(),
            [
                ("GET", VOCABULARY_PATH),
                ("GET", INTERPRETATIONS_PATH),
                ("POST", CREATE_PATH),
                ("GET", INTERPRETATIONS_PATH),
            ],
        )
        post = transport.posts()[0]
        self.assertEqual(post.method, "POST")
        self.assertEqual(post.path, CREATE_PATH)
        self.assertEqual(harness._thaw_json(post.payload), EXPECTED_BODY)
        self.assertEqual(
            json.dumps(
                harness._thaw_json(post.payload), ensure_ascii=False, sort_keys=True
            ),
            json.dumps(EXPECTED_BODY, ensure_ascii=False, sort_keys=True),
        )

    def test_the_sent_body_comes_from_the_same_immutable_plan_as_the_preview(
        self,
    ) -> None:
        outcome = self.run_probe(self.success_responses())
        plan = outcome["plan"]
        post = outcome["transport"].posts()[0]
        sent = harness._thaw_json(post.payload)
        self.assertEqual(sent, harness._thaw_json(plan.request_body))
        digest = hashlib.sha256(
            json.dumps(
                sent, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
        ).hexdigest()
        self.assertEqual(digest, plan.request_body_digest)
        self.assertEqual(
            plan.safe_preview()["request_body_digest"], plan.request_body_digest
        )
        self.assertIsInstance(plan.request_body, Mapping)
        with self.assertRaises(TypeError):
            plan.request_body["interpretation"] = {}  # type: ignore[index]

    def test_the_guard_refuses_every_non_reviewed_request(self) -> None:
        delegate = FakeTransport([])
        guard = harness.SingleInterpretationWriteGuard(delegate)
        test_credential = self.credential()
        forbidden = (
            harness.HttpRequest("GET", f"/open/api/v1/phrases?voc_id={VOCABULARY_ID}"),
            harness.HttpRequest(
                "POST",
                f"/open/api/v1/interpretations/{CREATED_RECORD_ID}",
                EXPECTED_BODY,
            ),
            harness.HttpRequest("POST", "/open/api/v1/phrases", EXPECTED_BODY),
        )
        for request in forbidden:
            with self.subTest(request=f"{request.method} {request.path}"):
                with self.assertRaises(harness.SafetyError):
                    guard.send(request, test_credential)
        self.assertEqual(guard.post_count, 0)
        self.assertEqual(guard.get_count, 0)
        self.assertEqual(delegate.requests, [])

    def test_put_patch_and_delete_cannot_even_be_constructed(self) -> None:
        for method in ("PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "post"):
            with self.subTest(method=method):
                with self.assertRaises(harness.SafetyError):
                    harness.HttpRequest(method, CREATE_PATH, EXPECTED_BODY)

    def test_the_guard_caps_gets_at_three(self) -> None:
        delegate = FakeTransport(
            [harness.HttpResponse(200, {"interpretations": []}) for _ in range(3)]
        )
        guard = harness.SingleInterpretationWriteGuard(delegate)
        request = harness.HttpRequest("GET", INTERPRETATIONS_PATH)
        for _ in range(harness.MAX_INTERPRETATION_CREATE_GETS):
            guard.send(request, self.credential())
        with self.assertRaises(harness.SafetyError):
            guard.send(request, self.credential())
        self.assertEqual(guard.get_count, harness.MAX_INTERPRETATION_CREATE_GETS)
        self.assertEqual(len(delegate.requests), 3)

    def test_no_run_ever_touches_a_phrase_endpoint(self) -> None:
        outcome = self.run_probe(self.success_responses())
        for _method, path in outcome["transport"].calls():
            self.assertNotIn("phrases", path)
        self.assertNotIn(
            "/open/api/v1/phrases", str(harness.INTERPRETATION_CREATE_READ_PATHS)
        )


# ---------------------------------------------------------------------------
# D. Clear-success path
# ---------------------------------------------------------------------------


class ClearSuccessTests(InterpretationCreateFixtures, unittest.TestCase):
    def test_zero_baseline_then_2xx_then_matching_readback_succeeds(self) -> None:
        outcome = self.run_probe(self.success_responses())
        result = outcome["result"]
        self.assertIsNotNone(result)
        summary = result.safe_summary()
        self.assertEqual(summary["mode"], "interpretation-create-probe")
        self.assertEqual(summary["status"], "succeeded")
        self.assertEqual(summary["operation"], "create")
        self.assertEqual(summary["write_outcome"], "confirmed-success")
        self.assertEqual(summary["requested_spelling"], "acquisition")
        self.assertEqual(summary["preflight_count"], 0)
        self.assertEqual(summary["post_write_count"], 1)
        self.assertEqual(summary["intended_tags"], ["MBA", "BEC", "GMAT"])
        self.assertEqual(summary["intended_status"], "PUBLISHED")
        self.assertEqual(summary["post_http_status"], 200)
        self.assertEqual(summary["post_count"], 1)
        self.assertTrue(summary["readback_attempted"])
        self.assertEqual(summary["requests_attempted"], 4)
        self.assertEqual(summary["requests_completed"], 4)
        self.assert_single_post(outcome)

    def test_success_output_carries_only_fingerprints_and_project_values(self) -> None:
        outcome = self.run_probe(self.success_responses())
        summary = outcome["result"].safe_summary()
        rendered = json.dumps(summary, ensure_ascii=False, sort_keys=True)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        self.assertEqual(
            summary["voc_id_fingerprint"],
            hashlib.sha256(VOCABULARY_ID.encode("utf-8")).hexdigest()[:16],
        )
        self.assertEqual(
            summary["created_record_id_fingerprint"],
            hashlib.sha256(CREATED_RECORD_ID.encode("utf-8")).hexdigest()[:16],
        )
        self.assertNotIn("voc_id", summary)
        self.assertNotIn("id", summary)

    def test_server_tag_order_is_accepted_as_a_set(self) -> None:
        orders = (
            ["MBA", "BEC", "GMAT"],
            ["GMAT", "MBA", "BEC"],
            ["BEC", "GMAT", "MBA"],
        )
        for tags in orders:
            with self.subTest(tags=tags):
                responses = self.success_responses()
                responses[-1] = self.collection_response(
                    [self.created_record(tags=tags)]
                )
                outcome = self.run_probe(responses)
                self.assertIsNotNone(outcome["result"])
                self.assert_single_post(outcome)

    def test_the_post_response_body_is_never_trusted_or_echoed(self) -> None:
        """The POST body carries an unsafe id; correctness must not depend on it."""
        outcome = self.run_probe(self.success_responses())
        summary = outcome["result"].safe_summary()
        rendered = json.dumps(summary, ensure_ascii=False, sort_keys=True) + json.dumps(
            outcome["journal"], ensure_ascii=False, sort_keys=True
        )
        self.assertNotIn(UNSAFE_RECORD_ID_SENTINEL, rendered)
        self.assertNotIn(POST_RESPONSE_SENTINEL, rendered)
        self.assertEqual(
            summary["created_record_id_fingerprint"],
            hashlib.sha256(CREATED_RECORD_ID.encode("utf-8")).hexdigest()[:16],
        )

    def test_data_wrapped_success_is_field_for_field_identical(self) -> None:
        documented = self.run_probe(self.success_responses())
        wrapped = self.run_probe(self.success_responses(wrapped=True))
        self.assertEqual(
            documented["result"].safe_summary(), wrapped["result"].safe_summary()
        )
        self.assertEqual(documented["transport"].calls(), wrapped["transport"].calls())


# ---------------------------------------------------------------------------
# E. Response-loss recovery
# ---------------------------------------------------------------------------


class ResponseLossRecoveryTests(InterpretationCreateFixtures, unittest.TestCase):
    def uncertain_post_outcomes(self) -> tuple[tuple[str, object], ...]:
        return (
            ("timeout", harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)),
            (
                "rejected-invalid-utf8",
                harness.TransportResponseError(200, "body-invalid-utf8"),
            ),
            (
                "rejected-invalid-json",
                harness.TransportResponseError(200, "body-invalid-json"),
            ),
            (
                "rejected-not-object",
                harness.TransportResponseError(200, "body-not-object"),
            ),
            (
                "rejected-too-large",
                harness.TransportResponseError(200, "body-too-large"),
            ),
            ("rejected-status-only", harness.TransportResponseError(None)),
            ("raw-os-error", OSError(TRANSPORT_EXCEPTION_SENTINEL)),
            ("raw-timeout", TimeoutError(TRANSPORT_EXCEPTION_SENTINEL)),
            ("raw-reset", ConnectionResetError(TRANSPORT_EXCEPTION_SENTINEL)),
            ("raw-ssl", ssl.SSLError(TRANSPORT_EXCEPTION_SENTINEL)),
            (
                "raw-incomplete-read",
                http.client.IncompleteRead(b"partial", 4096),
            ),
            ("safety-from-delegate", harness.SafetyError(TRANSPORT_EXCEPTION_SENTINEL)),
            ("non-response-object", SERVER_VALUE_SENTINEL),
            ("response-without-numeric-status", harness.HttpResponse("200", {})),
        )

    def test_every_uncertain_post_recovers_through_exactly_one_readback(self) -> None:
        for name, failure in self.uncertain_post_outcomes():
            with self.subTest(uncertainty=name):
                responses = [
                    self.vocabulary_response(),
                    self.collection_response([]),
                    failure,
                    self.collection_response([self.created_record()]),
                ]
                outcome = self.run_probe(responses)
                self.assertIsNotNone(outcome["result"], name)
                summary = outcome["result"].safe_summary()
                self.assertEqual(summary["status"], "recovered-succeeded")
                self.assertEqual(summary["write_outcome"], "recovered-success")
                self.assertEqual(summary["post_count"], 1)
                self.assertEqual(summary["post_write_count"], 1)
                self.assert_single_post(outcome)
                calls = outcome["transport"].calls()
                self.assertEqual(len(calls), 4)
                self.assertEqual(calls[3], ("GET", INTERPRETATIONS_PATH))
                self.assertEqual(
                    sum(1 for method, _ in calls if method == "POST"), 1
                )
                self.assertEqual(
                    outcome["journal"]["write_outcome"], "recovered-success"
                )
                self.assertEqual(outcome["journal"]["status"], "verified")

    def test_an_uncertain_post_never_produces_a_second_post_request(self) -> None:
        for name, failure in self.uncertain_post_outcomes():
            with self.subTest(uncertainty=name):
                responses = [
                    self.vocabulary_response(),
                    self.collection_response([]),
                    failure,
                    harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL),
                ]
                outcome = self.run_probe(responses)
                self.assertIsNone(outcome["result"])
                self.assert_single_post(outcome)
                self.assertEqual(len(outcome["transport"].calls()), 4)

    def test_the_guard_makes_a_second_post_structurally_impossible(self) -> None:
        delegate = FakeTransport(
            [
                harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL),
                harness.HttpResponse(200, {}),
            ]
        )
        guard = harness.SingleInterpretationWriteGuard(delegate)
        request = harness.HttpRequest("POST", CREATE_PATH, EXPECTED_BODY)
        with self.assertRaises(harness.TransportError):
            guard.send(request, self.credential())
        self.assertEqual(guard.post_count, 1)
        for _attempt in range(3):
            with self.assertRaises(harness.SafetyError):
                guard.send(request, self.credential())
        self.assertEqual(guard.post_count, 1)
        self.assertEqual(len(delegate.requests), 1)

    def test_the_executor_refuses_a_second_write_invocation(self) -> None:
        outcome = self.run_probe(self.success_responses())
        executor = outcome["executor"]
        with self.assertRaises(harness.SafetyError):
            executor._attempt_single_post(
                harness.HttpRequest("POST", CREATE_PATH, EXPECTED_BODY),
                self.credential(),
            )
        self.assert_single_post(outcome)


# ---------------------------------------------------------------------------
# E2. The real stdlib transport also cannot retry a POST
# ---------------------------------------------------------------------------


class ProductionTransportWriteTests(InterpretationCreateFixtures, unittest.TestCase):
    def connection_factory(self, behaviors: list[dict]) -> tuple[type, dict]:
        state: dict[str, object] = {
            "connections": 0,
            "requests": 0,
            "reads": 0,
            "closed": 0,
            "paths": [],
            "header_names": [],
            "bodies": [],
        }

        class FakeSocket:
            def settimeout(self, _timeout: float) -> None:
                return None

        class FakeResponse:
            def __init__(self, behavior: dict) -> None:
                self.status = behavior.get("status", 200)
                self._body = behavior.get("body", b"{}")

            def read(self, _limit: int) -> bytes:
                state["reads"] += 1  # type: ignore[operator]
                if isinstance(self._body, BaseException):
                    raise self._body
                if self._body is None:
                    raise AssertionError("this response body must not be read")
                return self._body

        class FakeConnection:
            def __init__(self, host: str, *, timeout: float) -> None:
                index = state["connections"]
                state["connections"] += 1  # type: ignore[operator]
                if index >= len(behaviors):  # type: ignore[operator]
                    raise AssertionError("the transport opened an extra connection")
                self.host = host
                self.sock: FakeSocket | None = None
                self.behavior = behaviors[index]  # type: ignore[index]
                self.closed = False

            def connect(self) -> None:
                error = self.behavior.get("connect_error")
                if isinstance(error, BaseException):
                    raise error
                self.sock = FakeSocket()

            def request(
                self,
                method: str,
                path: str,
                body: object = None,
                headers: dict | None = None,
            ) -> None:
                state["requests"] += 1  # type: ignore[operator]
                state["paths"].append((method, path))  # type: ignore[union-attr]
                state["header_names"].append(  # type: ignore[union-attr]
                    tuple(sorted(headers or {}))
                )
                state["bodies"].append(body)  # type: ignore[union-attr]
                error = self.behavior.get("request_error")
                if isinstance(error, BaseException):
                    raise error

            def getresponse(self) -> FakeResponse:
                error = self.behavior.get("getresponse_error")
                if isinstance(error, BaseException):
                    raise error
                return FakeResponse(self.behavior)

            def close(self) -> None:
                self.closed = True
                state["closed"] += 1  # type: ignore[operator]

        return FakeConnection, state

    def body(self, payload: dict) -> bytes:
        return json.dumps(payload, ensure_ascii=False).encode("utf-8")

    def preflight_behaviors(self) -> list[dict]:
        return [
            {
                "status": 200,
                "body": self.body({"voc": {"id": VOCABULARY_ID, "spelling": "acquisition"}}),
            },
            {"status": 200, "body": self.body({"interpretations": []})},
        ]

    def readback_behavior(self) -> dict:
        return {
            "status": 200,
            "body": self.body({"interpretations": [self.created_record()]}),
        }

    def drive(self, behaviors: list[dict]) -> dict[str, object]:
        connection, state = self.connection_factory(behaviors)
        _root, store = self.make_store()
        with mock.patch.object(harness.http.client, "HTTPSConnection", connection):
            executor = harness.InterpretationCreateExecutor(
                harness.ProductionHttpTransport()
            )
            test_credential = self.credential()
            plan = executor.preflight(test_credential, ACCOUNT_LABEL)
            try:
                result = executor.commit(
                    plan,
                    plan.expected_confirmation,
                    test_credential,
                    state_store=store,
                )
                failure = None
            except harness.InterpretationCreateFailure as raised:
                result, failure = None, raised
        return {
            "state": state,
            "result": result,
            "failure": failure,
            "executor": executor,
        }

    def test_the_real_transport_sends_one_post_with_the_exact_locked_body(self) -> None:
        behaviors = [
            *self.preflight_behaviors(),
            {"status": 200, "body": self.body({"ok": True})},
            self.readback_behavior(),
        ]
        outcome = self.drive(behaviors)
        state = outcome["state"]
        self.assertIsNotNone(outcome["result"])
        self.assertEqual(state["connections"], 4)
        self.assertEqual(state["requests"], 4)
        self.assertEqual(state["closed"], 4)
        self.assertEqual(
            state["paths"],
            [
                ("GET", VOCABULARY_PATH),
                ("GET", INTERPRETATIONS_PATH),
                ("POST", CREATE_PATH),
                ("GET", INTERPRETATIONS_PATH),
            ],
        )
        self.assertEqual(
            state["header_names"],
            [
                ("Accept", "Authorization"),
                ("Accept", "Authorization"),
                ("Accept", "Authorization", "Content-Type"),
                ("Accept", "Authorization"),
            ],
        )
        self.assertEqual(
            json.loads(state["bodies"][2].decode("utf-8")), EXPECTED_BODY
        )
        self.assertIsNone(state["bodies"][0])
        self.assertIsNone(state["bodies"][3])

    def test_production_post_io_failures_never_retry_and_recover_by_get(self) -> None:
        io_errors = (
            ("timeout", TimeoutError(f"{PRODUCTION_IO_SENTINEL}-timeout")),
            ("socket-timeout", socket.timeout(f"{PRODUCTION_IO_SENTINEL}-socket")),
            (
                "incomplete-read",
                http.client.IncompleteRead(
                    f"{PRODUCTION_IO_SENTINEL}-partial".encode("utf-8"), 4096
                ),
            ),
            ("reset", ConnectionResetError(f"{PRODUCTION_IO_SENTINEL}-reset")),
            ("ssl", ssl.SSLError(f"{PRODUCTION_IO_SENTINEL}-ssl")),
        )
        for name, error in io_errors:
            for phase in ("body", "getresponse_error", "request_error"):
                with self.subTest(error=name, phase=phase):
                    write_behavior: dict[str, object] = {"status": 200, "body": b"{}"}
                    if phase == "body":
                        write_behavior["body"] = error
                    else:
                        write_behavior[phase] = error
                    outcome = self.drive(
                        [
                            *self.preflight_behaviors(),
                            write_behavior,
                            self.readback_behavior(),
                        ]
                    )
                    state = outcome["state"]
                    self.assertIsNotNone(outcome["result"], name)
                    self.assertEqual(
                        outcome["result"].safe_summary()["write_outcome"],
                        "recovered-success",
                    )
                    self.assertEqual(outcome["executor"].post_count, 1)
                    self.assertEqual(
                        sum(1 for method, _ in state["paths"] if method == "POST"), 1
                    )
                    self.assertEqual(state["connections"], 4)
                    self.assertEqual(state["closed"], 4)
                    rendered = json.dumps(
                        outcome["result"].safe_summary(), ensure_ascii=False
                    )
                    self.assertNotIn(PRODUCTION_IO_SENTINEL, rendered)

    def test_production_post_invalid_body_recovers_without_a_second_post(self) -> None:
        bodies = {
            "invalid-utf8": b"\xff\xfe\x00",
            "invalid-json": b"{not json",
            "not-an-object": b"[1, 2, 3]",
            "oversized": b'{"x":"' + b"P" * (harness.MAX_RESPONSE_BYTES + 16) + b'"}',
        }
        for name, raw in bodies.items():
            with self.subTest(body=name):
                outcome = self.drive(
                    [
                        *self.preflight_behaviors(),
                        {"status": 200, "body": raw},
                        self.readback_behavior(),
                    ]
                )
                self.assertIsNotNone(outcome["result"], name)
                self.assertEqual(
                    outcome["result"].safe_summary()["write_outcome"],
                    "recovered-success",
                )
                self.assertEqual(outcome["executor"].post_count, 1)
                self.assertEqual(
                    sum(
                        1
                        for method, _ in outcome["state"]["paths"]
                        if method == "POST"
                    ),
                    1,
                )


# ---------------------------------------------------------------------------
# F. Fail-closed recovery
# ---------------------------------------------------------------------------


class FailClosedRecoveryTests(InterpretationCreateFixtures, unittest.TestCase):
    def readback_failures(self) -> tuple[tuple[str, object, str, str, str], ...]:
        return (
            (
                "empty",
                self.collection_response([]),
                "unknown-write-outcome",
                "not-verified",
                "no-record",
            ),
            (
                "two-records",
                self.collection_response(
                    [self.created_record(), self.foreign_record()]
                ),
                "ambiguous",
                "ambiguous",
                "multiple-records",
            ),
            (
                "mismatched-text",
                self.collection_response(
                    [self.created_record(interpretation=FOREIGN_INTERPRETATION_SENTINEL)]
                ),
                "mismatch",
                "not-verified",
                "record-mismatch",
            ),
            (
                "wrong-tags",
                self.collection_response(
                    [self.created_record(tags=["MBA", "BEC", "TOEFL"])]
                ),
                "mismatch",
                "not-verified",
                "record-mismatch",
            ),
            (
                "duplicate-tag",
                self.collection_response(
                    [self.created_record(tags=["MBA", "MBA", "BEC"])]
                ),
                "mismatch",
                "not-verified",
                "record-mismatch",
            ),
            (
                "extra-tag",
                self.collection_response(
                    [self.created_record(tags=["MBA", "BEC", "GMAT", "TOEFL"])]
                ),
                "mismatch",
                "not-verified",
                "record-mismatch",
            ),
            (
                "missing-tag",
                self.collection_response([self.created_record(tags=["MBA", "BEC"])]),
                "mismatch",
                "not-verified",
                "record-mismatch",
            ),
            (
                "tags-not-a-list",
                self.collection_response(
                    [self.created_record(tags="MBA,BEC,GMAT")]
                ),
                "mismatch",
                "not-verified",
                "record-mismatch",
            ),
            (
                "wrong-status",
                self.collection_response(
                    [self.created_record(status="UNPUBLISHED")]
                ),
                "mismatch",
                "not-verified",
                "record-mismatch",
            ),
            (
                "unsafe-record-id",
                self.collection_response(
                    [self.created_record(id=UNSAFE_RECORD_ID_SENTINEL)]
                ),
                "schema",
                "not-verified",
                "readback-unreadable",
            ),
            (
                "status-outside-enum",
                self.collection_response(
                    [self.created_record(status=SERVER_VALUE_SENTINEL)]
                ),
                "schema",
                "not-verified",
                "readback-unreadable",
            ),
            (
                "not-an-array",
                self.collection_response({"unexpected": SERVER_VALUE_SENTINEL}),
                "schema",
                "not-verified",
                "readback-unreadable",
            ),
            (
                "transport-error",
                harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL),
                "transport",
                "not-verified",
                "readback-unreadable",
            ),
            (
                "rejected-response",
                harness.TransportResponseError(200, "body-invalid-json"),
                "schema",
                "not-verified",
                "readback-unreadable",
            ),
            (
                "non-success-status",
                self.collection_response([self.created_record()], status=500),
                "http-status",
                "not-verified",
                "readback-unreadable",
            ),
        )

    def test_every_readback_failure_is_fail_closed_after_exactly_one_post(self) -> None:
        for name, readback, failure_class, outcome_name, journal_result in (
            self.readback_failures()
        ):
            with self.subTest(readback=name):
                outcome = self.run_probe(
                    [
                        self.vocabulary_response(),
                        self.collection_response([]),
                        self.post_response(),
                        readback,
                    ]
                )
                self.assertIsNone(outcome["result"], name)
                summary = outcome["failure"].safe_summary()
                self.assertEqual(summary["failure_stage"], "readback")
                self.assertEqual(summary["failure_class"], failure_class)
                self.assertEqual(summary["write_outcome"], outcome_name)
                self.assertTrue(summary["post_attempted"])
                self.assertEqual(summary["post_count"], 1)
                self.assertTrue(summary["readback_attempted"])
                self.assert_single_post(outcome)
                self.assertEqual(len(outcome["transport"].calls()), 4)
                journal = outcome["journal"]
                self.assertEqual(journal["status"], "write-unresolved")
                self.assertEqual(journal["readback_result"], journal_result)
                self.assertIsNone(journal["created_record_id_fingerprint"])
                rendered = self.rendered(outcome["failure"]) + json.dumps(
                    journal, ensure_ascii=False, sort_keys=True
                )
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_uncertain_post_plus_failed_readback_stays_fail_closed(self) -> None:
        for name, readback, _failure_class, _outcome, _journal in (
            self.readback_failures()
        ):
            with self.subTest(readback=name):
                outcome = self.run_probe(
                    [
                        self.vocabulary_response(),
                        self.collection_response([]),
                        harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL),
                        readback,
                    ]
                )
                self.assertIsNone(outcome["result"])
                self.assert_single_post(outcome)
                self.assertNotEqual(outcome["journal"]["status"], "verified")


# ---------------------------------------------------------------------------
# G. Non-2xx POST responses
# ---------------------------------------------------------------------------


class NonSuccessPostTests(InterpretationCreateFixtures, unittest.TestCase):
    STATUSES = (400, 401, 403, 409, 429, 500, 503)

    def test_a_non_2xx_post_never_retries_and_reads_back_once(self) -> None:
        for status in self.STATUSES:
            with self.subTest(status=status):
                outcome = self.run_probe(
                    [
                        self.vocabulary_response(),
                        self.collection_response([]),
                        harness.HttpResponse(status, {SERVER_KEY_SENTINEL: POST_RESPONSE_SENTINEL}),
                        self.collection_response([]),
                    ]
                )
                self.assertIsNone(outcome["result"])
                summary = outcome["failure"].safe_summary()
                self.assertEqual(summary["post_count"], 1)
                self.assertTrue(summary["readback_attempted"])
                self.assertEqual(summary["write_outcome"], "not-verified")
                self.assert_single_post(outcome)
                calls = outcome["transport"].calls()
                self.assertEqual(len(calls), 4)
                self.assertEqual(calls[3][0], "GET")

    def test_a_non_2xx_post_claims_success_only_when_readback_proves_it(self) -> None:
        for status in self.STATUSES:
            with self.subTest(status=status):
                outcome = self.run_probe(
                    [
                        self.vocabulary_response(),
                        self.collection_response([]),
                        harness.HttpResponse(status, {}),
                        self.collection_response([self.created_record()]),
                    ]
                )
                result = outcome["result"]
                self.assertIsNotNone(result, status)
                summary = result.safe_summary()
                self.assertEqual(summary["status"], "recovered-succeeded")
                self.assertEqual(summary["write_outcome"], "recovered-success")
                self.assertEqual(summary["post_http_status"], status)
                self.assert_single_post(outcome)

    def test_a_rejected_non_2xx_response_object_behaves_identically(self) -> None:
        for status in self.STATUSES:
            with self.subTest(status=status):
                outcome = self.run_probe(
                    [
                        self.vocabulary_response(),
                        self.collection_response([]),
                        harness.TransportResponseError(status),
                        self.collection_response([]),
                    ]
                )
                self.assertIsNone(outcome["result"])
                self.assert_single_post(outcome)
                self.assertEqual(len(outcome["transport"].calls()), 4)

    def test_a_confirmed_success_requires_a_2xx_post_status(self) -> None:
        with self.assertRaises(harness.SafetyError):
            harness.InterpretationCreateResult(
                write_outcome="confirmed-success",
                requested_spelling="acquisition",
                preflight_count=0,
                post_write_count=1,
                voc_id_fingerprint="0" * 16,
                created_record_id_fingerprint="1" * 16,
                post_http_status=409,
                readback_http_status=200,
                post_count=1,
                requests_attempted=4,
                requests_completed=4,
            )


# ---------------------------------------------------------------------------
# H. Privacy and containment
# ---------------------------------------------------------------------------


class PrivacyTests(InterpretationCreateFixtures, unittest.TestCase):
    def test_no_sentinel_escapes_any_representation_of_a_failure(self) -> None:
        scenarios: tuple[tuple[str, list[object]], ...] = (
            (
                "vocabulary-schema",
                [harness.HttpResponse(200, {SERVER_KEY_SENTINEL: SERVER_VALUE_SENTINEL})],
            ),
            (
                "baseline-not-zero",
                [
                    self.vocabulary_response(),
                    self.collection_response([self.foreign_record()]),
                ],
            ),
            (
                "readback-mismatch",
                [
                    self.vocabulary_response(),
                    self.collection_response([]),
                    self.post_response(),
                    self.collection_response(
                        [
                            self.created_record(
                                interpretation=FOREIGN_INTERPRETATION_SENTINEL
                            )
                        ]
                    ),
                ],
            ),
            (
                "post-transport-error",
                [
                    self.vocabulary_response(),
                    self.collection_response([]),
                    OSError(TRANSPORT_EXCEPTION_SENTINEL),
                    harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL),
                ],
            ),
        )
        for name, responses in scenarios:
            with self.subTest(scenario=name):
                transport = FakeTransport(list(responses))
                executor = harness.InterpretationCreateExecutor(transport)
                _root, store = self.make_store()
                test_credential = self.credential()
                stdout, stderr = io.StringIO(), io.StringIO()
                failure: BaseException | None = None
                with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
                    try:
                        plan = executor.preflight(test_credential, ACCOUNT_LABEL)
                        executor.commit(
                            plan,
                            plan.expected_confirmation,
                            test_credential,
                            state_store=store,
                        )
                    except harness.InterpretationCreateFailure as raised:
                        failure = raised
                self.assertIsNotNone(failure, name)
                rendered = (
                    self.rendered(failure) + stdout.getvalue() + stderr.getvalue()
                )
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
                self.assertIsNone(failure.__cause__)
                self.assertIsNone(failure.__context__)

    def test_plan_repr_and_str_never_expose_the_raw_id_or_label(self) -> None:
        _executor, _transport, plan = self.preflight(
            [self.vocabulary_response(), self.collection_response([])]
        )
        rendered = f"{plan!r}{plan}"
        self.assertNotIn(VOCABULARY_ID, rendered)
        self.assertNotIn(ACCOUNT_LABEL, rendered)
        self.assertNotIn(FAKE_TOKEN, rendered)
        self.assertIn(plan.voc_id_fingerprint, rendered)

    def test_the_credential_is_absent_from_every_success_and_failure_surface(
        self,
    ) -> None:
        success = self.run_probe(self.success_responses())
        failure = self.run_probe(
            [
                self.vocabulary_response(),
                self.collection_response([]),
                self.post_response(),
                self.collection_response([]),
            ]
        )
        surfaces = [
            json.dumps(success["result"].safe_summary(), ensure_ascii=False),
            repr(success["result"]),
            str(success["result"]),
            json.dumps(success["plan"].safe_preview(), ensure_ascii=False),
            json.dumps(success["journal"], ensure_ascii=False),
            self.rendered(failure["failure"]),
            json.dumps(failure["journal"], ensure_ascii=False),
        ]
        for surface in surfaces:
            self.assertNotIn(FAKE_TOKEN, surface)
            self.assertNotIn("Authorization", surface)
            self.assertNotIn("Cookie", surface)

    def test_the_preview_shows_the_intended_content_but_no_raw_id(self) -> None:
        _executor, _transport, plan = self.preflight(
            [self.vocabulary_response(), self.collection_response([])]
        )
        preview = plan.safe_preview()
        self.assertEqual(preview["operation"], "interpretation-create")
        self.assertEqual(preview["host"], "https://open.maimemo.com")
        self.assertEqual(preview["method"], "POST")
        self.assertEqual(preview["path"], CREATE_PATH)
        self.assertEqual(preview["requested_spelling"], "acquisition")
        self.assertEqual(preview["intended_interpretation"], "n. 收购；购置；获得")
        self.assertEqual(preview["intended_tags"], ["MBA", "BEC", "GMAT"])
        self.assertEqual(preview["intended_status"], "PUBLISHED")
        self.assertEqual(preview["preflight_interpretation_count"], 0)
        self.assertEqual(preview["account_label"], "[REDACTED]")
        self.assertEqual(
            preview["write_policy"], "EXACTLY ONE POST / NO RETRY / IMMEDIATE READBACK"
        )
        self.assertEqual(preview["maximum_requests"]["post"], 1)
        self.assertEqual(preview["maximum_requests"]["retries"], 0)
        self.assertEqual(preview["maximum_requests"]["phrase_calls"], 0)
        rendered = json.dumps(preview, ensure_ascii=False, sort_keys=True)
        self.assertNotIn(VOCABULARY_ID, rendered)
        self.assertNotIn(ACCOUNT_LABEL, rendered)
        self.assertNotIn(FAKE_TOKEN, rendered)

    def test_the_diagnostic_field_set_is_exactly_the_documented_contract(self) -> None:
        outcome = self.run_probe(
            [
                self.vocabulary_response(),
                self.collection_response([]),
                self.post_response(),
                self.collection_response([]),
            ]
        )
        self.assertEqual(
            set(outcome["failure"].safe_summary()),
            {
                "mode",
                "status",
                "operation",
                "failure_stage",
                "failure_class",
                "http_status",
                "post_attempted",
                "post_count",
                "readback_attempted",
                "write_outcome",
                "requests_attempted",
                "requests_completed",
            },
        )


# ---------------------------------------------------------------------------
# I. Private journal
# ---------------------------------------------------------------------------


class JournalTests(InterpretationCreateFixtures, unittest.TestCase):
    def test_the_journal_is_private_ignored_and_free_of_credentials(self) -> None:
        root, store = self.make_store()
        outcome = self.run_probe(self.success_responses(), store=store)
        destination = root / "issue24-interpretation-create-1.json"
        self.assertTrue(destination.is_file())
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        content = destination.read_text(encoding="utf-8")
        for forbidden in (
            FAKE_TOKEN,
            ACCOUNT_LABEL,
            VOCABULARY_ID,
            CREATED_RECORD_ID,
            "Authorization",
            "Cookie",
            SERVER_KEY_SENTINEL,
            SERVER_VALUE_SENTINEL,
            POST_RESPONSE_SENTINEL,
            UNSAFE_RECORD_ID_SENTINEL,
        ):
            self.assertNotIn(forbidden, content)
        ignore_rules = {
            line.strip()
            for line in (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertIn("artifacts/private/", ignore_rules)
        self.assertIsNotNone(outcome["result"])

    def test_the_journal_records_the_write_continuity_contract(self) -> None:
        outcome = self.run_probe(self.success_responses())
        journal = outcome["journal"]
        self.assertEqual(journal["mode"], "interpretation-create-probe")
        self.assertEqual(journal["operation"], "interpretation-create")
        self.assertEqual(journal["status"], "verified")
        self.assertEqual(journal["method"], "POST")
        self.assertEqual(journal["path"], CREATE_PATH)
        self.assertEqual(journal["requested_spelling"], "acquisition")
        self.assertEqual(journal["intended_interpretation"], "n. 收购；购置；获得")
        self.assertEqual(journal["intended_tags"], ["MBA", "BEC", "GMAT"])
        self.assertEqual(journal["intended_status"], "PUBLISHED")
        self.assertEqual(journal["preflight_interpretation_count"], 0)
        self.assertEqual(
            journal["request_body_digest"], outcome["plan"].request_body_digest
        )
        self.assertEqual(
            journal["voc_id_fingerprint"], outcome["plan"].voc_id_fingerprint
        )
        self.assertTrue(journal["post_attempted"])
        self.assertEqual(journal["post_count"], 1)
        self.assertTrue(journal["readback_attempted"])
        self.assertEqual(journal["readback_result"], "matched-exactly-one")
        self.assertEqual(journal["write_outcome"], "confirmed-success")
        self.assertEqual(journal["write_status"], 200)
        self.assertEqual(journal["read_status"], 200)
        self.assertEqual(
            journal["created_record_id_fingerprint"],
            hashlib.sha256(CREATED_RECORD_ID.encode("utf-8")).hexdigest()[:16],
        )
        self.assertNotIn("voc_id", journal)
        self.assertNotIn("account_label", journal)

    def test_the_journal_records_prepared_not_sent_before_any_post(self) -> None:
        captured: list[dict] = []
        _root, store = self.make_store()
        original = store.begin_interpretation_create

        def spy(plan: object, fingerprint: str) -> Path:
            path = original(plan, fingerprint)
            captured.append(
                store.read(harness.INTERPRETATION_CREATE_JOURNAL_SEQUENCE)
            )
            return path

        store.begin_interpretation_create = spy  # type: ignore[assignment]
        outcome = self.run_probe(self.success_responses(), store=store)
        self.assertEqual(len(captured), 1)
        self.assertEqual(captured[0]["status"], "prepared-not-sent")
        self.assertFalse(captured[0]["post_attempted"])
        self.assertEqual(captured[0]["post_count"], 0)
        self.assertEqual(captured[0]["write_outcome"], "not-attempted")
        self.assertIsNotNone(outcome["result"])

    def test_a_journal_failure_before_the_post_blocks_the_write(self) -> None:
        _root, store = self.make_store()

        def refuse(*_args: object, **_kwargs: object) -> Path:
            raise harness.SafetyError("journal refused")

        store.begin_interpretation_create = refuse  # type: ignore[assignment]
        outcome = self.run_probe(self.success_responses(), store=store)
        self.assert_no_post(outcome)
        self.assertIsNone(outcome["result"])
        self.assertEqual(
            outcome["failure"].safe_summary()["write_outcome"], "not-attempted"
        )

    def test_an_existing_journal_blocks_a_replay_before_any_post(self) -> None:
        _root, store = self.make_store()
        first = self.run_probe(self.success_responses(), store=store)
        self.assertIsNotNone(first["result"])
        second = self.run_probe(self.success_responses(), store=store)
        self.assert_no_post(second)
        self.assertIsNone(second["result"])
        self.assertEqual(second["journal"]["status"], "verified")

    def test_the_journal_root_and_prefix_stay_inside_the_reviewed_namespace(
        self,
    ) -> None:
        with self.assertRaises(harness.SafetyError):
            harness.PrivateStateStore(
                ROOT / "artifacts", journal_prefix="issue24-interpretation-create"
            )
        with self.assertRaises(harness.SafetyError):
            harness.PrivateStateStore(journal_prefix="../escape")
        with self.assertRaises(harness.SafetyError):
            harness.PrivateStateStore(journal_prefix=SERVER_KEY_SENTINEL)
        self.assertEqual(
            harness.PRIVATE_JOURNAL_PREFIXES,
            ("issue9-step", "issue24-interpretation-create"),
        )

    def test_a_symlinked_journal_destination_is_refused(self) -> None:
        root, store = self.make_store()
        destination = root / "issue24-interpretation-create-1.json"
        outside = root / "outside.json"
        outside.write_text("{}", encoding="utf-8")
        destination.symlink_to(outside)
        outcome = self.run_probe(self.success_responses(), store=store)
        self.assert_no_post(outcome)
        self.assertIsNone(outcome["result"])
        self.assertEqual(outside.read_text(encoding="utf-8"), "{}")

    def test_the_issue9_journal_namespace_is_untouched(self) -> None:
        store = harness.PrivateStateStore(journal_prefix="issue9-step")
        self.assertEqual(store.journal_prefix, "issue9-step")
        self.assertEqual(
            store._destination(3).name,
            "issue9-step-3.json",
        )
        write_store = harness.PrivateStateStore(
            journal_prefix=harness.INTERPRETATION_CREATE_JOURNAL_PREFIX
        )
        self.assertEqual(
            write_store._destination(1).name,
            "issue24-interpretation-create-1.json",
        )


# ---------------------------------------------------------------------------
# I2. A failed post-POST journal transition still reaches the single readback
#
# Once the single POST has been dispatched the private journal is no longer the
# last safety boundary — the one GET-only readback is. A local journal failure
# must therefore never suppress that readback, never replay the write and never
# route execution back into the POST path. It may only downgrade the *reported*
# result, because a proven record that cannot be durably recorded must not be
# announced as a success.
# ---------------------------------------------------------------------------


class PostJournalFailureReadbackTests(
    InterpretationCreateFixtures, unittest.TestCase
):
    # The two post-POST transitions: a clear 2xx acknowledges, an uncertain POST
    # goes to unknown. Both must behave identically when the journal refuses.
    POST_JOURNAL_TRANSITIONS = (
        "mark_interpretation_create_acknowledged",
        "mark_interpretation_create_unknown",
    )

    def refusing_store(self, method: str) -> harness.PrivateStateStore:
        """A journal whose single post-POST transition always refuses."""
        _root, store = self.make_store()

        def refuse(*_args: object, **_kwargs: object) -> Path:
            raise harness.SafetyError("journal refused")

        setattr(store, method, refuse)
        return store

    def responses_for(self, method: str, readback: object) -> list[object]:
        """Preflight plus a POST whose outcome selects the refused transition."""
        responses = self.success_responses()
        if method == "mark_interpretation_create_unknown":
            responses[2] = harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)
        responses[3] = readback
        return responses

    def run_post_journal_failure(
        self, method: str, readback: object
    ) -> tuple[dict, Mapping[str, object]]:
        """Drive the probe with a refusing journal and assert the shared floor.

        Every case must show the same safe sequence: preflight GET, preflight
        GET, exactly one POST, exactly one readback GET — then a fail-closed,
        sanitized diagnostic that still proves the readback was attempted.
        """
        store = self.refusing_store(method)
        outcome = self.run_probe(self.responses_for(method, readback), store=store)
        transport = outcome["transport"]

        # One POST, then one readback GET. Never a second POST.
        self.assert_single_post(outcome)
        self.assertEqual(
            transport.calls(),
            [
                ("GET", VOCABULARY_PATH),
                ("GET", INTERPRETATIONS_PATH),
                ("POST", CREATE_PATH),
                ("GET", INTERPRETATIONS_PATH),
            ],
        )
        self.assertEqual({call[0] for call in transport.calls()}, {"GET", "POST"})
        for _method, path in transport.calls():
            self.assertNotIn("phrase", path)

        # Fail closed, but with the readback proven and the POST count pinned.
        self.assertIsNone(outcome["result"])
        summary = outcome["failure"].safe_summary()
        self.assertEqual(summary["status"], "failed")
        self.assertEqual(summary["failure_stage"], "readback")
        self.assertTrue(summary["readback_attempted"])
        self.assertTrue(summary["post_attempted"])
        self.assertEqual(summary["post_count"], 1)
        self.assertNotIn(
            summary["write_outcome"], ("confirmed-success", "recovered-success")
        )
        self.assertEqual(summary["requests_attempted"], 4)

        # The refused transition left the journal in its pre-POST state, which
        # keeps blocking every replay, and it never gained a record fingerprint.
        journal = outcome["journal"]
        self.assertEqual(journal["status"], "prepared-not-sent")
        self.assertIsNone(journal["created_record_id_fingerprint"])

        # Nothing server-owned escapes through the failure or the journal.
        rendered = self.rendered(outcome["failure"])
        journal_text = json.dumps(journal, ensure_ascii=False, sort_keys=True)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
            self.assertNotIn(sentinel, journal_text)
        return summary, outcome

    def test_case_a_and_b_a_matching_readback_still_runs_but_is_not_a_success(
        self,
    ) -> None:
        """A: clear 2xx + acknowledged failure. B: uncertain POST + unknown
        failure. Both still read back, and both refuse to claim success while a
        verified state cannot be persisted."""
        for method in self.POST_JOURNAL_TRANSITIONS:
            with self.subTest(method=method):
                summary, _outcome = self.run_post_journal_failure(
                    method, self.collection_response([self.created_record()])
                )
                self.assertEqual(summary["failure_class"], "safety")
                self.assertEqual(summary["write_outcome"], "not-verified")
                self.assertIsNone(summary["http_status"])

    def test_case_c_a_post_journal_failure_with_an_empty_readback_fails_closed(
        self,
    ) -> None:
        for method in self.POST_JOURNAL_TRANSITIONS:
            with self.subTest(method=method):
                summary, _outcome = self.run_post_journal_failure(
                    method, self.collection_response([])
                )
                self.assertEqual(summary["failure_class"], "unknown-write-outcome")
                self.assertEqual(summary["write_outcome"], "not-verified")
                self.assertEqual(summary["http_status"], 200)

    def test_case_d_a_post_journal_failure_with_a_failed_readback_fails_closed(
        self,
    ) -> None:
        for method in self.POST_JOURNAL_TRANSITIONS:
            with self.subTest(method=method):
                summary, _outcome = self.run_post_journal_failure(
                    method, harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)
                )
                self.assertEqual(summary["failure_class"], "transport")
                self.assertEqual(summary["write_outcome"], "not-verified")
                self.assertIsNone(summary["http_status"])

    def test_case_d_a_non_2xx_readback_after_a_post_journal_failure_fails_closed(
        self,
    ) -> None:
        for method in self.POST_JOURNAL_TRANSITIONS:
            with self.subTest(method=method):
                summary, _outcome = self.run_post_journal_failure(
                    method, self.collection_response([], status=500)
                )
                self.assertEqual(summary["failure_class"], "http-status")
                self.assertEqual(summary["write_outcome"], "not-verified")
                self.assertEqual(summary["http_status"], 500)

    def test_case_e_a_journal_failure_can_never_re_enter_the_post_path(self) -> None:
        for method in self.POST_JOURNAL_TRANSITIONS:
            with self.subTest(method=method):
                _summary, outcome = self.run_post_journal_failure(
                    method, self.collection_response([self.created_record()])
                )
                transport = outcome["transport"]
                executor = outcome["executor"]
                plan = outcome["plan"]
                # Everything the POST was followed by was GET-only.
                self.assertEqual([call[0] for call in transport.calls()[3:]], ["GET"])

                # The guard has permanently consumed its single POST budget, so
                # even a direct re-send is structurally refused.
                with self.assertRaises(harness.SafetyError):
                    executor._guard.send(plan.write_request(), self.credential())
                self.assertEqual(len(transport.posts()), 1)
                self.assertEqual(executor.post_count, 1)

                # A second commit is refused as well, still without a POST.
                with self.assertRaises(harness.InterpretationCreateFailure) as raised:
                    executor.commit(
                        plan,
                        plan.expected_confirmation,
                        self.credential(),
                        state_store=outcome["store"],
                    )
                self.assertEqual(len(transport.posts()), 1)
                self.assertEqual(executor.post_count, 1)
                self.assertEqual(raised.exception.safe_summary()["post_count"], 1)

                # A fresh executor over the same journal is blocked before any
                # request, so the refused transition can never become a replay.
                replay = self.run_probe(
                    self.success_responses(), store=outcome["store"]
                )
                self.assert_no_post(replay)
                self.assertIsNone(replay["result"])

    def test_a_post_journal_failure_never_updates_or_deletes_anything(self) -> None:
        for method in self.POST_JOURNAL_TRANSITIONS:
            with self.subTest(method=method):
                _summary, outcome = self.run_post_journal_failure(
                    method, self.collection_response([self.created_record()])
                )
                for request in outcome["transport"].requests:
                    self.assertIn(request.method, ("GET", "POST"))
                    self.assertNotIn(request.method, ("PUT", "PATCH", "DELETE"))
                    self.assertTrue(request.path.startswith("/open/api/v1/"))
                # Only the single create carried a payload at all.
                self.assertEqual(
                    [
                        request.method
                        for request in outcome["transport"].requests
                        if request.payload is not None
                    ],
                    ["POST"],
                )


# ---------------------------------------------------------------------------
# Contract, enums and CLI
# ---------------------------------------------------------------------------


class ContractTests(InterpretationCreateFixtures, unittest.TestCase):
    def test_the_fixed_write_contract_is_exactly_the_issue_24_target(self) -> None:
        self.assertEqual(harness.INTERPRETATION_CREATE_SPELLING, "acquisition")
        self.assertEqual(harness.INTERPRETATION_CREATE_TEXT, "n. 收购；购置；获得")
        self.assertEqual(harness.INTERPRETATION_CREATE_TAGS, ("MBA", "BEC", "GMAT"))
        self.assertEqual(harness.INTERPRETATION_CREATE_STATUS, "PUBLISHED")
        self.assertEqual(harness.INTERPRETATION_CREATE_PATH, CREATE_PATH)
        self.assertEqual(harness.MAX_INTERPRETATION_CREATE_POSTS, 1)
        self.assertEqual(harness.MAX_INTERPRETATION_CREATE_GETS, 3)
        harness._validate_interpretation_create_contract()

    def test_any_contract_drift_fails_closed(self) -> None:
        drifts = {
            "INTERPRETATION_CREATE_SPELLING": "apple",
            "INTERPRETATION_CREATE_TEXT": "API test",
            "INTERPRETATION_CREATE_TAGS": ("MBA", "BEC"),
            "INTERPRETATION_CREATE_STATUS": "UNPUBLISHED",
            "INTERPRETATION_CREATE_PATH": "/open/api/v1/phrases",
            "MAX_INTERPRETATION_CREATE_POSTS": 2,
            "MAX_INTERPRETATION_CREATE_GETS": 9,
            "PRODUCTION_HOST": "example.invalid",
            "WRITE_CONFIRMATION_PREFIX": "CONFIRM READ-ONLY PROBE",
        }
        for name, value in drifts.items():
            with self.subTest(constant=name):
                with mock.patch.object(harness, name, value):
                    with self.assertRaises(harness.SafetyError):
                        harness._validate_interpretation_create_contract()

    def test_every_closed_enum_stays_project_owned(self) -> None:
        self.assertEqual(
            harness.INTERPRETATION_CREATE_FAILURE_STAGES,
            (
                "transport-init",
                "preflight-vocabulary",
                "preflight-interpretations",
                "confirmation",
                "write",
                "readback",
            ),
        )
        self.assertEqual(
            harness.INTERPRETATION_CREATE_FAILURE_CLASSES,
            (
                "transport",
                "http-status",
                "schema",
                "safety",
                "confirmation",
                "ambiguous",
                "mismatch",
                "unknown-write-outcome",
            ),
        )
        self.assertEqual(
            harness.INTERPRETATION_CREATE_WRITE_OUTCOMES,
            (
                "not-attempted",
                "confirmed-success",
                "recovered-success",
                "not-verified",
                "ambiguous",
            ),
        )
        for enum in (
            harness.INTERPRETATION_CREATE_FAILURE_STAGES,
            harness.INTERPRETATION_CREATE_FAILURE_CLASSES,
            harness.INTERPRETATION_CREATE_WRITE_OUTCOMES,
            harness.INTERPRETATION_CREATE_READBACK_RESULTS,
        ):
            self.assertIsInstance(enum, tuple)
            self.assertEqual(len(enum), len(set(enum)))

    def test_an_equal_string_never_becomes_the_emitted_enum_member(self) -> None:
        injected = "".join(("not", "-attempted"))
        self.assertIsNot(injected, harness.WRITE_OUTCOME_NOT_ATTEMPTED)
        diagnostic = harness.InterpretationCreateDiagnostic(
            failure_stage="".join(("confirm", "ation")),
            failure_class="".join(("confirm", "ation")),
            http_status=None,
            post_attempted=False,
            post_count=0,
            readback_attempted=False,
            write_outcome=injected,
            requests_attempted=2,
            requests_completed=2,
        )
        self.assertIs(diagnostic.write_outcome, harness.WRITE_OUTCOME_NOT_ATTEMPTED)
        self.assertIs(
            diagnostic.failure_stage, harness.INTERPRETATION_CREATE_FAILURE_STAGES[3]
        )
        self.assertIs(
            diagnostic.failure_class, harness.INTERPRETATION_CREATE_FAILURE_CLASSES[4]
        )

    def test_the_diagnostic_rejects_every_out_of_contract_combination(self) -> None:
        base = {
            "failure_stage": "readback",
            "failure_class": "mismatch",
            "http_status": 200,
            "post_attempted": True,
            "post_count": 1,
            "readback_attempted": True,
            "write_outcome": "not-verified",
            "requests_attempted": 4,
            "requests_completed": 4,
        }
        harness.InterpretationCreateDiagnostic(**base)  # type: ignore[arg-type]
        invalid = (
            {"failure_stage": SERVER_KEY_SENTINEL},
            {"failure_class": SERVER_KEY_SENTINEL},
            {"write_outcome": SERVER_KEY_SENTINEL},
            {"write_outcome": "confirmed-success"},
            {"write_outcome": "recovered-success"},
            {"post_count": 2},
            {"post_count": 0},
            {"post_attempted": False},
            {"post_count": 0, "post_attempted": False, "readback_attempted": True},
            {"failure_stage": "confirmation"},
            {"failure_class": "transport"},
            {"failure_class": "safety"},
            {"failure_class": "confirmation"},
            {"failure_class": "http-status"},
            {"requests_completed": 5},
            {"requests_attempted": 3, "requests_completed": 4},
            {"readback_attempted": False},
            {"http_status": "200"},
            {"http_status": 42},
        )
        for override in invalid:
            with self.subTest(override=override):
                with self.assertRaises(harness.SafetyError):
                    harness.InterpretationCreateDiagnostic(
                        **{**base, **override}  # type: ignore[arg-type]
                    )

    def test_no_write_outcome_may_precede_the_write_stage(self) -> None:
        for stage in (
            "transport-init",
            "preflight-vocabulary",
            "preflight-interpretations",
            "confirmation",
        ):
            with self.subTest(stage=stage):
                with self.assertRaises(harness.SafetyError):
                    harness.InterpretationCreateDiagnostic(
                        failure_stage=stage,
                        failure_class="safety",
                        http_status=None,
                        post_attempted=True,
                        post_count=1,
                        readback_attempted=False,
                        write_outcome="not-verified",
                        requests_attempted=3,
                        requests_completed=3,
                    )


class CliTests(InterpretationCreateFixtures, unittest.TestCase):
    def drive_cli(
        self,
        responses: list[object],
        *,
        argv: list[str] | None = None,
        isatty: bool = True,
        confirmation: object = None,
    ) -> tuple[int, str, FakeTransport]:
        transport = FakeTransport(responses)
        _root, store = self.make_store()
        stdout = io.StringIO()

        def token_prompt(_message: str) -> str:
            return FAKE_TOKEN

        def confirmation_prompt(_message: str) -> str:
            if confirmation is not None:
                return str(confirmation)
            text = stdout.getvalue()
            start = text.index("{")
            return json.loads(text[start:])["required_confirmation"]

        with mock.patch("sys.stdout", stdout):
            code = harness.main(
                argv if argv is not None else self.cli_args(),
                token_prompt=token_prompt,
                confirmation_prompt=confirmation_prompt,
                transport_factory=lambda: transport,
                stdin_isatty=lambda: isatty,
                state_store_factory=lambda: store,
            )
        return code, stdout.getvalue(), transport

    def test_the_cli_runs_the_documented_operator_command(self) -> None:
        code, output, transport = self.drive_cli(self.success_responses())
        self.assertEqual(code, 0)
        self.assertIn("EXACTLY ONE POST / NO RETRY / IMMEDIATE READBACK", output)
        self.assertIn('"status": "succeeded"', output)
        self.assertEqual(len(transport.posts()), 1)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, output)

    def test_the_cli_never_accepts_content_or_a_token_on_the_command_line(self) -> None:
        rejected = (
            [*self.cli_args(), "--token", FAKE_TOKEN],
            [*self.cli_args(), "--word", "acquisition"],
            [*self.cli_args(), "--interpretation", "n. 收购"],
            [*self.cli_args(), "--tags", "MBA,BEC,GMAT"],
            [*self.cli_args(), "--status", "PUBLISHED"],
            [*self.cli_args(), "--voc-id", VOCABULARY_ID],
            ["interpretation-create-probe", "--allow-network"],
        )
        for argv in rejected:
            with self.subTest(argv=argv[-2:]):
                stderr = io.StringIO()
                with self.assertRaises(SystemExit), mock.patch("sys.stderr", stderr):
                    harness.parse_args(argv)
                rendered = stderr.getvalue()
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_the_cli_blocks_without_allow_network_a_tty_or_a_valid_label(self) -> None:
        cases = (
            (["interpretation-create-probe", "--account-label", ACCOUNT_LABEL], True),
            (self.cli_args(), False),
        )
        for argv, isatty in cases:
            with self.subTest(argv=argv, isatty=isatty):
                transport = FakeTransport([])
                stdout = io.StringIO()

                def forbidden_prompt(_message: str) -> str:
                    raise AssertionError("a blocked CLI path called a hidden prompt")

                with mock.patch("sys.stdout", stdout):
                    code = harness.main(
                        argv,
                        token_prompt=forbidden_prompt,
                        confirmation_prompt=forbidden_prompt,
                        transport_factory=lambda: transport,
                        stdin_isatty=lambda: isatty,
                    )
                self.assertEqual(code, 3)
                self.assertIn("BLOCKED", stdout.getvalue())
                self.assertEqual(transport.requests, [])

        for label in ("main account", "production", "主账号"):
            with self.subTest(label=label):
                transport = FakeTransport([])
                stdout = io.StringIO()
                with mock.patch("sys.stdout", stdout):
                    code = harness.main(
                        [
                            "interpretation-create-probe",
                            "--account-label",
                            label,
                            "--allow-network",
                        ],
                        token_prompt=lambda _m: FAKE_TOKEN,
                        confirmation_prompt=lambda _m: "",
                        transport_factory=lambda: transport,
                        stdin_isatty=lambda: True,
                    )
                self.assertEqual(code, 3)
                self.assertEqual(transport.requests, [])

    def test_the_cli_prints_one_sanitized_diagnostic_on_failure(self) -> None:
        code, output, transport = self.drive_cli(
            [
                self.vocabulary_response(),
                self.collection_response([self.foreign_record()]),
            ]
        )
        self.assertEqual(code, 4)
        self.assertIn('"status": "failed"', output)
        self.assertIn('"write_outcome": "not-attempted"', output)
        self.assertEqual(transport.posts(), [])
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, output)

    def test_a_wrong_cli_confirmation_sends_zero_posts(self) -> None:
        code, output, transport = self.drive_cli(
            self.success_responses(), confirmation="CONFIRM ONE REAL INTERPRETATION WRITE"
        )
        self.assertEqual(code, 4)
        self.assertIn('"failure_class": "confirmation"', output)
        self.assertEqual(transport.posts(), [])

    def test_the_offline_default_mode_never_prompts_or_writes(self) -> None:
        def forbidden(_message: str) -> str:
            raise AssertionError("offline mode called a hidden prompt")

        with mock.patch("sys.stdout", io.StringIO()):
            self.assertEqual(
                harness.main(
                    [],
                    token_prompt=forbidden,
                    confirmation_prompt=forbidden,
                    transport_factory=lambda: FakeTransport([]),
                    stdin_isatty=lambda: False,
                ),
                0,
            )

    def test_the_subcommand_cannot_be_combined_with_a_legacy_network_mode(self) -> None:
        with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
            harness.parse_args(["--mode", "live-step", *self.cli_args()])


# ---------------------------------------------------------------------------
# J. Process-level no-network guard
# ---------------------------------------------------------------------------


class NoNetworkGuardTests(InterpretationCreateFixtures, unittest.TestCase):
    def test_no_maimemo_request_is_possible_under_the_process_guard(self) -> None:
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        for blocked in (
            socket.socket,
            socket.create_connection,
            urllib.request.urlopen,
        ):
            with self.subTest(blocked=getattr(blocked, "__name__", repr(blocked))):
                with self.assertRaises(RuntimeError):
                    blocked()

    def test_the_production_transport_cannot_reach_the_network_here(self) -> None:
        transport = harness.ProductionHttpTransport()
        request = harness.HttpRequest("POST", CREATE_PATH, EXPECTED_BODY)
        with self.assertRaises(harness.TransportError):
            transport.send(request, self.credential())


if __name__ == "__main__":
    unittest.main()
