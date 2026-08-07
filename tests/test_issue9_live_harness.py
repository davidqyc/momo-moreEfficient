from __future__ import annotations

from collections.abc import Iterator, Mapping
import hashlib
import http.client
import io
import json
import os
import ssl
from dataclasses import replace
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
SCRIPTS = ROOT / "scripts"
FIXTURE = ROOT / "tests" / "fixtures" / "issue2-smoke-input.example.json"
sys.path.insert(0, str(SCRIPTS))

import issue9_live_harness as harness  # noqa: E402


FAKE_TOKEN = "FAKE_TEST_CREDENTIAL_NOT_VALID"
ACCOUNT_LABEL = "issue9-secondary-fixture"
TAGS = ["MBA", "BEC", "GMAT"]


class FakeTransport:
    def __init__(
        self,
        responses: list[harness.HttpResponse | Exception] | None = None,
        hook: object | None = None,
    ) -> None:
        self.responses = list(responses or [])
        self.hook = hook
        self.requests: list[harness.HttpRequest] = []

    def send(
        self,
        request: harness.HttpRequest,
        _credential: harness.TestAccountCredential,
    ) -> harness.HttpResponse:
        self.requests.append(request)
        if callable(self.hook):
            self.hook(request, len(self.requests) - 1)
        if not self.responses:
            raise AssertionError("fake transport has no queued response")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def credential() -> harness.TestAccountCredential:
    return harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL)


def valid_gate(
    test_credential: harness.TestAccountCredential,
) -> harness.ManualAccountGate:
    fingerprint = test_credential.fingerprint
    return harness.ManualAccountGate(
        allow_network=True,
        account_label=ACCOUNT_LABEL,
        credential_fingerprint=fingerprint,
        confirmation=(
            f"CONFIRM SECONDARY TEST ACCOUNT: {ACCOUNT_LABEL} "
            f"TOKEN-FP: {fingerprint}"
        ),
    )


def phrase_rollback(record_id: str = "INVALID_PHRASE_ID") -> dict[str, object]:
    return {
        "id": record_id,
        "phrase": "OFFLINE PREVIOUS PHRASE",
        "interpretation": "OFFLINE PREVIOUS TRANSLATION",
        "tags": list(TAGS),
        "origin": "OFFLINE_PREVIOUS_ORIGIN",
        "status": "PUBLISHED",
    }


def interpretation_record(
    step: harness.PreparedStep,
    record_id: str = "INVALID_INTERPRETATION_ID",
) -> dict[str, object]:
    payload = step.payload["interpretation"]
    return {
        "id": record_id,
        "interpretation": payload["interpretation"],
        "tags": list(payload["tags"]),
        "status": payload["status"],
    }


def phrase_record(
    step: harness.PreparedStep,
    highlight: object,
    record_id: str = "INVALID_PHRASE_ID",
) -> dict[str, object]:
    payload = step.payload["phrase"]
    return {
        "id": record_id,
        "phrase": payload["phrase"],
        "interpretation": payload["interpretation"],
        "tags": list(payload["tags"]),
        "origin": payload["origin"],
        "status": "PUBLISHED",
        "highlight": highlight,
    }


def responses_for_step(
    step: harness.PreparedStep,
    readback_record: dict[str, object],
    *,
    preflight_record: dict[str, object] | None = None,
    create_baseline_records: list[dict[str, object]] | None = None,
    post_readback_records: list[dict[str, object]] | None = None,
) -> list[harness.HttpResponse]:
    singular = "interpretation" if step.response_key == "interpretations" else "phrase"
    record_id = str(readback_record["id"])
    responses: list[harness.HttpResponse] = []
    if step.action.startswith("update_"):
        if preflight_record is None:
            raise AssertionError("update fake responses require a preflight record")
        responses.append(
            harness.HttpResponse(200, {step.response_key: [preflight_record]})
        )
    else:
        baseline_records = list(create_baseline_records or [])
        responses.append(
            harness.HttpResponse(
                200,
                {step.response_key: baseline_records},
            )
        )
    final_records = (
        list(post_readback_records)
        if post_readback_records is not None
        else (
            list(create_baseline_records or []) + [readback_record]
            if not step.action.startswith("update_")
            else [readback_record]
        )
    )
    responses.extend(
        [
            harness.HttpResponse(200, {singular: {"id": record_id}}),
            harness.HttpResponse(200, {step.response_key: final_records}),
        ]
    )
    return responses


class Issue9SafetyTests(unittest.TestCase):
    def setUp(self) -> None:
        harness.PRIVATE_STATE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(harness.PRIVATE_STATE_ROOT, 0o700)
        self.plan = harness.build_offline_plan(FIXTURE)

    def make_store(self, prefix: str) -> tuple[Path, harness.PrivateStateStore]:
        root = Path(
            tempfile.mkdtemp(prefix=prefix, dir=harness.PRIVATE_STATE_ROOT)
        )
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        return root, harness.PrivateStateStore(root)

    def make_interpretation_update_step(
        self,
        record_id: str = "INVALID_INTERPRETATION_UPDATE_ID",
    ) -> tuple[harness.PreparedStep, dict[str, object]]:
        decision = harness.choose_interpretation_operation(
            self.plan["vocabulary"]["id"],
            "OFFLINE REPLACEMENT INTERPRETATION",
            [
                harness.ExistingInterpretation(
                    record_id,
                    "OFFLINE PREVIOUS INTERPRETATION",
                    True,
                    tuple(TAGS),
                    "PUBLISHED",
                )
            ],
        )
        snapshot = dict(decision.existing_record or {})
        return (
            harness.prepare_operation(
                decision.operation,
                self.plan["vocabulary"]["id"],
                existing_record=snapshot,
            ),
            snapshot,
        )

    def test_global_test_guard_blocks_socket_creation(self) -> None:
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        with self.assertRaisesRegex(RuntimeError, "network disabled"):
            socket.socket()

    def test_default_cli_is_offline_and_never_instantiates_real_transport(self) -> None:
        output = io.StringIO()
        with mock.patch.object(
            harness.ProductionHttpTransport,
            "__init__",
            side_effect=AssertionError("real transport instantiated"),
        ), mock.patch("sys.stdout", output):
            result = harness.main([])
        self.assertEqual(result, 0)
        self.assertIn("DRY RUN — NO REQUEST SENT", output.getvalue())

    def test_cli_has_no_token_input_and_network_modes_remain_blocked(self) -> None:
        with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
            harness.parse_args(["--token", FAKE_TOKEN])
        for mode in ("read-only", "live-step"):
            output = io.StringIO()
            with mock.patch("sys.stdout", output):
                result = harness.main(["--mode", mode])
            self.assertEqual(result, 3)
            self.assertIn("BLOCKED", output.getvalue())
            self.assertNotIn(FAKE_TOKEN, output.getvalue())

    def test_official_schema_has_no_reliable_account_identity_endpoint(self) -> None:
        self.assertEqual(harness.IDENTITY_ENDPOINT_FINDING, "没有找到")

    def test_host_paths_timeouts_query_encoding_and_record_ids_are_locked(self) -> None:
        transport = harness.ProductionHttpTransport(
            connect_timeout_seconds=2.0, read_timeout_seconds=3.0
        )
        self.assertEqual(harness.PRODUCTION_HOST, "open.maimemo.com")
        self.assertEqual(harness.OPEN_API_PREFIX, "/open/api/v1")
        self.assertEqual(transport.connect_timeout_seconds, 2.0)
        self.assertEqual(transport.read_timeout_seconds, 3.0)
        path = harness.build_query_path(
            "interpretations", {"voc_id": "INVALID ID/?"}
        )
        self.assertEqual(
            path,
            "/open/api/v1/interpretations?voc_id=INVALID+ID%2F%3F",
        )
        self.assertEqual(
            harness.build_query_path("vocabulary", {"spelling": "sample word"}),
            "/open/api/v1/vocabulary?spelling=sample+word",
        )
        for resource, params in (
            ("vocabulary/query", {"spelling": "sampleword"}),
            ("vocabulary", {"voc_id": "INVALID"}),
            ("phrases", {"spelling": "sampleword"}),
            ("phrases", {"voc_id": "INVALID", "extra": "blocked"}),
        ):
            with self.subTest(resource=resource, params=params), self.assertRaises(
                harness.SafetyError
            ):
                harness.build_query_path(resource, params)
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest(
                "GET", "/open/api/v1/vocabulary/query?spelling=sampleword"
            )
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest("GET", "/api/v1/phrases?voc_id=INVALID")
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest("GET", "/open/api/v1/unreviewed?fixture=true")
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest("POST", "/open/api/v1/phrases/../escape", {})
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest("POST", "/open/api/v1/phrases/INVALID%2FESCAPE", {})
        with self.assertRaises(harness.SafetyError):
            harness.ProductionHttpTransport(connect_timeout_seconds=float("inf"))
        for unsafe_id in ("../escape", "with/slash", "query?id", "fragment#id", "line\nid"):
            with self.subTest(unsafe_id=unsafe_id), self.assertRaises(
                harness.SafetyError
            ):
                harness.prepare_plan_step(
                    self.plan,
                    3,
                    phrase_record_id=unsafe_id,
                    existing_record=phrase_rollback(unsafe_id),
                )

    def test_manual_account_gate_binds_label_and_token_fingerprint(self) -> None:
        test_credential = credential()
        wrong_fingerprint = "0" * 16
        blocked_gates = [
            harness.ManualAccountGate(
                False,
                ACCOUNT_LABEL,
                test_credential.fingerprint,
                valid_gate(test_credential).confirmation,
            ),
            harness.ManualAccountGate(
                True,
                ACCOUNT_LABEL,
                wrong_fingerprint,
                f"CONFIRM SECONDARY TEST ACCOUNT: {ACCOUNT_LABEL} TOKEN-FP: {wrong_fingerprint}",
            ),
            harness.ManualAccountGate(
                True, ACCOUNT_LABEL, test_credential.fingerprint, "wrong"
            ),
        ]
        for gate in blocked_gates:
            transport = FakeTransport()
            with self.assertRaises(harness.SafetyError):
                harness.run_read_only_probe(
                    transport,
                    test_credential,
                    gate,
                    "interpretations",
                    {"voc_id": "INVALID"},
                )
            self.assertEqual(transport.requests, [])
        with self.assertRaises(harness.SafetyError):
            harness.TestAccountCredential(
                FAKE_TOKEN, ACCOUNT_LABEL, source_name="main-account"
            )
        with self.assertRaises(harness.SafetyError):
            harness.ManualAccountGate(
                True,
                "main-test-account",
                test_credential.fingerprint,
                "OFFLINE FIXED CONFIRMATION",
            )
        self.assertNotIn(FAKE_TOKEN, valid_gate(test_credential).expected_confirmation)

    def test_account_label_gate_repr_str_and_errors_never_leak_token(self) -> None:
        invalid_labels = [
            "",
            " leading-space",
            "trailing-space ",
            "control\nlabel",
            "L" * (harness.MAX_ACCOUNT_LABEL_CHARS + 1),
            FAKE_TOKEN,
            f"secondary-{FAKE_TOKEN}-account",
            "主账号",
            "主号-test",
            "主账户-test",
            "生产-test",
            "PrOdUcTiOn-test-account",
            "OWNER-account-test",
            "ordinary-account",
        ]
        for label in invalid_labels:
            with self.subTest(label_kind=len(label)):
                with self.assertRaises(harness.SafetyError) as context:
                    harness.TestAccountCredential(FAKE_TOKEN, label)
                self.assertNotIn(FAKE_TOKEN, str(context.exception))
                if label:
                    self.assertNotIn(label, str(context.exception))

        for label in (
            "主账号",
            "主号-test",
            "主账户-test",
            "生产-test",
            "PrOdUcTiOn-test-account",
            "OWNER-account-test",
            "ordinary-account",
        ):
            with self.subTest(gate_label_length=len(label)):
                with self.assertRaises(harness.SafetyError) as gate_context:
                    harness.ManualAccountGate(
                        True,
                        label,
                        "0" * 16,
                        "OFFLINE FIXED CONFIRMATION",
                    )
                self.assertNotIn(FAKE_TOKEN, str(gate_context.exception))
                self.assertNotIn(label, str(gate_context.exception))

        chinese_label = "issue9-测试副账号"
        chinese_credential = harness.TestAccountCredential(FAKE_TOKEN, chinese_label)
        chinese_gate = harness.ManualAccountGate(
            True,
            chinese_label,
            chinese_credential.fingerprint,
            (
                f"CONFIRM SECONDARY TEST ACCOUNT: {chinese_label} "
                f"TOKEN-FP: {chinese_credential.fingerprint}"
            ),
        )
        chinese_gate.validate(chinese_credential)
        valid_gate(credential()).validate(credential())
        for rendered in (repr(chinese_credential), repr(chinese_gate), str(chinese_gate)):
            self.assertNotIn(FAKE_TOKEN, rendered)
            self.assertNotIn(chinese_label, rendered)

        test_credential = credential()
        confirmation_with_token = (
            f"CONFIRM SECONDARY TEST ACCOUNT: {ACCOUNT_LABEL} "
            f"TOKEN-FP: {test_credential.fingerprint} {FAKE_TOKEN}"
        )
        leaking_gate = harness.ManualAccountGate(
            True,
            ACCOUNT_LABEL,
            test_credential.fingerprint,
            confirmation_with_token,
        )
        with self.assertRaises(harness.SafetyError) as context:
            leaking_gate.validate(test_credential)
        self.assertNotIn(FAKE_TOKEN, str(context.exception))
        self.assertNotIn(confirmation_with_token, str(context.exception))

        safe_gate = valid_gate(test_credential)
        for rendered in (repr(safe_gate), str(safe_gate), repr(leaking_gate), str(leaking_gate)):
            self.assertNotIn(FAKE_TOKEN, rendered)
            self.assertNotIn(ACCOUNT_LABEL, rendered)
            self.assertNotIn(safe_gate.confirmation, rendered)
            self.assertIn(test_credential.fingerprint, rendered)

        malformed_confirmations = [
            "",
            " leading",
            "trailing ",
            "line\nbreak",
            "C" * (harness.MAX_GATE_CONFIRMATION_CHARS + 1),
        ]
        for confirmation in malformed_confirmations:
            with self.subTest(confirmation_length=len(confirmation)):
                with self.assertRaises(harness.SafetyError) as malformed_context:
                    harness.ManualAccountGate(
                        True,
                        ACCOUNT_LABEL,
                        test_credential.fingerprint,
                        confirmation,
                    )
                self.assertNotIn(FAKE_TOKEN, str(malformed_context.exception))
                if confirmation:
                    self.assertNotIn(confirmation, str(malformed_context.exception))

    def test_read_only_probe_uses_one_urlencoded_documented_get(self) -> None:
        test_credential = credential()
        transport = FakeTransport(
            [harness.HttpResponse(200, {"interpretations": []})]
        )
        result = harness.run_read_only_probe(
            transport,
            test_credential,
            valid_gate(test_credential),
            "interpretations",
            {"voc_id": "INVALID ID/?"},
        )
        self.assertEqual(
            result,
            {
                "status": 200,
                "response_shape": {
                    "canonical_key": "interpretations",
                    "canonical_key_present": True,
                    "unknown_top_level_field_count": 0,
                },
            },
        )
        self.assertEqual(len(transport.requests), 1)
        self.assertEqual(transport.requests[0].method, "GET")
        self.assertEqual(
            transport.requests[0].path,
            "/open/api/v1/interpretations?voc_id=INVALID+ID%2F%3F",
        )

    def test_interactive_preview_is_real_while_safe_summary_is_redacted(self) -> None:
        step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record=phrase_rollback(),
        )
        interactive = step.interactive_preview()
        safe = step.safe_summary()
        self.assertEqual(
            interactive["existing_record"]["phrase"], "OFFLINE PREVIOUS PHRASE"
        )
        self.assertEqual(
            interactive["payload"]["phrase"]["origin"], "OFFLINE_FIXTURE_ONLY"
        )
        self.assertIn("INVALID_PHRASE_ID", interactive["path"])
        safe_json = json.dumps(safe, ensure_ascii=False)
        self.assertNotIn("OFFLINE PREVIOUS PHRASE", safe_json)
        self.assertNotIn("OFFLINE_FIXTURE_ONLY", safe_json)
        self.assertNotIn("INVALID_PHRASE_ID", safe_json)
        self.assertNotIn(FAKE_TOKEN, json.dumps(interactive, ensure_ascii=False))
        with self.assertRaisesRegex(harness.SafetyError, "missing required fields"):
            harness.prepare_plan_step(
                self.plan,
                3,
                phrase_record_id="INVALID_PHRASE_ID",
                existing_record={"id": "INVALID_PHRASE_ID"},
            )
        with self.assertRaisesRegex(harness.SafetyError, "does not match"):
            harness.prepare_plan_step(
                self.plan,
                3,
                phrase_record_id="INVALID_PHRASE_ID",
                existing_record=phrase_rollback("DIFFERENT_PHRASE_ID"),
            )

    def test_interpretation_create_update_and_ambiguity_contract(self) -> None:
        created = harness.choose_interpretation_operation(
            "INVALID_VOCABULARY_ID", "OFFLINE NEW", []
        )
        self.assertEqual(created.operation["action"], "create_interpretation")
        self.assertIsNone(created.interactive_preview()["existing_record"])

        updated = harness.choose_interpretation_operation(
            "INVALID_VOCABULARY_ID",
            "OFFLINE NEW",
            [
                harness.ExistingInterpretation(
                    "INVALID_RECORD_ID",
                    "OFFLINE OLD",
                    True,
                    tuple(TAGS),
                    "PUBLISHED",
                )
            ],
        )
        self.assertEqual(updated.operation["action"], "update_interpretation")
        self.assertEqual(
            updated.operation["path"],
            "/open/api/v1/interpretations/INVALID_RECORD_ID",
        )
        self.assertEqual(set(updated.operation["payload"]), {"interpretation"})
        self.assertEqual(
            set(updated.operation["payload"]["interpretation"]),
            {"interpretation", "tags", "status"},
        )
        interactive = updated.interactive_preview()
        self.assertEqual(interactive["existing_record"]["interpretation"], "OFFLINE OLD")
        self.assertEqual(
            interactive["proposed_payload"]["interpretation"]["interpretation"],
            "OFFLINE NEW",
        )
        prepared_update = harness.prepare_operation(
            updated.operation,
            "INVALID_VOCABULARY_ID",
            existing_record=updated.existing_record,
        )
        self.assertEqual(
            prepared_update.interactive_preview()["existing_record"],
            interactive["existing_record"],
        )
        safe_json = json.dumps(updated.safe_summary(), ensure_ascii=False)
        self.assertNotIn("OFFLINE OLD", safe_json)
        self.assertNotIn("OFFLINE NEW", safe_json)

        ambiguous_sets = [
            [harness.ExistingInterpretation(None, "OFFLINE OLD", True)],
            [harness.ExistingInterpretation("INVALID_ID", "OFFLINE OLD", False)],
            [
                harness.ExistingInterpretation("INVALID_ID_1", "OLD 1", True),
                harness.ExistingInterpretation("INVALID_ID_2", "OLD 2", True),
            ],
        ]
        for existing in ambiguous_sets:
            with self.subTest(existing=existing), self.assertRaises(
                harness.SafetyError
            ):
                harness.choose_interpretation_operation(
                    "INVALID_VOCABULARY_ID", "OFFLINE NEW", existing
                )

    def test_interpretation_readback_uses_official_shape_without_voc_id(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        record = interpretation_record(step)
        self.assertNotIn("voc_id", record)
        root, state_store = self.make_store("issue9-interpretation-")
        test_credential = credential()
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretations": []}),
                harness.HttpResponse(
                    200, {"interpretation": {"id": "INVALID_INTERPRETATION_ID"}}
                ),
                harness.HttpResponse(200, {"interpretations": [record]}),
            ]
        )
        result = harness.SingleStepExecutor(transport).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        self.assertEqual(
            set(result.verified_fields), {"interpretation", "tags", "status"}
        )
        self.assertEqual(state_store.read(1)["status"], "verified")
        self.assertTrue((root / "issue9-step-1.json").is_file())

    def test_create_interpretation_preflight_requires_zero_existing_records(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        existing = interpretation_record(step, "INVALID_EXISTING_INTERPRETATION_ID")
        root, state_store = self.make_store("issue9-create-interpretation-existing-")
        transport = FakeTransport(
            [harness.HttpResponse(200, {"interpretations": [existing]})]
        )
        test_credential = credential()
        with self.assertRaisesRegex(harness.VerificationError, "update flow"):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual([request.method for request in transport.requests], ["GET"])
        self.assertEqual(list(root.iterdir()), [])

    def test_create_interpretation_readback_requires_exactly_one_total_record(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        first = interpretation_record(step, "INVALID_NEW_INTERPRETATION_1")
        second = interpretation_record(step, "INVALID_NEW_INTERPRETATION_2")
        _, state_store = self.make_store("issue9-interpretation-create-cardinality-")
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretations": []}),
                harness.HttpResponse(
                    200,
                    {"interpretation": {"id": "INVALID_NEW_INTERPRETATION_1"}},
                ),
                harness.HttpResponse(200, {"interpretations": [first, second]}),
            ]
        )
        test_credential = credential()
        with self.assertRaisesRegex(
            harness.VerificationError, "multiple user interpretations"
        ):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(
            [request.method for request in transport.requests], ["GET", "POST", "GET"]
        )
        self.assertEqual(
            state_store.read(1)["status"], "write-succeeded-readback-unverified"
        )

    def test_update_interpretation_preflight_blocks_multiple_total_records(self) -> None:
        step, snapshot = self.make_interpretation_update_step()
        other = dict(snapshot)
        other["id"] = "INVALID_OTHER_INTERPRETATION_ID"
        root, state_store = self.make_store("issue9-interpretation-update-preflight-")
        transport = FakeTransport(
            [harness.HttpResponse(200, {"interpretations": [snapshot, other]})]
        )
        test_credential = credential()
        with self.assertRaisesRegex(
            harness.VerificationError, "multiple user interpretations"
        ):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual([request.method for request in transport.requests], ["GET"])
        self.assertEqual(list(root.iterdir()), [])

    def test_update_interpretation_readback_remains_unique(self) -> None:
        step, snapshot = self.make_interpretation_update_step()
        updated = interpretation_record(step, "INVALID_INTERPRETATION_UPDATE_ID")
        second = dict(updated)
        second["id"] = "INVALID_CONCURRENT_INTERPRETATION_ID"
        _, state_store = self.make_store("issue9-interpretation-update-readback-")
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretations": [snapshot]}),
                harness.HttpResponse(
                    200,
                    {"interpretation": {"id": "INVALID_INTERPRETATION_UPDATE_ID"}},
                ),
                harness.HttpResponse(200, {"interpretations": [updated, second]}),
            ]
        )
        test_credential = credential()
        with self.assertRaisesRegex(
            harness.VerificationError, "multiple user interpretations"
        ):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(
            state_store.read(step.sequence)["status"],
            "write-succeeded-readback-unverified",
        )

    def test_update_interpretation_single_target_still_verifies(self) -> None:
        step, snapshot = self.make_interpretation_update_step()
        updated = interpretation_record(step, "INVALID_INTERPRETATION_UPDATE_ID")
        _, state_store = self.make_store("issue9-interpretation-update-single-")
        test_credential = credential()
        result = harness.SingleStepExecutor(
            FakeTransport(responses_for_step(step, updated, preflight_record=snapshot))
        ).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        self.assertEqual(result.payload_readback_status, "verified")
        self.assertEqual(state_store.read(step.sequence)["status"], "verified")

    def test_create_phrase_preflight_blocks_exact_duplicate(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        duplicate = phrase_record(
            step,
            [{"start": 4, "end": 14}],
            "INVALID_EXISTING_DUPLICATE_PHRASE_ID",
        )
        root, state_store = self.make_store("issue9-create-phrase-duplicate-")
        transport = FakeTransport(
            [harness.HttpResponse(200, {"phrases": [duplicate]})]
        )
        test_credential = credential()
        with self.assertRaisesRegex(harness.VerificationError, "exact duplicate"):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual([request.method for request in transport.requests], ["GET"])
        self.assertEqual(list(root.iterdir()), [])

    def test_create_baseline_requires_unique_safe_complete_record_identity(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        valid = phrase_rollback("INVALID_BASELINE_PHRASE_ID")
        cases = {
            "missing-id": [{key: value for key, value in valid.items() if key != "id"}],
            "duplicate-id": [valid, dict(valid)],
            "unsafe-id": [{**valid, "id": "unsafe/id"}],
        }
        test_credential = credential()
        for name, records in cases.items():
            with self.subTest(name=name):
                root, state_store = self.make_store(f"issue9-baseline-{name}-")
                transport = FakeTransport(
                    [harness.HttpResponse(200, {"phrases": records})]
                )
                with self.assertRaises(harness.VerificationError):
                    harness.SingleStepExecutor(transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual([request.method for request in transport.requests], ["GET"])
                self.assertEqual(list(root.iterdir()), [])

    def test_create_preflight_failure_or_malformed_response_never_posts(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        cases: list[tuple[str, harness.HttpResponse | Exception]] = [
            ("transport", harness.TransportError("offline fake preflight failure")),
            ("non-2xx", harness.HttpResponse(503, {"error": "offline"})),
            ("missing-list", harness.HttpResponse(200, {})),
            ("object-not-list", harness.HttpResponse(200, {"phrases": {}})),
            ("invalid-list-item", harness.HttpResponse(200, {"phrases": ["bad"]})),
        ]
        test_credential = credential()
        for name, response in cases:
            with self.subTest(name=name):
                root, state_store = self.make_store(f"issue9-create-preflight-{name}-")
                transport = FakeTransport([response])
                with self.assertRaises(harness.VerificationError):
                    harness.SingleStepExecutor(transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual([request.method for request in transport.requests], ["GET"])
                self.assertEqual(list(root.iterdir()), [])

    def test_private_journal_contains_only_filtered_create_baseline(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        baseline = phrase_rollback("INVALID_OLDER_PHRASE_ID")
        baseline["highlight"] = [{"start": 1, "end": 2}]
        baseline["raw_server_noise"] = {
            "Authorization": FAKE_TOKEN,
            "unreviewed": "OFFLINE RAW RESPONSE ONLY",
        }
        created = phrase_record(
            step,
            [{"start": 4, "end": 14}],
            "INVALID_NEW_PHRASE_ID",
        )
        _, state_store = self.make_store("issue9-create-baseline-journal-")
        test_credential = credential()
        result = harness.SingleStepExecutor(
            FakeTransport(
                responses_for_step(
                    step,
                    created,
                    create_baseline_records=[baseline],
                )
            )
        ).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        self.assertEqual(result.payload_readback_status, "verified")
        state = state_store.read(2)
        self.assertEqual(
            set(state["create_baseline"]["records"][0]),
            {"id", "phrase", "interpretation", "tags", "origin", "status"},
        )
        self.assertEqual(
            state["create_baseline"]["record_ids"], ["INVALID_OLDER_PHRASE_ID"]
        )
        serialized = json.dumps(state, ensure_ascii=False)
        self.assertNotIn("raw_server_noise", serialized)
        self.assertNotIn("OFFLINE RAW RESPONSE ONLY", serialized)
        self.assertNotIn(FAKE_TOKEN, serialized)
        self.assertNotIn("Authorization", serialized)
        self.assertNotIn("Cookie", serialized)
        self.assertNotIn(ACCOUNT_LABEL, serialized)

    def test_every_write_requires_state_store_and_exact_confirmation(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        test_credential = credential()
        transport = FakeTransport()
        with self.assertRaisesRegex(harness.SafetyError, "every live write"):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=None,
            )
        self.assertEqual(transport.requests, [])

        root, state_store = self.make_store("issue9-confirmation-")
        with self.assertRaises(harness.ConfirmationError):
            harness.SingleStepExecutor(transport).execute(
                step,
                "yes",
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(transport.requests, [])
        self.assertEqual(list(root.iterdir()), [])
        state_store.begin(
            step,
            test_credential.fingerprint,
            create_baseline=harness.CreateBaseline("interpretations", (), ()),
        )
        with self.assertRaisesRegex(harness.SafetyError, "do not replay"):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(transport.requests, [])

    def test_confirmation_binds_deeply_immutable_final_payload(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        source_entity = self.plan["operations"][0]["payload"]["interpretation"]
        source_entity["interpretation"] = "OFFLINE MUTATED SOURCE"
        self.assertNotEqual(
            step.payload["interpretation"]["interpretation"],
            source_entity["interpretation"],
        )
        with self.assertRaises(TypeError):
            step.payload["interpretation"]["interpretation"] = "BLOCKED"

        rollback_source = phrase_rollback()
        update_step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record=rollback_source,
        )
        rollback_source["phrase"] = "OFFLINE MUTATED ROLLBACK SOURCE"
        self.assertEqual(
            update_step.rollback_snapshot["phrase"], "OFFLINE PREVIOUS PHRASE"
        )
        with self.assertRaises(TypeError):
            update_step.rollback_snapshot["phrase"] = "BLOCKED"

        tampered_payload = step.interactive_preview()["payload"]
        tampered_payload["interpretation"]["interpretation"] = (
            "OFFLINE VALID BUT UNCONFIRMED REPLACEMENT"
        )
        forged = replace(step, payload=tampered_payload)
        root, state_store = self.make_store("issue9-tampered-confirmation-")
        transport = FakeTransport()
        test_credential = credential()
        with self.assertRaises(harness.ConfirmationError):
            harness.SingleStepExecutor(transport).execute(
                forged,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(transport.requests, [])
        self.assertEqual(list(root.iterdir()), [])

    def test_executor_revalidates_all_send_values_for_forged_steps(self) -> None:
        create_interpretation = harness.prepare_plan_step(self.plan, 1)
        create_phrase = harness.prepare_plan_step(self.plan, 2)
        interpretation_decision = harness.choose_interpretation_operation(
            self.plan["vocabulary"]["id"],
            "OFFLINE NEW INTERPRETATION",
            [
                harness.ExistingInterpretation(
                    "INVALID_INTERPRETATION_ID",
                    "OFFLINE OLD INTERPRETATION",
                    True,
                    tuple(TAGS),
                    "PUBLISHED",
                )
            ],
        )
        update_interpretation = harness.prepare_operation(
            interpretation_decision.operation,
            self.plan["vocabulary"]["id"],
            existing_record=interpretation_decision.existing_record,
        )
        update_phrase = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record=phrase_rollback(),
        )

        cases: list[tuple[str, harness.PreparedStep, dict[str, object]]] = []
        for name, field, value in (
            ("interpretation-wrong-voc", "voc_id", "INVALID_OTHER_VOCABULARY"),
            ("interpretation-blank", "interpretation", "  "),
            ("interpretation-tags", "tags", ["MBA", "BEC", "MBA"]),
            ("interpretation-status", "status", "DELETED"),
        ):
            payload = create_interpretation.interactive_preview()["payload"]
            payload["interpretation"][field] = value
            cases.append((name, create_interpretation, payload))
        for name, field, value in (
            ("phrase-wrong-voc", "voc_id", "INVALID_OTHER_VOCABULARY"),
            ("phrase-blank", "phrase", ""),
            ("translation-blank", "interpretation", "\t"),
            ("origin-blank", "origin", " "),
            ("phrase-tags", "tags", ["GMAT", "BEC", "MBA"]),
        ):
            payload = create_phrase.interactive_preview()["payload"]
            payload["phrase"][field] = value
            cases.append((name, create_phrase, payload))
        update_interpretation_payload = update_interpretation.interactive_preview()[
            "payload"
        ]
        update_interpretation_payload["id"] = "INVALID_INTERPRETATION_ID"
        cases.append(
            ("interpretation-update-id", update_interpretation, update_interpretation_payload)
        )
        update_phrase_payload = update_phrase.interactive_preview()["payload"]
        update_phrase_payload["phrase"]["voc_id"] = self.plan["vocabulary"]["id"]
        cases.append(("phrase-update-voc", update_phrase, update_phrase_payload))

        for name, valid_step, payload in cases:
            with self.subTest(name=name):
                forged = replace(valid_step, payload=payload)
                root, state_store = self.make_store(f"issue9-forged-{name}-")
                transport = FakeTransport()
                test_credential = credential()
                with self.assertRaises(harness.SafetyError):
                    harness.SingleStepExecutor(transport).execute(
                        forged,
                        forged.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(transport.requests, [])
                self.assertEqual(list(root.iterdir()), [])

    def test_journal_is_persisted_before_post_and_before_get(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        _, state_store = self.make_store("issue9-order-")
        test_credential = credential()

        def inspect_journal(_request: harness.HttpRequest, index: int) -> None:
            destination = state_store.root / "issue9-step-1.json"
            if index == 0:
                self.assertFalse(destination.exists())
            elif index == 1:
                self.assertEqual(state_store.read(1)["status"], "prepared-not-sent")
            else:
                self.assertEqual(
                    state_store.read(1)["status"],
                    "write-succeeded-readback-unverified",
                )

        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretations": []}),
                harness.HttpResponse(
                    200, {"interpretation": {"id": "INVALID_INTERPRETATION_ID"}}
                ),
                harness.HttpResponse(
                    200, {"interpretations": [interpretation_record(step)]}
                ),
            ],
            hook=inspect_journal,
        )
        harness.SingleStepExecutor(transport).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        self.assertEqual(state_store.read(1)["status"], "verified")

    def test_update_preflight_blocks_wrong_word_id_and_stale_old_content(self) -> None:
        snapshot = phrase_rollback("INVALID_TARGET_PHRASE_ID")
        step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_TARGET_PHRASE_ID",
            existing_record=snapshot,
        )
        wrong_word_record = dict(snapshot)
        wrong_word_record["id"] = "INVALID_OTHER_WORD_PHRASE_ID"
        stale_record = dict(snapshot)
        stale_record["phrase"] = "OFFLINE CHANGED ON ANOTHER DEVICE"

        for name, record in (
            ("wrong-word", wrong_word_record),
            ("stale-content", stale_record),
        ):
            with self.subTest(name=name):
                root, state_store = self.make_store(f"issue9-preflight-{name}-")
                transport = FakeTransport(
                    [harness.HttpResponse(200, {"phrases": [record]})]
                )
                test_credential = credential()
                with self.assertRaisesRegex(
                    harness.VerificationError, "stale or identity mismatch"
                ):
                    harness.SingleStepExecutor(transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(len(transport.requests), 1)
                self.assertEqual(transport.requests[0].method, "GET")
                self.assertEqual(
                    transport.requests[0].path,
                    "/open/api/v1/phrases?voc_id=INVALID_VOCABULARY_ID_ISSUE_2",
                )
                self.assertEqual(
                    [request for request in transport.requests if request.method == "POST"],
                    [],
                )
                self.assertEqual(list(root.iterdir()), [])

    def test_successful_update_preflight_precedes_journal_and_single_post(self) -> None:
        snapshot = phrase_rollback()
        step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record=snapshot,
        )
        readback = phrase_record(step, [[8, 19]])
        root, state_store = self.make_store("issue9-preflight-order-")

        def inspect_order(request: harness.HttpRequest, index: int) -> None:
            destination = root / "issue9-step-3.json"
            if index == 0:
                self.assertEqual(request.method, "GET")
                self.assertFalse(destination.exists())
            elif index == 1:
                self.assertEqual(request.method, "POST")
                self.assertEqual(state_store.read(3)["status"], "prepared-not-sent")
            else:
                self.assertEqual(request.method, "GET")
                self.assertEqual(
                    state_store.read(3)["status"],
                    "write-succeeded-readback-unverified",
                )

        transport = FakeTransport(
            responses_for_step(step, readback, preflight_record=snapshot),
            hook=inspect_order,
        )
        test_credential = credential()
        harness.SingleStepExecutor(transport).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        self.assertEqual([request.method for request in transport.requests], ["GET", "POST", "GET"])
        self.assertEqual(state_store.read(3)["status"], "verified")

    def test_phrase_update_preflight_requires_published_target(self) -> None:
        snapshot = phrase_rollback()
        step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record=snapshot,
        )
        cases = {
            "deleted": {**snapshot, "status": "DELETED"},
            "missing": {
                key: value for key, value in snapshot.items() if key != "status"
            },
        }
        test_credential = credential()
        for name, preflight_record in cases.items():
            with self.subTest(name=name):
                root, state_store = self.make_store(
                    f"issue9-phrase-preflight-status-{name}-"
                )
                transport = FakeTransport(
                    [harness.HttpResponse(200, {"phrases": [preflight_record]})]
                )
                with self.assertRaisesRegex(
                    harness.VerificationError, "stale or identity mismatch"
                ):
                    harness.SingleStepExecutor(transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(
                    [request.method for request in transport.requests], ["GET"]
                )
                self.assertEqual(list(root.iterdir()), [])

    def test_update_response_cannot_switch_the_preflighted_record_id(self) -> None:
        snapshot = phrase_rollback()
        step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record=snapshot,
        )
        _, state_store = self.make_store("issue9-response-id-switch-")
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"phrases": [snapshot]}),
                harness.HttpResponse(
                    200, {"phrase": {"id": "INVALID_OTHER_PHRASE_ID"}}
                ),
            ]
        )
        test_credential = credential()
        with self.assertRaisesRegex(harness.VerificationError, "changed the update target"):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual([request.method for request in transport.requests], ["GET", "POST"])
        state = state_store.read(3)
        self.assertEqual(state["status"], "write-succeeded-readback-unverified")
        self.assertIsNone(state["continuation_record_id"])

    def test_timeout_and_non_2xx_post_are_unknown_and_never_retried(self) -> None:
        cases: list[tuple[str, harness.HttpResponse | Exception, int | None]] = [
            ("timeout", harness.TransportError("fake timeout"), None),
            ("non-2xx", harness.HttpResponse(503, {"error": "fake"}), 503),
        ]
        for name, response, expected_status in cases:
            with self.subTest(name=name):
                step = harness.prepare_plan_step(self.plan, 1)
                _, state_store = self.make_store(f"issue9-{name}-")
                test_credential = credential()
                transport = FakeTransport(
                    [harness.HttpResponse(200, {"interpretations": []}), response]
                )
                with self.assertRaises(harness.UnknownOutcomeError):
                    harness.SingleStepExecutor(transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                state = state_store.read(1)
                self.assertEqual(state["status"], "write-attempted-outcome-unknown")
                self.assertEqual(state.get("write_status"), expected_status)
                self.assertEqual(state["request"]["method"], "POST")
                self.assertEqual(
                    state["request"]["path"],
                    "/open/api/v1/interpretations",
                )
                self.assertEqual(
                    state["request"]["payload"],
                    step.interactive_preview()["payload"],
                )
                serialized = json.dumps(state, ensure_ascii=False)
                self.assertIn("明显虚假的离线示例释义", serialized)
                self.assertEqual(
                    state["credential_fingerprint"], test_credential.fingerprint
                )
                self.assertNotIn(FAKE_TOKEN, serialized)
                self.assertNotIn("Authorization", serialized)
                self.assertNotIn("Cookie", serialized)
                self.assertNotIn("response", state)
                self.assertEqual(len(transport.requests), 2)
                self.assertEqual(
                    [request.method for request in transport.requests], ["GET", "POST"]
                )
                replay_transport = FakeTransport()
                with self.assertRaisesRegex(harness.SafetyError, "do not replay"):
                    harness.SingleStepExecutor(replay_transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(replay_transport.requests, [])

    def test_readback_failures_remain_durable_and_block_replay(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        mismatched = interpretation_record(step)
        mismatched["status"] = "DRAFT"
        cases: list[tuple[str, harness.HttpResponse | Exception]] = [
            ("timeout", harness.TransportError("fake read timeout")),
            ("non-2xx", harness.HttpResponse(503, {"error": "fake"})),
            ("ambiguous", harness.HttpResponse(200, {"interpretations": []})),
            ("mismatch", harness.HttpResponse(200, {"interpretations": [mismatched]})),
        ]
        for name, read_response in cases:
            with self.subTest(name=name):
                _, state_store = self.make_store(f"issue9-read-{name}-")
                test_credential = credential()
                transport = FakeTransport(
                    [
                        harness.HttpResponse(200, {"interpretations": []}),
                        harness.HttpResponse(
                            200,
                            {"interpretation": {"id": "INVALID_INTERPRETATION_ID"}},
                        ),
                        read_response,
                    ]
                )
                with self.assertRaises(harness.VerificationError):
                    harness.SingleStepExecutor(transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(
                    state_store.read(1)["status"],
                    "write-succeeded-readback-unverified",
                )
                replay_transport = FakeTransport()
                with self.assertRaisesRegex(harness.SafetyError, "do not replay"):
                    harness.SingleStepExecutor(replay_transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(replay_transport.requests, [])

    def test_verified_state_also_blocks_replay(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        _, state_store = self.make_store("issue9-verified-replay-")
        test_credential = credential()
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretations": []}),
                harness.HttpResponse(
                    200, {"interpretation": {"id": "INVALID_INTERPRETATION_ID"}}
                ),
                harness.HttpResponse(
                    200, {"interpretations": [interpretation_record(step)]}
                ),
            ]
        )
        harness.SingleStepExecutor(transport).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        replay_transport = FakeTransport()
        with self.assertRaisesRegex(harness.SafetyError, "do not replay"):
            harness.SingleStepExecutor(replay_transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(replay_transport.requests, [])

    def test_phrase_highlight_is_observed_for_exact_inflected_and_multiple(self) -> None:
        cases = [
            (2, [{"start": 4, "end": 14}], "object-range-array", None),
            (3, [[8, 19]], "integer-pair-array", phrase_rollback()),
            (
                4,
                [{"start": 4, "end": 14}, {"start": 31, "end": 41}],
                "object-range-array",
                phrase_rollback(),
            ),
        ]
        for sequence, ranges, raw_shape, existing in cases:
            with self.subTest(sequence=sequence):
                kwargs: dict[str, object] = {}
                if existing is not None:
                    kwargs = {
                        "phrase_record_id": "INVALID_PHRASE_ID",
                        "existing_record": existing,
                    }
                step = harness.prepare_plan_step(self.plan, sequence, **kwargs)
                official_record = phrase_record(step, ranges)
                self.assertNotIn("voc_id", official_record)
                _, state_store = self.make_store(f"issue9-highlight-{sequence}-")
                test_credential = credential()
                transport = FakeTransport(
                    responses_for_step(
                        step,
                        official_record,
                        preflight_record=existing,
                    )
                )
                result = harness.SingleStepExecutor(transport).execute(
                    step,
                    step.confirmation,
                    test_credential,
                    valid_gate(test_credential),
                    state_store=state_store,
                )
                self.assertEqual(
                    result.highlight_observation.as_dict()["normalized_ranges"],
                    [
                        {"start": item["start"], "end": item["end"]}
                        if isinstance(item, dict)
                        else {"start": item[0], "end": item[1]}
                        for item in ranges
                    ],
                )
                self.assertEqual(result.highlight_observation.raw_shape, raw_shape)
                self.assertEqual(
                    result.highlight_observation.outcome, "ranges-observed"
                )
                self.assertEqual(
                    result.highlight_observation.semantic_status,
                    "awaiting-owner-app-comparison",
                )
                self.assertEqual(result.payload_readback_status, "verified")
                self.assertEqual(result.publication_status, "PUBLISHED")
                self.assertIn("status", result.verified_fields)
                self.assertNotIn("status", step.payload["phrase"])
                persisted = state_store.read(sequence)
                self.assertEqual(persisted["status"], "verified")
                self.assertEqual(
                    persisted["result"]["payload_readback_status"], "verified"
                )
                self.assertEqual(
                    persisted["result"]["highlight_observation"]["raw_shape"],
                    raw_shape,
                )
                self.assertEqual(
                    persisted["verified_record_snapshot"]["status"], "PUBLISHED"
                )
                self.assertEqual(
                    persisted["result"]["publication_status"], "PUBLISHED"
                )

    def test_phrase_readback_requires_published_status(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        cases: dict[str, str | None] = {
            "deleted": "DELETED",
            "unknown": "OFFLINE_UNKNOWN_STATUS",
            "missing": None,
        }
        test_credential = credential()
        for name, status_value in cases.items():
            with self.subTest(name=name):
                record = phrase_record(
                    step,
                    [{"start": 4, "end": 14}],
                    f"INVALID_PHRASE_STATUS_{name.upper()}",
                )
                if status_value is None:
                    record.pop("status")
                else:
                    record["status"] = status_value
                _, state_store = self.make_store(f"issue9-phrase-status-{name}-")
                transport = FakeTransport(responses_for_step(step, record))
                with self.assertRaisesRegex(
                    harness.VerificationError, "publication status"
                ):
                    harness.SingleStepExecutor(transport).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(
                    state_store.read(2)["status"],
                    "write-succeeded-readback-unverified",
                )
                self.assertEqual(
                    [request.method for request in transport.requests],
                    ["GET", "POST", "GET"],
                )

    def test_highlight_negative_invalid_and_unknown_do_not_unverify_payload(self) -> None:
        observations = [
            (None, "negative", "missing"),
            ([], "negative", "empty-array"),
            ([{"start": 4, "end": "14"}], "invalid", "object-range-array"),
            ([{"start": 14, "end": 4}], "invalid", "object-range-array"),
            ([{"start": 4, "end": 500}], "invalid", "object-range-array"),
            (["unrecognized"], "unknown", "unrecognized-array"),
        ]
        for index, (highlight, outcome, raw_shape) in enumerate(observations):
            with self.subTest(highlight=highlight, outcome=outcome):
                step = harness.prepare_plan_step(self.plan, 2)
                record = phrase_record(step, [{"start": 4, "end": 14}])
                if highlight is None:
                    record.pop("highlight")
                else:
                    record["highlight"] = highlight
                _, state_store = self.make_store(f"issue9-bad-highlight-{index}-")
                test_credential = credential()
                transport = FakeTransport(
                    responses_for_step(step, record)
                )
                result = harness.SingleStepExecutor(transport).execute(
                    step,
                    step.confirmation,
                    test_credential,
                    valid_gate(test_credential),
                    state_store=state_store,
                )
                self.assertEqual(result.payload_readback_status, "verified")
                self.assertEqual(result.highlight_observation.outcome, outcome)
                self.assertEqual(result.highlight_observation.raw_shape, raw_shape)
                self.assertNotEqual(
                    result.highlight_observation.semantic_status,
                    "automatic-highlight-verified",
                )
                state = state_store.read(2)
                self.assertEqual(state["status"], "verified")
                self.assertEqual(
                    state["result"]["highlight_observation"]["outcome"], outcome
                )

    def test_small_unknown_highlight_is_private_bounded_evidence_only(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        private_marker = "OFFLINE_PRIVATE_HIGHLIGHT_SENTINEL"
        unknown_highlight = {
            "unexpected_ranges": [{"from": 4, "to": 14}],
            "fixture_marker": private_marker,
        }
        record = phrase_record(
            step,
            unknown_highlight,
            "INVALID_PRIVATE_HIGHLIGHT_PHRASE_ID",
        )
        _, state_store = self.make_store("issue9-private-highlight-")
        test_credential = credential()
        result = harness.SingleStepExecutor(
            FakeTransport(responses_for_step(step, record))
        ).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        self.assertEqual(result.payload_readback_status, "verified")
        self.assertEqual(result.highlight_observation.outcome, "unknown")
        safe = json.dumps(result.safe_summary(), ensure_ascii=False)
        self.assertNotIn(private_marker, safe)
        self.assertNotIn(private_marker, repr(result))
        private_result = state_store.read(2)["result"]
        evidence = private_result["bounded_raw_highlight"]
        self.assertEqual(evidence["status"], "captured")
        self.assertEqual(evidence["value"], unknown_highlight)
        self.assertEqual(private_result["payload_readback_status"], "verified")

    def test_unsafe_or_oversized_highlight_is_rejected_without_unverifying_payload(
        self,
    ) -> None:
        deep_value: object = "OFFLINE_DEEPEST_VALUE"
        for _ in range(harness.PRIVATE_HIGHLIGHT_MAX_DEPTH + 2):
            deep_value = [deep_value]
        cases = {
            "oversized": ["X" * (harness.PRIVATE_HIGHLIGHT_MAX_BYTES + 200)],
            "too-deep": deep_value,
            "sensitive-key": {"Authorization": "OFFLINE_PRIVATE_HEADER"},
            "credential-material": [FAKE_TOKEN],
        }
        test_credential = credential()
        for index, (name, raw_highlight) in enumerate(cases.items()):
            with self.subTest(name=name):
                step = harness.prepare_plan_step(self.plan, 2)
                record = phrase_record(
                    step,
                    raw_highlight,
                    f"INVALID_REJECTED_HIGHLIGHT_{index}",
                )
                _, state_store = self.make_store(f"issue9-highlight-reject-{name}-")
                result = harness.SingleStepExecutor(
                    FakeTransport(responses_for_step(step, record))
                ).execute(
                    step,
                    step.confirmation,
                    test_credential,
                    valid_gate(test_credential),
                    state_store=state_store,
                )
                self.assertEqual(result.payload_readback_status, "verified")
                self.assertEqual(state_store.read(2)["status"], "verified")
                evidence = state_store.read(2)["result"]["bounded_raw_highlight"]
                self.assertEqual(evidence["status"], "evidence-truncated/rejected")
                self.assertNotIn("value", evidence)
                serialized = json.dumps(state_store.read(2), ensure_ascii=False)
                safe_serialized = json.dumps(result.safe_summary(), ensure_ascii=False)
                self.assertNotIn("OFFLINE_PRIVATE_HEADER", serialized)
                self.assertNotIn("OFFLINE_DEEPEST_VALUE", serialized)
                self.assertNotIn(FAKE_TOKEN, serialized)
                self.assertNotIn("X" * 100, serialized)
                self.assertNotIn("OFFLINE_PRIVATE_HEADER", safe_serialized)
                self.assertNotIn("OFFLINE_DEEPEST_VALUE", safe_serialized)
                self.assertNotIn(FAKE_TOKEN, safe_serialized)

    def test_phrase_continuation_uses_private_server_id_across_three_steps(self) -> None:
        test_credential = credential()
        exact_step = harness.prepare_plan_step(self.plan, 2)
        server_record_id = "INVALID_SERVER_ASSIGNED_PHRASE_ID"
        exact_record = phrase_record(
            exact_step,
            [{"start": 4, "end": 14}],
            server_record_id,
        )
        _, exact_store = self.make_store("issue9-chain-exact-")
        exact_result = harness.SingleStepExecutor(
            FakeTransport(responses_for_step(exact_step, exact_record))
        ).execute(
            exact_step,
            exact_step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=exact_store,
        )
        self.assertEqual(
            exact_result.interactive_continuation()["record_id"], server_record_id
        )
        self.assertNotIn(server_record_id, json.dumps(exact_result.safe_summary()))
        self.assertNotIn(server_record_id, repr(exact_result))
        self.assertEqual(
            exact_store.read(2)["continuation_record_id"], server_record_id
        )

        inflected_step = harness.prepare_phrase_continuation_step(
            self.plan,
            3,
            previous_state_store=exact_store,
            previous_sequence=2,
            credential_fingerprint=test_credential.fingerprint,
        )
        self.assertEqual(
            inflected_step.path,
            f"/open/api/v1/phrases/{server_record_id}",
        )
        self.assertEqual(
            inflected_step.interactive_preview()["existing_record"],
            exact_store.read(2)["verified_record_snapshot"],
        )
        inflected_record = phrase_record(
            inflected_step,
            [[8, 19]],
            server_record_id,
        )
        _, inflected_store = self.make_store("issue9-chain-inflected-")
        harness.SingleStepExecutor(
            FakeTransport(
                responses_for_step(
                    inflected_step,
                    inflected_record,
                    preflight_record=exact_store.read(2)[
                        "verified_record_snapshot"
                    ],
                )
            )
        ).execute(
            inflected_step,
            inflected_step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=inflected_store,
        )

        multiple_step = harness.prepare_phrase_continuation_step(
            self.plan,
            4,
            previous_state_store=inflected_store,
            previous_sequence=3,
            credential_fingerprint=test_credential.fingerprint,
        )
        self.assertEqual(
            multiple_step.path,
            f"/open/api/v1/phrases/{server_record_id}",
        )
        self.assertEqual(
            multiple_step.interactive_preview()["existing_record"],
            inflected_store.read(3)["verified_record_snapshot"],
        )
        with self.assertRaisesRegex(harness.SafetyError, "fingerprint changed"):
            harness.prepare_phrase_continuation_step(
                self.plan,
                4,
                previous_state_store=inflected_store,
                previous_sequence=3,
                credential_fingerprint="0" * 16,
            )

    def test_readback_recovers_missing_write_response_id_only_when_unique(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        test_credential = credential()
        recovered_id = "INVALID_READBACK_ONLY_PHRASE_ID"
        recovered_record = phrase_record(
            step,
            [{"start": 4, "end": 14}],
            recovered_id,
        )
        _, recovered_store = self.make_store("issue9-readback-id-")
        result = harness.SingleStepExecutor(
            FakeTransport(
                [
                    harness.HttpResponse(200, {"phrases": []}),
                    harness.HttpResponse(200, {}),
                    harness.HttpResponse(200, {"phrases": [recovered_record]}),
                ]
            )
        ).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=recovered_store,
        )
        self.assertEqual(result.continuation_record_id, recovered_id)
        self.assertEqual(
            recovered_store.read(2)["continuation_record_id"], recovered_id
        )

        second_record = dict(recovered_record)
        second_record["id"] = "INVALID_SECOND_CANDIDATE_PHRASE_ID"
        _, ambiguous_store = self.make_store("issue9-readback-id-ambiguous-")
        with self.assertRaises(harness.VerificationError):
            harness.SingleStepExecutor(
                FakeTransport(
                    [
                        harness.HttpResponse(200, {"phrases": []}),
                        harness.HttpResponse(200, {}),
                        harness.HttpResponse(
                            200, {"phrases": [recovered_record, second_record]}
                        ),
                    ]
                )
            ).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=ambiguous_store,
            )
        ambiguous_state = ambiguous_store.read(2)
        self.assertEqual(
            ambiguous_state["status"], "write-succeeded-readback-unverified"
        )
        self.assertIsNone(ambiguous_state["continuation_record_id"])

    def test_create_without_response_id_rejects_only_old_matching_record(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        record_id = "INVALID_PREEXISTING_PHRASE_ID"
        baseline = phrase_rollback(record_id)
        same_old_id_now_matching = phrase_record(
            step,
            [{"start": 4, "end": 14}],
            record_id,
        )
        _, state_store = self.make_store("issue9-no-id-old-only-")
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"phrases": [baseline]}),
                harness.HttpResponse(200, {}),
                harness.HttpResponse(200, {"phrases": [same_old_id_now_matching]}),
            ]
        )
        test_credential = credential()
        with self.assertRaisesRegex(
            harness.VerificationError, "exactly one new record"
        ):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(
            [request.method for request in transport.requests], ["GET", "POST", "GET"]
        )
        state = state_store.read(2)
        self.assertEqual(state["status"], "write-succeeded-readback-unverified")
        self.assertIsNone(state["continuation_record_id"])

    def test_create_response_id_that_existed_in_baseline_is_unresolved(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        baseline_id = "INVALID_EXISTING_PHRASE_ID"
        baseline = phrase_rollback(baseline_id)
        _, state_store = self.make_store("issue9-create-response-old-id-")
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"phrases": [baseline]}),
                harness.HttpResponse(200, {"phrase": {"id": baseline_id}}),
            ]
        )
        test_credential = credential()
        with self.assertRaisesRegex(
            harness.VerificationError, "already existed"
        ):
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(
            [request.method for request in transport.requests], ["GET", "POST"]
        )
        state = state_store.read(2)
        self.assertEqual(state["status"], "write-succeeded-readback-unverified")
        self.assertIsNone(state["continuation_record_id"])

    def test_create_without_response_id_requires_one_new_matching_record(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        baseline = phrase_rollback("INVALID_BASELINE_PHRASE_ID")
        new_record = phrase_record(
            step,
            [{"start": 4, "end": 14}],
            "INVALID_NEW_PHRASE_ID",
        )
        _, state_store = self.make_store("issue9-no-id-baseline-diff-")
        test_credential = credential()
        result = harness.SingleStepExecutor(
            FakeTransport(
                [
                    harness.HttpResponse(200, {"phrases": [baseline]}),
                    harness.HttpResponse(200, {}),
                    harness.HttpResponse(200, {"phrases": [baseline, new_record]}),
                ]
            )
        ).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        self.assertEqual(result.continuation_record_id, "INVALID_NEW_PHRASE_ID")
        self.assertEqual(state_store.read(2)["status"], "verified")

    def test_create_new_id_content_mismatch_remains_unresolved(self) -> None:
        step = harness.prepare_plan_step(self.plan, 2)
        mismatched = phrase_record(
            step,
            [{"start": 4, "end": 14}],
            "INVALID_NEW_MISMATCHED_PHRASE_ID",
        )
        mismatched["origin"] = "OFFLINE_DIFFERENT_ORIGIN"
        _, state_store = self.make_store("issue9-create-new-mismatch-")
        test_credential = credential()
        with self.assertRaisesRegex(harness.VerificationError, "origin"):
            harness.SingleStepExecutor(
                FakeTransport(
                    [
                        harness.HttpResponse(200, {"phrases": []}),
                        harness.HttpResponse(200, {}),
                        harness.HttpResponse(200, {"phrases": [mismatched]}),
                    ]
                )
            ).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertEqual(
            state_store.read(2)["status"], "write-succeeded-readback-unverified"
        )

    def test_readback_tags_are_exact_set_with_order_only_ignored(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        test_credential = credential()
        reordered = interpretation_record(step)
        reordered["tags"] = ["GMAT", "MBA", "BEC"]
        _, reordered_store = self.make_store("issue9-tags-reordered-")
        result = harness.SingleStepExecutor(
            FakeTransport(responses_for_step(step, reordered))
        ).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=reordered_store,
        )
        self.assertEqual(result.payload_readback_status, "verified")

        for name, tags in (
            ("missing", ["MBA", "BEC"]),
            ("extra", ["MBA", "BEC", "GMAT", "OTHER"]),
            ("duplicate", ["MBA", "BEC", "BEC"]),
        ):
            with self.subTest(name=name):
                record = interpretation_record(step)
                record["tags"] = tags
                _, state_store = self.make_store(f"issue9-tags-{name}-")
                with self.assertRaises(harness.VerificationError):
                    harness.SingleStepExecutor(
                        FakeTransport(responses_for_step(step, record))
                    ).execute(
                        step,
                        step.confirmation,
                        test_credential,
                        valid_gate(test_credential),
                        state_store=state_store,
                    )
                self.assertEqual(
                    state_store.read(1)["status"],
                    "write-succeeded-readback-unverified",
                )

    def test_private_rollback_snapshot_is_complete_restricted_and_ignored(self) -> None:
        old_record = phrase_rollback()
        step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record=old_record,
        )
        root, state_store = self.make_store("issue9-rollback-")
        test_credential = credential()
        transport = FakeTransport(
            responses_for_step(
                step,
                phrase_record(step, [{"start": 8, "end": 19}]),
                preflight_record=old_record,
            )
        )
        harness.SingleStepExecutor(transport).execute(
            step,
            step.confirmation,
            test_credential,
            valid_gate(test_credential),
            state_store=state_store,
        )
        destination = root / "issue9-step-3.json"
        state = state_store.read(3)
        self.assertEqual(state["rollback_snapshot"], old_record)
        self.assertEqual(state["request"]["method"], "POST")
        self.assertEqual(
            state["request"]["payload"], step.interactive_preview()["payload"]
        )
        self.assertEqual(state["continuation_record_id"], "INVALID_PHRASE_ID")
        content = destination.read_text(encoding="utf-8")
        self.assertIn("OFFLINE PREVIOUS PHRASE", content)
        self.assertNotIn(FAKE_TOKEN, content)
        self.assertNotIn("Authorization", content)
        self.assertNotIn("Cookie", content)
        self.assertNotIn(ACCOUNT_LABEL, content)
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        ignore_rules = {
            line.strip()
            for line in (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertIn("artifacts/private/", ignore_rules)

    def test_credential_never_appears_in_repr_summary_state_or_error(self) -> None:
        test_credential = credential()
        self.assertNotIn(FAKE_TOKEN, repr(test_credential))
        self.assertNotIn(FAKE_TOKEN, str(test_credential))
        step = harness.prepare_plan_step(self.plan, 1)
        self.assertNotIn(FAKE_TOKEN, json.dumps(step.safe_summary()))
        _, state_store = self.make_store("issue9-token-redaction-")
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretations": []}),
                harness.TransportError(FAKE_TOKEN),
            ]
        )
        with self.assertRaises(harness.UnknownOutcomeError) as context:
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=state_store,
            )
        self.assertNotIn(FAKE_TOKEN, str(context.exception))
        self.assertNotIn(FAKE_TOKEN, json.dumps(state_store.read(1)))

        collision_payload = step.interactive_preview()["payload"]
        collision_payload["interpretation"]["interpretation"] = FAKE_TOKEN
        forged = replace(step, payload=collision_payload)
        collision_root, collision_store = self.make_store(
            "issue9-token-collision-"
        )
        collision_transport = FakeTransport()
        with self.assertRaises(harness.SafetyError) as collision_context:
            harness.SingleStepExecutor(collision_transport).execute(
                forged,
                forged.confirmation,
                test_credential,
                valid_gate(test_credential),
                state_store=collision_store,
            )
        self.assertNotIn(FAKE_TOKEN, str(collision_context.exception))
        self.assertEqual(collision_transport.requests, [])
        self.assertEqual(list(collision_root.iterdir()), [])


class ReadOnlyProbeFixtures:
    """Shared read-only probe fixtures for the Issue #11 and #14 suites."""

    WORD = "sampleword"
    RETURNED_WORD = "SampleWord"
    VOCABULARY_ID = "INVALID_ISSUE11_VOCABULARY_ID"
    PRIVATE_INTERPRETATION = "PRIVATE OFFLINE INTERPRETATION BODY"
    PRIVATE_PHRASE = "PRIVATE OFFLINE PHRASE BODY"
    PRIVATE_VOCABULARY_KEY = "PRIVATE OFFLINE VOCABULARY KEY SENTINEL"

    def responses(
        self,
        *,
        vocabulary: dict[str, object] | None = None,
        interpretations: object | None = None,
        phrases: object | None = None,
    ) -> list[harness.HttpResponse]:
        voc = vocabulary or {
            "id": self.VOCABULARY_ID,
            "spelling": self.RETURNED_WORD,
            "private_unknown_field": "PRIVATE VOCABULARY BODY",
        }
        interpretation_records = (
            interpretations
            if interpretations is not None
            else [
                {
                    "id": "INVALID_ISSUE11_INTERPRETATION_ID",
                    "status": "PUBLISHED",
                    "interpretation": self.PRIVATE_INTERPRETATION,
                }
            ]
        )
        phrase_records = (
            phrases
            if phrases is not None
            else [
                {
                    "id": "INVALID_ISSUE11_PHRASE_ID",
                    "status": "PUBLISHED",
                    "phrase": self.PRIVATE_PHRASE,
                    "interpretation": "PRIVATE OFFLINE TRANSLATION BODY",
                    "highlight": [[0, 10]],
                }
            ]
        )
        return [
            harness.HttpResponse(200, {"voc": voc}),
            harness.HttpResponse(200, {"interpretations": interpretation_records}),
            harness.HttpResponse(200, {"phrases": phrase_records}),
        ]

    def probe_credential(self) -> harness.TestAccountCredential:
        return harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL)

    def interpretation_record(self, **overrides: object) -> dict[str, object]:
        record: dict[str, object] = {
            "id": "INVALID_ISSUE11_INTERPRETATION_ID",
            "status": "PUBLISHED",
            "interpretation": self.PRIVATE_INTERPRETATION,
        }
        record.update(overrides)
        return record

    def phrase_record(self, **overrides: object) -> dict[str, object]:
        record: dict[str, object] = {
            "id": "INVALID_ISSUE11_PHRASE_ID",
            "status": "PUBLISHED",
            "phrase": self.PRIVATE_PHRASE,
            "highlight": [[0, 10]],
        }
        record.update(overrides)
        return record

    def probe_gate(
        self,
        test_credential: harness.TestAccountCredential,
        *,
        word: str | None = None,
        confirmation: str | None = None,
    ) -> harness.ReadOnlyProbeGate:
        requested_word = word or self.WORD
        expected = harness._read_only_confirmation_for(
            ACCOUNT_LABEL,
            test_credential.fingerprint,
            requested_word,
        )
        return harness.ReadOnlyProbeGate(
            account_label=ACCOUNT_LABEL,
            credential_fingerprint=test_credential.fingerprint,
            requested_word=requested_word,
            confirmation=confirmation or expected,
        )

    def cli_args(self) -> list[str]:
        return [
            "read-only-probe",
            "--word",
            self.WORD,
            "--account-label",
            ACCOUNT_LABEL,
            "--allow-network",
        ]

class Issue11ReadOnlyProbeTests(ReadOnlyProbeFixtures, unittest.TestCase):
    def test_offline_modes_never_call_getpass_or_transport(self) -> None:
        def forbidden_prompt(_message: str) -> str:
            raise AssertionError("offline mode called a hidden prompt")

        def forbidden_transport() -> FakeTransport:
            raise AssertionError("offline mode created a transport")

        for argv in ([], ["--mode", "offline-plan"]):
            with self.subTest(argv=argv), mock.patch("sys.stdout", io.StringIO()):
                self.assertEqual(
                    harness.main(
                        argv,
                        token_prompt=forbidden_prompt,
                        confirmation_prompt=forbidden_prompt,
                        transport_factory=forbidden_transport,
                        stdin_isatty=lambda: False,
                    ),
                    0,
                )

    def test_cli_rejects_token_argv_config_and_piped_stdin_before_prompt(self) -> None:
        with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
            harness.parse_args([*self.cli_args(), "--token", FAKE_TOKEN])

        prompt_calls: list[str] = []
        factory_calls: list[str] = []

        def prompt(_message: str) -> str:
            prompt_calls.append("called")
            return FAKE_TOKEN

        def factory() -> FakeTransport:
            factory_calls.append("called")
            return FakeTransport(self.responses())

        piped_stdin = io.StringIO(FAKE_TOKEN)
        with mock.patch("sys.stdin", piped_stdin), mock.patch(
            "sys.stdout", io.StringIO()
        ):
            result = harness.main(
                self.cli_args(),
                token_prompt=prompt,
                confirmation_prompt=prompt,
                transport_factory=factory,
                stdin_isatty=lambda: False,
            )
        self.assertEqual(result, 3)
        self.assertEqual(prompt_calls, [])
        self.assertEqual(factory_calls, [])
        self.assertEqual(piped_stdin.tell(), 0)

        with mock.patch.object(
            Path,
            "open",
            side_effect=AssertionError("read-only mode opened a config file"),
        ), mock.patch("sys.stdout", io.StringIO()):
            result = harness.main(
                [
                    "--input",
                    "/private/tmp/forbidden-token.env",
                    *self.cli_args(),
                ],
                token_prompt=prompt,
                confirmation_prompt=prompt,
                transport_factory=factory,
                stdin_isatty=lambda: True,
            )
        self.assertEqual(result, 3)
        self.assertEqual(prompt_calls, [])
        self.assertEqual(factory_calls, [])

    def test_environment_token_is_ignored_and_hidden_prompt_is_injectable(self) -> None:
        environment_token = "ENVIRONMENT_TOKEN_MUST_NOT_BE_USED"
        captured_tokens: list[str] = []
        delegate = FakeTransport(self.responses())

        class CapturingTransport:
            def send(
                inner_self,
                request: harness.HttpRequest,
                test_credential: harness.TestAccountCredential,
            ) -> harness.HttpResponse:
                captured_tokens.append(test_credential.token)
                return delegate.send(request, test_credential)

        expected_confirmation = harness._read_only_confirmation_for(
            ACCOUNT_LABEL,
            self.probe_credential().fingerprint,
            self.WORD,
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ,
            {
                "MAIMEMO_TOKEN": environment_token,
                "MOMO_TOKEN": environment_token,
            },
        ), mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            result = harness.main(
                self.cli_args(),
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: expected_confirmation,
                transport_factory=CapturingTransport,
                stdin_isatty=lambda: True,
            )
        self.assertEqual(result, 0)
        self.assertEqual(captured_tokens, [FAKE_TOKEN] * 3)
        rendered = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn(FAKE_TOKEN, rendered)
        self.assertNotIn(environment_token, rendered)

    def test_exact_confirmation_is_required_before_transport_creation(self) -> None:
        factory_calls: list[str] = []

        def factory() -> FakeTransport:
            factory_calls.append("called")
            return FakeTransport(self.responses())

        with mock.patch("sys.stdout", io.StringIO()):
            result = harness.main(
                self.cli_args(),
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: "WRONG CONFIRMATION",
                transport_factory=factory,
                stdin_isatty=lambda: True,
            )
        self.assertEqual(result, 3)
        self.assertEqual(factory_calls, [])

        args_without_network = [item for item in self.cli_args() if item != "--allow-network"]
        token_calls: list[str] = []
        with mock.patch("sys.stdout", io.StringIO()):
            result = harness.main(
                args_without_network,
                token_prompt=lambda _message: token_calls.append("called") or FAKE_TOKEN,
                confirmation_prompt=lambda _message: "unused",
                transport_factory=factory,
                stdin_isatty=lambda: True,
            )
        self.assertEqual(result, 3)
        self.assertEqual(token_calls, [])
        self.assertEqual(factory_calls, [])

    def test_confirmation_binds_label_fingerprint_word_host_endpoints_and_terms(self) -> None:
        test_credential = self.probe_credential()
        baseline = harness._read_only_confirmation_for(
            ACCOUNT_LABEL, test_credential.fingerprint, self.WORD
        )
        variants = [
            harness._read_only_confirmation_for(
                "different-secondary-test", test_credential.fingerprint, self.WORD
            ),
            harness._read_only_confirmation_for(
                ACCOUNT_LABEL, "0" * 16, self.WORD
            ),
            harness._read_only_confirmation_for(
                ACCOUNT_LABEL, test_credential.fingerprint, "differentword"
            ),
        ]
        with mock.patch.object(
            harness,
            "PRODUCTION_BASE_URL",
            "https://invalid.example",
        ), self.assertRaises(harness.SafetyError):
            harness._read_only_confirmation_for(
                ACCOUNT_LABEL, test_credential.fingerprint, self.WORD
            )
        with mock.patch.object(
            harness,
            "READ_ONLY_ENDPOINT_TEMPLATES",
            ("GET /invalid",),
        ), self.assertRaises(harness.SafetyError):
            harness._read_only_confirmation_for(
                ACCOUNT_LABEL, test_credential.fingerprint, self.WORD
            )
        self.assertTrue(all(item != baseline for item in variants))
        self.assertIn(harness.READ_ONLY_PRICING_TERMS_CLAUSE, baseline)
        safe = self.probe_gate(test_credential).safe_summary()
        self.assertIn("pricing/terms", safe["manual_gate"])
        self.assertNotIn(ACCOUNT_LABEL, json.dumps(safe, ensure_ascii=False))
        self.assertNotIn(self.WORD, json.dumps(safe, ensure_ascii=False))

    def test_token_shape_and_accidental_argv_collision_fail_without_leak(self) -> None:
        for malformed in (
            " leading-token",
            "trailing-token ",
            "line\nbreak",
            "X" * (harness.MAX_TOKEN_CHARS + 1),
        ):
            with self.subTest(token_length=len(malformed)), self.assertRaises(
                harness.SafetyError
            ) as context:
                harness.TestAccountCredential(malformed, ACCOUNT_LABEL)
            self.assertNotIn(malformed, str(context.exception))

        stdout = io.StringIO()
        factory_calls: list[str] = []
        with mock.patch("sys.stdout", stdout):
            result = harness.main(
                [
                    "read-only-probe",
                    "--word",
                    FAKE_TOKEN,
                    "--account-label",
                    ACCOUNT_LABEL,
                    "--allow-network",
                ],
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: "unused",
                transport_factory=lambda: factory_calls.append("called")
                or FakeTransport(),
                stdin_isatty=lambda: True,
            )
        self.assertEqual(result, 3)
        self.assertEqual(factory_calls, [])
        self.assertNotIn(FAKE_TOKEN, stdout.getvalue())

        test_credential = self.probe_credential()
        leaking_gate = harness.ReadOnlyProbeGate(
            account_label=ACCOUNT_LABEL,
            credential_fingerprint=test_credential.fingerprint,
            requested_word=FAKE_TOKEN,
            confirmation=harness._read_only_confirmation_for(
                ACCOUNT_LABEL,
                test_credential.fingerprint,
                FAKE_TOKEN,
            ),
        )
        self.assertNotIn(FAKE_TOKEN, repr(leaking_gate))
        self.assertNotIn(FAKE_TOKEN, str(leaking_gate))
        self.assertNotIn(
            FAKE_TOKEN,
            json.dumps(leaking_gate.safe_summary(), ensure_ascii=False),
        )

        spelling_token_credential = harness.TestAccountCredential(
            self.RETURNED_WORD,
            ACCOUNT_LABEL,
        )
        spelling_token_gate = self.probe_gate(spelling_token_credential)
        with self.assertRaises(harness.SafetyError) as result_context:
            harness.ReadOnlyProbeExecutor(
                FakeTransport(self.responses())
            ).execute(spelling_token_credential, spelling_token_gate)
        self.assertNotIn(self.RETURNED_WORD, str(result_context.exception))

    def test_fake_cli_flow_sends_only_three_gets_and_sanitizes_output(self) -> None:
        transport = FakeTransport(self.responses())
        test_credential = self.probe_credential()
        gate = self.probe_gate(test_credential)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch(
            "sys.stderr", stderr
        ), mock.patch.object(
            Path,
            "open",
            side_effect=AssertionError("read-only probe persisted a file"),
        ), mock.patch(
            "builtins.open",
            side_effect=AssertionError("read-only probe persisted a file"),
        ):
            result = harness.main(
                self.cli_args(),
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: gate.expected_confirmation,
                transport_factory=lambda: transport,
                stdin_isatty=lambda: True,
            )
        self.assertEqual(result, 0)
        self.assertEqual(
            [(request.method, request.path) for request in transport.requests],
            [
                (
                    "GET",
                    "/open/api/v1/vocabulary?spelling=sampleword",
                ),
                (
                    "GET",
                    "/open/api/v1/interpretations?voc_id=INVALID_ISSUE11_VOCABULARY_ID",
                ),
                (
                    "GET",
                    "/open/api/v1/phrases?voc_id=INVALID_ISSUE11_VOCABULARY_ID",
                ),
            ],
        )
        rendered = stdout.getvalue() + stderr.getvalue()
        for forbidden in (
            FAKE_TOKEN,
            ACCOUNT_LABEL,
            self.VOCABULARY_ID,
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
            "PRIVATE OFFLINE TRANSLATION BODY",
        ):
            self.assertNotIn(forbidden, rendered)
        self.assertIn(self.WORD, rendered)
        self.assertIn(self.RETURNED_WORD, rendered)
        self.assertIn(test_credential.fingerprint, rendered)
        self.assertIn('"interpretation_count": 1', rendered)
        self.assertIn('"phrase_count": 1', rendered)

    def test_read_only_guard_rejects_every_write_method(self) -> None:
        delegate = FakeTransport()
        guard = harness.ReadOnlyTransportGuard(delegate)
        test_credential = self.probe_credential()
        post = harness.HttpRequest(
            "POST",
            "/open/api/v1/interpretations",
            {"interpretation": {}},
        )
        with self.assertRaisesRegex(harness.SafetyError, "GET requests only"):
            guard.send(post, test_credential)
        self.assertEqual(delegate.requests, [])
        for method in ("PUT", "PATCH", "DELETE"):
            with self.subTest(method=method), self.assertRaises(harness.SafetyError):
                harness.HttpRequest(
                    method,
                    "/open/api/v1/vocabulary?spelling=sampleword",
                )

    def test_redirect_is_rejected_without_following_or_reading_body(self) -> None:
        test_credential = self.probe_credential()
        transport = FakeTransport(
            [harness.HttpResponse(302, {"location": "https://invalid.example"})]
        )
        with self.assertRaises(harness.SafetyError) as context:
            harness.ReadOnlyProbeExecutor(transport).execute(
                test_credential,
                self.probe_gate(test_credential),
            )
        self.assertEqual(len(transport.requests), 1)
        self.assertNotIn(FAKE_TOKEN, str(context.exception))

        class FakeSocket:
            def settimeout(self, _timeout: float) -> None:
                return None

        class RedirectResponse:
            status = 302

            def read(self, _limit: int) -> bytes:
                raise AssertionError("redirect body must not be read")

        class FakeConnection:
            instances: list["FakeConnection"] = []

            def __init__(self, host: str, *, timeout: float) -> None:
                self.host = host
                self.timeout = timeout
                self.sock: FakeSocket | None = None
                self.requests: list[tuple[object, ...]] = []
                self.closed = False
                self.__class__.instances.append(self)

            def connect(self) -> None:
                self.sock = FakeSocket()

            def request(self, *args: object, **kwargs: object) -> None:
                self.requests.append((*args, kwargs))

            def getresponse(self) -> RedirectResponse:
                return RedirectResponse()

            def close(self) -> None:
                self.closed = True

        request = harness.HttpRequest(
            "GET",
            "/open/api/v1/vocabulary?spelling=sampleword",
        )
        with mock.patch.object(
            harness.http.client,
            "HTTPSConnection",
            FakeConnection,
        ), self.assertRaises(harness.TransportError) as transport_context:
            harness.ProductionHttpTransport().send(request, test_credential)
        connection = FakeConnection.instances[-1]
        self.assertEqual(connection.host, "open.maimemo.com")
        self.assertEqual(len(connection.requests), 1)
        self.assertTrue(connection.closed)
        self.assertNotIn(FAKE_TOKEN, str(transport_context.exception))

    def test_http_and_transport_failures_do_not_leak_or_retry(self) -> None:
        test_credential = self.probe_credential()
        cases: list[harness.HttpResponse | Exception] = [
            harness.HttpResponse(
                401,
                {
                    "error": FAKE_TOKEN,
                    "private": self.PRIVATE_INTERPRETATION,
                },
            ),
            harness.HttpResponse(
                500,
                {"private": self.PRIVATE_PHRASE},
            ),
            harness.TransportError(FAKE_TOKEN),
        ]
        for response in cases:
            with self.subTest(response_type=type(response).__name__):
                transport = FakeTransport([response])
                with self.assertRaises(harness.SafetyError) as context:
                    harness.ReadOnlyProbeExecutor(transport).execute(
                        test_credential,
                        self.probe_gate(test_credential),
                    )
                self.assertEqual(len(transport.requests), 1)
                rendered = str(context.exception)
                self.assertNotIn(FAKE_TOKEN, rendered)
                self.assertNotIn(self.PRIVATE_INTERPRETATION, rendered)
                self.assertNotIn(self.PRIVATE_PHRASE, rendered)

        failing_transport = FakeTransport(
            [
                harness.HttpResponse(
                    401,
                    {"error": FAKE_TOKEN, "private": self.PRIVATE_PHRASE},
                )
            ]
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            result = harness.main(
                self.cli_args(),
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: self.probe_gate(
                    test_credential
                ).expected_confirmation,
                transport_factory=lambda: failing_transport,
                stdin_isatty=lambda: True,
            )
        self.assertEqual(result, 4)
        self.assertEqual(len(failing_transport.requests), 1)
        rendered = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn(FAKE_TOKEN, rendered)
        self.assertNotIn(self.PRIVATE_PHRASE, rendered)

    def test_schema_ambiguity_unsafe_ids_and_spelling_mismatch_stop_immediately(self) -> None:
        test_credential = self.probe_credential()
        cases = [
            ("missing-voc", [harness.HttpResponse(200, {})], 1),
            (
                "sensitive-top-level-key",
                [harness.HttpResponse(200, {"token": FAKE_TOKEN})],
                1,
            ),
            (
                "unsafe-voc-id",
                self.responses(
                    vocabulary={"id": "../unsafe", "spelling": self.WORD}
                ),
                1,
            ),
            (
                "spelling-mismatch",
                self.responses(
                    vocabulary={"id": self.VOCABULARY_ID, "spelling": "otherword"}
                ),
                1,
            ),
            (
                "interpretations-not-array",
                self.responses(interpretations={"not": "an array"}),
                2,
            ),
            (
                "duplicate-interpretation-id",
                self.responses(
                    interpretations=[
                        {"id": "INVALID_DUPLICATE", "status": "PUBLISHED"},
                        {"id": "INVALID_DUPLICATE", "status": "PUBLISHED"},
                    ]
                ),
                2,
            ),
            (
                "missing-interpretation-status",
                self.responses(
                    interpretations=[{"id": "INVALID_INTERPRETATION_ID"}]
                ),
                2,
            ),
            (
                "unsafe-phrase-id",
                self.responses(
                    phrases=[
                        {
                            "id": "unsafe/id",
                            "status": "PUBLISHED",
                            "phrase": self.PRIVATE_PHRASE,
                            "highlight": [],
                        }
                    ]
                ),
                3,
            ),
            (
                "missing-highlight",
                self.responses(
                    phrases=[
                        {
                            "id": "INVALID_PHRASE_ID",
                            "status": "PUBLISHED",
                            "phrase": self.PRIVATE_PHRASE,
                        }
                    ]
                ),
                3,
            ),
            (
                "duplicate-phrase-id",
                self.responses(
                    phrases=[
                        {
                            "id": "INVALID_DUPLICATE_PHRASE",
                            "status": "PUBLISHED",
                            "phrase": self.PRIVATE_PHRASE,
                            "highlight": [],
                        },
                        {
                            "id": "INVALID_DUPLICATE_PHRASE",
                            "status": "PUBLISHED",
                            "phrase": self.PRIVATE_PHRASE,
                            "highlight": [],
                        },
                    ]
                ),
                3,
            ),
        ]
        for name, responses, expected_requests in cases:
            with self.subTest(name=name):
                transport = FakeTransport(responses)
                with self.assertRaises(harness.SafetyError) as context:
                    harness.ReadOnlyProbeExecutor(transport).execute(
                        test_credential,
                        self.probe_gate(test_credential),
                    )
                self.assertEqual(len(transport.requests), expected_requests)
                self.assertNotIn(FAKE_TOKEN, str(context.exception))

    def test_safe_result_contains_counts_statuses_shapes_and_fingerprint_only(self) -> None:
        test_credential = self.probe_credential()
        result = harness.ReadOnlyProbeExecutor(
            FakeTransport(self.responses())
        ).execute(test_credential, self.probe_gate(test_credential))
        safe = result.safe_summary()
        self.assertEqual(
            set(safe),
            {
                "mode",
                "requested_spelling",
                "returned_spelling",
                "voc_id_fingerprint",
                "interpretation_count",
                "phrase_count",
                "interpretation_statuses",
                "phrase_statuses",
                "phrase_highlight_shapes",
                "response_statuses",
                "response_shapes",
            },
        )
        self.assertEqual(
            safe["response_shapes"],
            {
                "vocabulary": {
                    "canonical_key": "voc",
                    "canonical_key_present": True,
                    "unknown_top_level_field_count": 0,
                },
                "interpretations": {
                    "canonical_key": "interpretations",
                    "canonical_key_present": True,
                    "unknown_top_level_field_count": 0,
                },
                "phrases": {
                    "canonical_key": "phrases",
                    "canonical_key_present": True,
                    "unknown_top_level_field_count": 0,
                },
            },
        )
        self.assertEqual(safe["interpretation_statuses"], {"PUBLISHED": 1})
        self.assertEqual(safe["phrase_statuses"], {"PUBLISHED": 1})
        self.assertEqual(
            safe["phrase_highlight_shapes"], {"integer-pair-array": 1}
        )
        rendered = json.dumps(safe, ensure_ascii=False) + repr(result) + str(result)
        for forbidden in (
            FAKE_TOKEN,
            ACCOUNT_LABEL,
            self.VOCABULARY_ID,
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
        ):
            self.assertNotIn(forbidden, rendered)
        self.assertEqual(len(safe["voc_id_fingerprint"]), 16)

        object_shape_result = harness.ReadOnlyProbeExecutor(
            FakeTransport(
                self.responses(
                    phrases=[
                        {
                            "id": "INVALID_OBJECT_RANGE_PHRASE",
                            "status": "PUBLISHED",
                            "phrase": self.PRIVATE_PHRASE,
                            "highlight": [{"start": 0, "end": 10}],
                        },
                        {
                            "id": "INVALID_EMPTY_RANGE_PHRASE",
                            "status": "DELETED",
                            "phrase": self.PRIVATE_PHRASE,
                            "highlight": [],
                        },
                    ]
                )
            )
        ).execute(test_credential, self.probe_gate(test_credential))
        self.assertEqual(
            object_shape_result.safe_summary()["phrase_highlight_shapes"],
            {"object-range-array": 1, "empty-array": 1},
        )

    def test_record_status_accepts_only_the_endpoint_specific_enum(self) -> None:
        test_credential = self.probe_credential()
        for status in ("PUBLISHED", "UNPUBLISHED", "DELETED"):
            with self.subTest(endpoint="interpretations", status=status):
                result = harness.ReadOnlyProbeExecutor(
                    FakeTransport(
                        self.responses(
                            interpretations=[self.interpretation_record(status=status)]
                        )
                    )
                ).execute(test_credential, self.probe_gate(test_credential))
                self.assertEqual(
                    result.safe_summary()["interpretation_statuses"], {status: 1}
                )
        for status in ("PUBLISHED", "DELETED"):
            with self.subTest(endpoint="phrases", status=status):
                result = harness.ReadOnlyProbeExecutor(
                    FakeTransport(
                        self.responses(phrases=[self.phrase_record(status=status)])
                    )
                ).execute(test_credential, self.probe_gate(test_credential))
                self.assertEqual(result.safe_summary()["phrase_statuses"], {status: 1})

        server_string = "".join(("PUB", "LISHED"))
        self.assertIsNot(server_string, "PUBLISHED")
        reported = harness.ReadOnlyProbeExecutor(
            FakeTransport(
                self.responses(
                    interpretations=[self.interpretation_record(status=server_string)]
                )
            )
        ).execute(test_credential, self.probe_gate(test_credential))
        reported_status = next(iter(reported.safe_summary()["interpretation_statuses"]))
        self.assertTrue(
            any(
                reported_status is documented
                for documented in harness.READ_ONLY_STATUS_ENUMS["interpretations"]
            ),
            "safe output must reuse the documented constant, not server memory",
        )

    def test_unknown_or_non_string_status_fails_closed_without_echo(self) -> None:
        test_credential = self.probe_credential()
        missing = object()
        unknown_strings = (
            "PRIVATESECRET",
            "DRAFT",
            "ARCHIVEDPRIVATENOTE",
            "published",
            " PUBLISHED ",
            "",
        )
        shared_invalid: tuple[object, ...] = (
            missing,
            *unknown_strings,
            0,
            7,
            True,
            False,
            None,
            ["PUBLISHED"],
            {"status": "PUBLISHED"},
        )
        endpoints = (
            ("interpretations", shared_invalid, 2),
            ("phrases", (*shared_invalid, "UNPUBLISHED"), 3),
        )
        for response_key, invalid_values, expected_requests in endpoints:
            for index, value in enumerate(invalid_values):
                with self.subTest(endpoint=response_key, index=index):
                    if response_key == "interpretations":
                        record = self.interpretation_record()
                        responses = self.responses(interpretations=[record])
                    else:
                        record = self.phrase_record()
                        responses = self.responses(phrases=[record])
                    if value is missing:
                        del record["status"]
                    else:
                        record["status"] = value
                    transport = FakeTransport(responses)
                    with self.assertRaises(harness.SafetyError) as context:
                        harness.ReadOnlyProbeExecutor(transport).execute(
                            test_credential,
                            self.probe_gate(test_credential),
                        )
                    self.assertEqual(len(transport.requests), expected_requests)
                    rendered = f"{context.exception}{context.exception!r}"
                    if isinstance(value, str) and value:
                        self.assertNotIn(value, rendered)
                    for forbidden in (
                        FAKE_TOKEN,
                        self.PRIVATE_INTERPRETATION,
                        self.PRIVATE_PHRASE,
                    ):
                        self.assertNotIn(forbidden, rendered)

        for response_key, unknown in (
            ("interpretations", "PRIVATESECRET"),
            ("phrases", "ANOTHERSECRET"),
        ):
            with self.subTest(cli=response_key):
                if response_key == "interpretations":
                    responses = self.responses(
                        interpretations=[self.interpretation_record(status=unknown)]
                    )
                else:
                    responses = self.responses(
                        phrases=[self.phrase_record(status=unknown)]
                    )
                stdout = io.StringIO()
                stderr = io.StringIO()
                with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
                    exit_code = harness.main(
                        self.cli_args(),
                        token_prompt=lambda _message: FAKE_TOKEN,
                        confirmation_prompt=lambda _message: self.probe_gate(
                            test_credential
                        ).expected_confirmation,
                        transport_factory=lambda: FakeTransport(responses),
                        stdin_isatty=lambda: True,
                    )
                self.assertEqual(exit_code, 4)
                rendered = stdout.getvalue() + stderr.getvalue()
                for forbidden in (
                    unknown,
                    FAKE_TOKEN,
                    self.PRIVATE_INTERPRETATION,
                    self.PRIVATE_PHRASE,
                ):
                    self.assertNotIn(forbidden, rendered)

    def test_highlight_ranges_within_phrase_length_are_accepted(self) -> None:
        test_credential = self.probe_credential()
        length = len(self.PRIVATE_PHRASE)
        accepted = (
            ("object-range", [{"start": 1, "end": 5}], "object-range-array"),
            ("integer-pair-range", [[1, 5]], "integer-pair-array"),
            (
                "object-end-equals-length",
                [{"start": 0, "end": length}],
                "object-range-array",
            ),
            ("pair-end-equals-length", [[0, length]], "integer-pair-array"),
            ("no-highlight-returned", [], "empty-array"),
        )
        for name, highlight, expected_shape in accepted:
            with self.subTest(accepted=name):
                result = harness.ReadOnlyProbeExecutor(
                    FakeTransport(
                        self.responses(
                            phrases=[self.phrase_record(highlight=highlight)]
                        )
                    )
                ).execute(test_credential, self.probe_gate(test_credential))
                safe = result.safe_summary()
                self.assertEqual(
                    safe["phrase_highlight_shapes"], {expected_shape: 1}
                )
                rendered = (
                    json.dumps(safe, ensure_ascii=False) + repr(result) + str(result)
                )
                self.assertNotIn(self.PRIVATE_PHRASE, rendered)

    def test_out_of_bounds_or_malformed_highlight_fails_closed_without_echo(
        self,
    ) -> None:
        test_credential = self.probe_credential()
        length = len(self.PRIVATE_PHRASE)
        rejected = (
            ("object-end-beyond-phrase", [{"start": 0, "end": length + 1}]),
            ("pair-end-beyond-phrase", [[0, length + 1]]),
            ("pair-far-beyond-phrase", [[0, 999999]]),
            ("object-zero-length-range", [{"start": 3, "end": 3}]),
            ("pair-zero-length-range", [[3, 3]]),
            ("object-negative-start", [{"start": -1, "end": 4}]),
            ("pair-negative-start", [[-1, 4]]),
            ("pair-negative-end", [[0, -4]]),
            ("object-start-after-end", [{"start": 5, "end": 2}]),
            ("pair-start-after-end", [[5, 2]]),
            ("object-boolean-start", [{"start": True, "end": 4}]),
            ("pair-boolean-end", [[0, True]]),
            ("mixed-structures", [{"start": 0, "end": 4}, [0, 4]]),
            ("oversized-tuple", [[0, 2, 4]]),
            ("string-range", [["0", "4"]]),
            ("missing-object-keys", [{"begin": 0, "finish": 4}]),
            ("not-an-array", {"start": 0, "end": 4}),
        )
        for name, highlight in rejected:
            with self.subTest(rejected=name):
                transport = FakeTransport(
                    self.responses(phrases=[self.phrase_record(highlight=highlight)])
                )
                with self.assertRaises(harness.SafetyError) as context:
                    harness.ReadOnlyProbeExecutor(transport).execute(
                        test_credential,
                        self.probe_gate(test_credential),
                    )
                self.assertEqual(len(transport.requests), 3)
                rendered = f"{context.exception}{context.exception!r}"
                self.assertNotIn(self.PRIVATE_PHRASE, rendered)
                self.assertNotIn(FAKE_TOKEN, rendered)

        missing = object()
        invalid_phrases: tuple[object, ...] = (
            missing,
            "",
            123,
            True,
            None,
            ["PRIVATE OFFLINE PHRASE BODY"],
            {"text": "PRIVATE OFFLINE PHRASE BODY"},
        )
        for index, value in enumerate(invalid_phrases):
            with self.subTest(invalid_phrase=index):
                record = self.phrase_record()
                if value is missing:
                    del record["phrase"]
                else:
                    record["phrase"] = value
                transport = FakeTransport(self.responses(phrases=[record]))
                with self.assertRaises(harness.SafetyError) as context:
                    harness.ReadOnlyProbeExecutor(transport).execute(
                        test_credential,
                        self.probe_gate(test_credential),
                    )
                self.assertEqual(len(transport.requests), 3)
                rendered = f"{context.exception}{context.exception!r}"
                self.assertNotIn(self.PRIVATE_PHRASE, rendered)
                self.assertNotIn(FAKE_TOKEN, rendered)

        stdout = io.StringIO()
        stderr = io.StringIO()
        out_of_bounds = self.responses(
            phrases=[self.phrase_record(highlight=[[0, 999999]])]
        )
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            exit_code = harness.main(
                self.cli_args(),
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: self.probe_gate(
                    test_credential
                ).expected_confirmation,
                transport_factory=lambda: FakeTransport(out_of_bounds),
                stdin_isatty=lambda: True,
            )
        self.assertEqual(exit_code, 4)
        rendered = stdout.getvalue() + stderr.getvalue()
        for forbidden in (FAKE_TOKEN, self.PRIVATE_PHRASE, "999999"):
            self.assertNotIn(forbidden, rendered)

    def test_argv_parse_failures_never_echo_token_or_argument_values(self) -> None:
        secret = "PRIVATE_SECRET_TOKEN_c41f0a9e2b7d"
        sentinel = "PRIVATE_SENTINEL_UNKNOWN_ARGUMENT_VALUE"
        prompt_calls: list[str] = []
        factory_calls: list[str] = []

        def prompt(_message: str) -> str:
            prompt_calls.append("called")
            return FAKE_TOKEN

        def factory() -> FakeTransport:
            factory_calls.append("called")
            return FakeTransport(self.responses())

        cases = (
            ("separate-token-option", [*self.cli_args(), "--token", secret]),
            ("joined-token-option", [*self.cli_args(), f"--token={secret}"]),
            ("unknown-option-value", [*self.cli_args(), "--unexpected-option", sentinel]),
            ("unknown-mode-value", ["--mode", sentinel]),
            ("unknown-subcommand", [sentinel]),
            ("bare-positional", [*self.cli_args(), sentinel]),
            (
                "subcommand-with-legacy-mode",
                ["--mode", "read-only", *self.cli_args()],
            ),
        )
        for name, argv in cases:
            with self.subTest(case=name):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with mock.patch("sys.stdout", stdout), mock.patch(
                    "sys.stderr", stderr
                ), self.assertRaises(SystemExit) as context:
                    harness.main(
                        argv,
                        token_prompt=prompt,
                        confirmation_prompt=prompt,
                        transport_factory=factory,
                        stdin_isatty=lambda: True,
                    )
                self.assertEqual(context.exception.code, 2)
                rendered = (
                    stdout.getvalue()
                    + stderr.getvalue()
                    + str(context.exception)
                    + repr(context.exception)
                )
                for forbidden in (
                    secret,
                    sentinel,
                    "--token",
                    "--unexpected-option",
                    FAKE_TOKEN,
                ):
                    self.assertNotIn(forbidden, rendered)
                self.assertIn("usage:", rendered)

        self.assertEqual(prompt_calls, [])
        self.assertEqual(factory_calls, [])

        stderr = io.StringIO()
        with mock.patch("sys.stdout", io.StringIO()), mock.patch(
            "sys.stderr", stderr
        ), self.assertRaises(SystemExit):
            harness.parse_args([*self.cli_args(), "--token", secret])
        self.assertIn(harness.SANITIZED_ARGV_ERROR, stderr.getvalue())
        self.assertNotIn(secret, stderr.getvalue())

    def sentinel_key_responses(self) -> list[harness.HttpResponse]:
        return [
            harness.HttpResponse(
                200,
                {
                    "voc": {
                        "id": self.VOCABULARY_ID,
                        "spelling": self.RETURNED_WORD,
                    },
                    self.PRIVATE_VOCABULARY_KEY: {"nested": "PRIVATE NESTED VALUE"},
                },
            ),
            harness.HttpResponse(
                200,
                {
                    "interpretations": [self.interpretation_record()],
                    self.PRIVATE_INTERPRETATION: {},
                },
            ),
            harness.HttpResponse(
                200,
                {
                    "phrases": [self.phrase_record()],
                    self.PRIVATE_PHRASE: [],
                },
            ),
        ]

    def test_unknown_top_level_key_names_never_reach_ordinary_output(self) -> None:
        test_credential = self.probe_credential()
        result = harness.ReadOnlyProbeExecutor(
            FakeTransport(self.sentinel_key_responses())
        ).execute(test_credential, self.probe_gate(test_credential))
        safe = result.safe_summary()
        self.assertEqual(
            safe["response_shapes"],
            {
                "vocabulary": {
                    "canonical_key": "voc",
                    "canonical_key_present": True,
                    "unknown_top_level_field_count": 1,
                },
                "interpretations": {
                    "canonical_key": "interpretations",
                    "canonical_key_present": True,
                    "unknown_top_level_field_count": 1,
                },
                "phrases": {
                    "canonical_key": "phrases",
                    "canonical_key_present": True,
                    "unknown_top_level_field_count": 1,
                },
            },
        )
        rendered = json.dumps(safe, ensure_ascii=False) + repr(result) + str(result)
        for forbidden in (
            self.PRIVATE_VOCABULARY_KEY,
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
            "PRIVATE NESTED VALUE",
            self.VOCABULARY_ID,
            FAKE_TOKEN,
        ):
            self.assertNotIn(forbidden, rendered)

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            exit_code = harness.main(
                self.cli_args(),
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: self.probe_gate(
                    test_credential
                ).expected_confirmation,
                transport_factory=lambda: FakeTransport(
                    self.sentinel_key_responses()
                ),
                stdin_isatty=lambda: True,
            )
        self.assertEqual(exit_code, 0)
        rendered = stdout.getvalue() + stderr.getvalue()
        for forbidden in (
            self.PRIVATE_VOCABULARY_KEY,
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
            "PRIVATE NESTED VALUE",
            self.VOCABULARY_ID,
            FAKE_TOKEN,
        ):
            self.assertNotIn(forbidden, rendered)

    def test_rejected_top_level_fields_do_not_echo_the_field_name(self) -> None:
        test_credential = self.probe_credential()
        sensitive_key = f"{self.PRIVATE_VOCABULARY_KEY} token"
        cases = (
            (
                "sensitive-unknown-key",
                [
                    harness.HttpResponse(
                        200,
                        {
                            "voc": {
                                "id": self.VOCABULARY_ID,
                                "spelling": self.RETURNED_WORD,
                            },
                            sensitive_key: {},
                        },
                    )
                ],
                sensitive_key,
            ),
            (
                "non-string-key",
                [harness.HttpResponse(200, {7: ["PRIVATE NESTED VALUE"]})],
                "PRIVATE NESTED VALUE",
            ),
        )
        for name, responses, forbidden in cases:
            with self.subTest(case=name):
                transport = FakeTransport(responses)
                with self.assertRaises(harness.SafetyError) as context:
                    harness.ReadOnlyProbeExecutor(transport).execute(
                        test_credential,
                        self.probe_gate(test_credential),
                    )
                self.assertEqual(len(transport.requests), 1)
                rendered = f"{context.exception}{context.exception!r}"
                self.assertNotIn(forbidden, rendered)
                self.assertNotIn(FAKE_TOKEN, rendered)


SERVER_KEY_SENTINEL = "PRIVATE-SERVER-KEY-SENTINEL"
SERVER_BODY_SENTINEL = "PRIVATE SERVER BODY SENTINEL"
SERVER_MESSAGE_SENTINEL = "PRIVATE SERVER ERROR MESSAGE SENTINEL"
REDIRECT_LOCATION_SENTINEL = "https://redirect-target.invalid/private-sentinel-path"
TRANSPORT_EXCEPTION_SENTINEL = "PRIVATE TRANSPORT EXCEPTION SENTINEL"
PRODUCTION_IO_SENTINEL = "PRIVATE-PRODUCTION-IO-SENTINEL"
# Issue #16: a non-empty string voc id that the unchanged local
# ``_safe_record_id`` policy rejects because of its punctuation. This is the
# hypothesis the next owner-authorized run has to prove or disprove, so it must
# be classified exactly and must never appear in any output.
VOC_ID_PUNCTUATION_SENTINEL = "PRIVATE.ISSUE16/VOC ID+SENTINEL"
SPELLING_SENTINEL = "PRIVATEISSUE16SPELLINGSENTINEL"
INJECTED_REASON_SENTINEL = "PRIVATE-INJECTED-SCHEMA-REASON-SENTINEL"
# Issue #18: the envelope classifier reads an in-memory production body. Every
# key name and value it could conceivably touch is a private sentinel here, so
# any leak into a diagnostic, stdout, stderr, repr or traceback is a test
# failure rather than a silent disclosure.
ENVELOPE_UNKNOWN_KEY_SENTINEL = "PRIVATE-ISSUE18-UNKNOWN-SERVER-KEY-SENTINEL"
ENVELOPE_OTHER_KEY_SENTINEL = "PRIVATE-ISSUE18-SECOND-UNKNOWN-SERVER-KEY-SENTINEL"
ENVELOPE_VALUE_SENTINEL = "PRIVATE ISSUE18 SERVER VALUE SENTINEL"
ENVELOPE_ID_SENTINEL = "PRIVATE-ISSUE18-VOC-ID-SENTINEL"
ENVELOPE_SPELLING_SENTINEL = "PRIVATEISSUE18SPELLINGSENTINEL"
ENVELOPE_CODE_SENTINEL = "PRIVATE-ISSUE18-BUSINESS-CODE-SENTINEL"
ENVELOPE_MESSAGE_SENTINEL = "PRIVATE ISSUE18 BUSINESS MESSAGE SENTINEL"
ENVELOPE_STATUS_SENTINEL = "PRIVATE-ISSUE18-BUSINESS-STATUS-SENTINEL"
ENVELOPE_INJECTED_SENTINEL = "PRIVATE-INJECTED-RESPONSE-ENVELOPE-SENTINEL"
# Issue #20: the compatibility boundary descends into one wrapper. Every sibling
# key and value it passes on the way is a private sentinel here, so anything that
# escapes into a diagnostic, stdout, stderr, repr or traceback is a test failure
# rather than a silent disclosure.
COMPAT_UNKNOWN_KEY_SENTINEL = "PRIVATE-ISSUE20-UNKNOWN-WRAPPER-KEY-SENTINEL"
COMPAT_VALUE_SENTINEL = "PRIVATE ISSUE20 WRAPPER VALUE SENTINEL"
# Issue #22: the same boundary now descends one wrapper for the two collection
# GETs. Every sibling key and value it passes on the way is a private sentinel
# here, so anything that escapes into a diagnostic, stdout, stderr, repr or
# traceback is a test failure rather than a silent disclosure.
COLLECTION_UNKNOWN_KEY_SENTINEL = "PRIVATE-ISSUE22-UNKNOWN-COLLECTION-KEY-SENTINEL"
COLLECTION_VALUE_SENTINEL = "PRIVATE ISSUE22 COLLECTION VALUE SENTINEL"
COLLECTION_RECORD_ID_SENTINEL = "PRIVATE.ISSUE22/COLLECTION ID+SENTINEL"
SENTINELS = (
    FAKE_TOKEN,
    SERVER_KEY_SENTINEL,
    SERVER_BODY_SENTINEL,
    SERVER_MESSAGE_SENTINEL,
    REDIRECT_LOCATION_SENTINEL,
    TRANSPORT_EXCEPTION_SENTINEL,
    PRODUCTION_IO_SENTINEL,
    VOC_ID_PUNCTUATION_SENTINEL,
    SPELLING_SENTINEL,
    INJECTED_REASON_SENTINEL,
    ENVELOPE_UNKNOWN_KEY_SENTINEL,
    ENVELOPE_OTHER_KEY_SENTINEL,
    ENVELOPE_VALUE_SENTINEL,
    ENVELOPE_ID_SENTINEL,
    ENVELOPE_SPELLING_SENTINEL,
    ENVELOPE_CODE_SENTINEL,
    ENVELOPE_MESSAGE_SENTINEL,
    ENVELOPE_STATUS_SENTINEL,
    ENVELOPE_INJECTED_SENTINEL,
    COMPAT_UNKNOWN_KEY_SENTINEL,
    COMPAT_VALUE_SENTINEL,
    COLLECTION_UNKNOWN_KEY_SENTINEL,
    COLLECTION_VALUE_SENTINEL,
    COLLECTION_RECORD_ID_SENTINEL,
)


def envelope_record(**overrides: object) -> dict[str, object]:
    """A vocabulary-shaped record built only from private sentinel values."""
    record: dict[str, object] = {
        "id": ENVELOPE_ID_SENTINEL,
        "spelling": ENVELOPE_SPELLING_SENTINEL,
        ENVELOPE_UNKNOWN_KEY_SENTINEL: ENVELOPE_VALUE_SENTINEL,
    }
    record.update(overrides)
    return record


def missing_voc_envelope_cases() -> tuple[tuple[str, dict[str, object], str], ...]:
    """Issue #18: ``(name, HTTP 200 body, expected response_envelope)``.

    Every body here is a complete, decoded JSON object with **no** documented
    top-level ``voc``, which is exactly the live third-run shape: the probe still
    fails with ``schema_reason = missing-voc``, and the envelope only says where
    an apparent vocabulary record lives.

    Two envelope constants are absent on purpose and are covered at the
    classifier level instead. ``direct-voc-object`` never reaches ``missing-voc``
    because a body with a usable top-level ``voc`` is validated by the documented
    path. ``data-voc-wrapper`` no longer reaches it either: after Issue #20 that
    single observed production location is canonicalized and handed to the
    unchanged vocabulary validation, so it is covered by
    :func:`data_voc_compatibility_cases`.
    """
    return (
        # --- one case per still-reachable envelope constant ------------------
        (
            "direct-vocabulary-object",
            envelope_record(),
            "direct-vocabulary-object",
        ),
        (
            "data-vocabulary-object",
            {"data": envelope_record()},
            "data-vocabulary-object",
        ),
        (
            "result-voc-wrapper",
            {"result": {"voc": envelope_record()}},
            "result-voc-wrapper",
        ),
        (
            "result-vocabulary-object",
            {"result": envelope_record()},
            "result-vocabulary-object",
        ),
        (
            "vocabulary-wrapper",
            {"vocabulary": envelope_record()},
            "vocabulary-wrapper",
        ),
        (
            "business-error-like",
            {
                "code": ENVELOPE_CODE_SENTINEL,
                "message": ENVELOPE_MESSAGE_SENTINEL,
                "success": False,
                ENVELOPE_UNKNOWN_KEY_SENTINEL: ENVELOPE_VALUE_SENTINEL,
            },
            "business-error-like",
        ),
        (
            "unknown-object-only-unreviewed-keys",
            {
                ENVELOPE_UNKNOWN_KEY_SENTINEL: ENVELOPE_VALUE_SENTINEL,
                ENVELOPE_OTHER_KEY_SENTINEL: [ENVELOPE_VALUE_SENTINEL],
            },
            "unknown-object",
        ),
        ("unknown-object-empty", {}, "unknown-object"),
        # --- deterministic precedence ---------------------------------------
        (
            "precedence-data-record-beats-result-wrapper",
            {"data": envelope_record(), "result": {"voc": envelope_record()}},
            "data-vocabulary-object",
        ),
        (
            "precedence-result-wrapper-beats-vocabulary-wrapper",
            {
                "result": {"voc": envelope_record()},
                "vocabulary": envelope_record(),
            },
            "result-voc-wrapper",
        ),
        (
            "precedence-vocabulary-shape-beats-business-metadata",
            {
                "data": envelope_record(),
                "status": ENVELOPE_STATUS_SENTINEL,
                "code": ENVELOPE_CODE_SENTINEL,
                "message": ENVELOPE_MESSAGE_SENTINEL,
            },
            "data-vocabulary-object",
        ),
        (
            "precedence-vocabulary-wrapper-beats-business-metadata",
            {
                "vocabulary": envelope_record(),
                "error": ENVELOPE_MESSAGE_SENTINEL,
                "success": True,
            },
            "vocabulary-wrapper",
        ),
        # --- structural near-misses collapse, never leak --------------------
        (
            "near-miss-record-with-boolean-id",
            {"vocabulary": {"id": True, "spelling": ENVELOPE_SPELLING_SENTINEL}},
            "unknown-object",
        ),
        (
            "near-miss-record-with-non-string-spelling",
            {"result": {"id": ENVELOPE_ID_SENTINEL, "spelling": [1, 2]}},
            "unknown-object",
        ),
        (
            "near-miss-container-is-not-an-object",
            {"data": ENVELOPE_VALUE_SENTINEL, "result": [ENVELOPE_VALUE_SENTINEL]},
            "unknown-object",
        ),
        # --- broad structural id types locate the record without accepting it
        (
            "integer-id-still-locates-the-record",
            {"data": {"id": 20260808, "spelling": ENVELOPE_SPELLING_SENTINEL}},
            "data-vocabulary-object",
        ),
    )


def data_voc_compatibility_cases() -> tuple[tuple[str, dict[str, object], str], ...]:
    """Issue #20: ``(name, HTTP 200 body, unchanged classifier envelope)``.

    Every body here has **no** documented top-level ``voc`` but does carry the
    one observed production location ``data.voc``, so the canonicalization
    boundary now relocates that value and the unchanged strict validation
    decides. None of them can still report ``missing-voc``.

    The third element remains the *classifier's* verdict, which Issue #20 leaves
    completely untouched: these bodies are still classified exactly as before,
    they just no longer reach the ``missing-voc`` checkpoint that reports it.
    """
    return (
        (
            "data-voc-wrapper",
            {"data": {"voc": envelope_record()}},
            "data-voc-wrapper",
        ),
        (
            "precedence-direct-record-beats-data-voc-wrapper",
            dict(envelope_record(), data={"voc": envelope_record()}),
            "direct-vocabulary-object",
        ),
        (
            "precedence-data-voc-wrapper-beats-data-record",
            {"data": dict(envelope_record(), voc=envelope_record())},
            "data-voc-wrapper",
        ),
        (
            "precedence-data-beats-result",
            {
                "data": {"voc": envelope_record()},
                "result": {"voc": envelope_record()},
            },
            "data-voc-wrapper",
        ),
        (
            "near-miss-record-without-spelling",
            {"data": {"voc": {"id": ENVELOPE_ID_SENTINEL}}},
            "unknown-object",
        ),
        (
            "near-miss-record-with-object-id",
            {
                "data": {
                    "voc": {
                        "id": {ENVELOPE_UNKNOWN_KEY_SENTINEL: ENVELOPE_VALUE_SENTINEL},
                        "spelling": ENVELOPE_SPELLING_SENTINEL,
                    }
                }
            },
            "unknown-object",
        ),
        (
            "near-miss-container-with-non-object-voc",
            {"data": {"voc": ENVELOPE_VALUE_SENTINEL}},
            "unknown-object",
        ),
        (
            "near-miss-collapses-to-business-metadata",
            {
                "data": {"voc": {"id": ENVELOPE_ID_SENTINEL}},
                "code": ENVELOPE_CODE_SENTINEL,
            },
            "business-error-like",
        ),
    )


def vocabulary_envelope_cases() -> tuple[tuple[str, dict[str, object], str], ...]:
    """The full classifier corpus: both groups above.

    The Issue #18 classifier is unchanged by Issue #20, so every body still
    classifies exactly as it did. Only the *end-to-end* consumers split, because
    the ``data.voc`` group is now accepted into the unchanged validation instead
    of stopping at ``missing-voc``.
    """
    return missing_voc_envelope_cases() + data_voc_compatibility_cases()


class Issue14ReadOnlyDiagnosticTests(ReadOnlyProbeFixtures, unittest.TestCase):
    """Issue #14: sanitized stage/class/status/counter diagnostics.

    Every case uses the fake transport plus the process-level no-network guard;
    no real credential is read and no Maimemo request is ever sent.
    """

    def hostile_body(self) -> dict[str, object]:
        """A server body carrying every sentinel the diagnostic must suppress."""
        return {
            SERVER_KEY_SENTINEL: SERVER_BODY_SENTINEL,
            "error": FAKE_TOKEN,
            "message": SERVER_MESSAGE_SENTINEL,
            "location": REDIRECT_LOCATION_SENTINEL,
        }

    def expected(
        self,
        stage: str,
        failure_class: str,
        http_status: int | None,
        attempted: int,
        completed: int,
        schema_reason: str | None = None,
        response_envelope: str | None = None,
    ) -> dict[str, object]:
        return {
            "mode": "read-only-probe",
            "status": "failed",
            "failure_stage": stage,
            "failure_class": failure_class,
            "http_status": http_status,
            "schema_reason": schema_reason,
            "response_envelope": response_envelope,
            "requests_attempted": attempted,
            "requests_completed": completed,
        }

    def vocabulary_schema_reason_cases(
        self,
    ) -> list[tuple[str, list[object], dict[str, object], int]]:
        """Issue #16: one case per vocabulary-stage ``schema_reason``.

        Every case is a completely received HTTP 200 on the first GET, exactly
        like the real second owner-authorized run, so the only thing that varies
        is which reviewed checkpoint the body violates.
        """

        def voc_case(
            name: str,
            body: object,
            schema_reason: str,
            response_envelope: str | None = None,
        ) -> tuple[str, list[object], dict[str, object], int]:
            return (
                name,
                [harness.HttpResponse(200, body)],
                self.expected(
                    "vocabulary",
                    "schema",
                    200,
                    1,
                    1,
                    schema_reason,
                    response_envelope,
                ),
                1,
            )

        def rejected_body_case(
            name: str,
            schema_reason: object,
            expected_reason: str,
        ) -> tuple[str, list[object], dict[str, object], int]:
            return (
                name,
                [harness.TransportResponseError(200, schema_reason)],
                self.expected("vocabulary", "schema", 200, 1, 1, expected_reason),
                1,
            )

        return [
            rejected_body_case(
                "vocabulary-body-invalid-utf8",
                harness.SCHEMA_REASON_BODY_INVALID_UTF8,
                "body-invalid-utf8",
            ),
            rejected_body_case(
                "vocabulary-body-invalid-json",
                harness.SCHEMA_REASON_BODY_INVALID_JSON,
                "body-invalid-json",
            ),
            rejected_body_case(
                "vocabulary-body-not-object-from-transport",
                harness.SCHEMA_REASON_BODY_NOT_OBJECT,
                "body-not-object",
            ),
            rejected_body_case(
                "vocabulary-body-too-large",
                harness.SCHEMA_REASON_BODY_TOO_LARGE,
                "body-too-large",
            ),
            rejected_body_case(
                "vocabulary-injected-reason-is-not-project-owned",
                INJECTED_REASON_SENTINEL,
                "other-reviewed-schema",
            ),
            voc_case(
                "vocabulary-body-not-object-non-string-key",
                {7: [SERVER_BODY_SENTINEL]},
                "body-not-object",
            ),
            voc_case(
                "vocabulary-top-level-response-policy",
                {
                    "voc": {"id": self.VOCABULARY_ID, "spelling": self.RETURNED_WORD},
                    f"{SERVER_KEY_SENTINEL}-token": SERVER_BODY_SENTINEL,
                },
                "top-level-response-policy",
            ),
            voc_case(
                "vocabulary-missing-voc-field",
                {SERVER_KEY_SENTINEL: SERVER_BODY_SENTINEL},
                "missing-voc",
                "unknown-object",
            ),
            voc_case(
                "vocabulary-voc-not-object",
                {"voc": SERVER_BODY_SENTINEL},
                "voc-not-object",
            ),
            voc_case(
                "vocabulary-voc-id-missing",
                {"voc": {"spelling": self.RETURNED_WORD}},
                "voc-id-missing-or-not-string",
            ),
            voc_case(
                "vocabulary-voc-id-not-a-string",
                {"voc": {"id": 20260808, "spelling": self.RETURNED_WORD}},
                "voc-id-missing-or-not-string",
            ),
            voc_case(
                "vocabulary-voc-id-empty",
                {"voc": {"id": "", "spelling": self.RETURNED_WORD}},
                "voc-id-empty",
            ),
            voc_case(
                "vocabulary-voc-id-local-policy",
                {
                    "voc": {
                        "id": VOC_ID_PUNCTUATION_SENTINEL,
                        "spelling": self.RETURNED_WORD,
                    }
                },
                "voc-id-local-policy",
            ),
            voc_case(
                "vocabulary-spelling-missing",
                {"voc": {"id": self.VOCABULARY_ID}},
                "spelling-missing-or-not-string",
            ),
            voc_case(
                "vocabulary-spelling-not-a-string",
                {"voc": {"id": self.VOCABULARY_ID, "spelling": [SPELLING_SENTINEL]}},
                "spelling-missing-or-not-string",
            ),
            voc_case(
                "vocabulary-spelling-local-policy",
                {
                    "voc": {
                        "id": self.VOCABULARY_ID,
                        "spelling": f" {self.RETURNED_WORD} ",
                    }
                },
                "spelling-local-policy",
            ),
            voc_case(
                "vocabulary-spelling-mismatch-sentinel",
                {"voc": {"id": self.VOCABULARY_ID, "spelling": SPELLING_SENTINEL}},
                "spelling-mismatch",
            ),
        ]

    def vocabulary_response_envelope_cases(
        self,
    ) -> list[tuple[str, list[object], dict[str, object], int]]:
        """Issue #18: every still-reachable envelope, as a full probe failure case.

        Routing these through ``failure_cases()`` means the existing no-retry,
        sentinel-containment, contract-field and CLI suites cover them too. The
        Issue #20 ``data.voc`` group is excluded because it no longer stops at
        ``missing-voc``; it has its own end-to-end cases.
        """
        return [
            (
                f"vocabulary-envelope-{name}",
                [harness.HttpResponse(200, body)],
                self.expected(
                    "vocabulary", "schema", 200, 1, 1, "missing-voc", envelope
                ),
                1,
            )
            for name, body, envelope in missing_voc_envelope_cases()
        ]

    def failure_cases(self) -> list[tuple[str, list[object], dict[str, object], int]]:
        """(name, queued transport results, expected diagnostic, request count)."""
        valid = self.responses()
        cases: list[tuple[str, list[object], dict[str, object], int]] = [
            (
                "vocabulary-transport",
                [harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)],
                self.expected("vocabulary", "transport", None, 1, 0),
                1,
            ),
            (
                "vocabulary-transport-oserror",
                [OSError(TRANSPORT_EXCEPTION_SENTINEL)],
                self.expected("vocabulary", "transport", None, 1, 0),
                1,
            ),
            (
                "vocabulary-transport-safety",
                [harness.SafetyError(TRANSPORT_EXCEPTION_SENTINEL)],
                self.expected("vocabulary", "safety", None, 1, 0),
                1,
            ),
            (
                "vocabulary-non-response-object",
                [{"status": 200, SERVER_KEY_SENTINEL: SERVER_BODY_SENTINEL}],
                self.expected("vocabulary", "transport", None, 1, 0),
                1,
            ),
            (
                "vocabulary-out-of-range-status",
                [harness.HttpResponse(999, self.hostile_body())],
                self.expected("vocabulary", "transport", None, 1, 0),
                1,
            ),
            (
                "vocabulary-redirect",
                [harness.HttpResponse(302, self.hostile_body())],
                self.expected("vocabulary", "http-status", 302, 1, 1),
                1,
            ),
            (
                "vocabulary-schema-missing-voc",
                [harness.HttpResponse(200, self.hostile_body())],
                # The hostile body carries allowlisted ``error``/``message``
                # keys, so it classifies as business metadata; the sentinel
                # values behind them are never read or emitted.
                self.expected(
                    "vocabulary",
                    "schema",
                    200,
                    1,
                    1,
                    "missing-voc",
                    "business-error-like",
                ),
                1,
            ),
            (
                "vocabulary-schema-spelling-mismatch",
                self.responses(
                    vocabulary={"id": self.VOCABULARY_ID, "spelling": "otherword"}
                ),
                self.expected("vocabulary", "schema", 200, 1, 1, "spelling-mismatch"),
                1,
            ),
            (
                "vocabulary-response-rejected-401",
                [harness.TransportResponseError(401)],
                self.expected("vocabulary", "http-status", 401, 1, 1),
                1,
            ),
            (
                "vocabulary-response-rejected-without-status",
                [harness.TransportResponseError(None)],
                self.expected("vocabulary", "transport", None, 1, 0),
                1,
            ),
            (
                "interpretations-transport",
                [valid[0], harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)],
                self.expected("interpretations", "transport", None, 2, 1),
                2,
            ),
            (
                "interpretations-response-rejected-redirect",
                [valid[0], harness.TransportResponseError(302)],
                self.expected("interpretations", "http-status", 302, 2, 2),
                2,
            ),
            (
                "phrases-response-rejected-undecodable-success",
                [valid[0], valid[1], harness.TransportResponseError(200)],
                self.expected(
                    "phrases", "schema", 200, 3, 3, "other-reviewed-schema"
                ),
                3,
            ),
            (
                "interpretations-schema-not-an-array",
                self.responses(interpretations={"nested": SERVER_BODY_SENTINEL}),
                self.expected(
                    "interpretations", "schema", 200, 2, 2, "other-reviewed-schema"
                ),
                2,
            ),
            (
                "interpretations-schema-unknown-status",
                self.responses(
                    interpretations=[
                        self.interpretation_record(status=SERVER_BODY_SENTINEL)
                    ]
                ),
                self.expected(
                    "interpretations", "schema", 200, 2, 2, "other-reviewed-schema"
                ),
                2,
            ),
            (
                "phrases-transport",
                [
                    valid[0],
                    valid[1],
                    harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL),
                ],
                self.expected("phrases", "transport", None, 3, 2),
                3,
            ),
            (
                "phrases-schema-missing-highlight",
                self.responses(
                    phrases=[
                        {
                            "id": "INVALID_ISSUE14_PHRASE_ID",
                            "status": "PUBLISHED",
                            "phrase": SERVER_BODY_SENTINEL,
                        }
                    ]
                ),
                self.expected(
                    "phrases", "schema", 200, 3, 3, "other-reviewed-schema"
                ),
                3,
            ),
            (
                "phrases-schema-unsafe-id",
                self.responses(
                    phrases=[
                        {
                            "id": "../unsafe",
                            "status": "PUBLISHED",
                            "phrase": SERVER_BODY_SENTINEL,
                            "highlight": [],
                        }
                    ]
                ),
                self.expected(
                    "phrases", "schema", 200, 3, 3, "other-reviewed-schema"
                ),
                3,
            ),
        ]
        cases.extend(self.vocabulary_schema_reason_cases())
        cases.extend(self.vocabulary_response_envelope_cases())
        for status in (401, 403, 404, 429, 500, 503):
            cases.append(
                (
                    f"vocabulary-http-{status}",
                    [harness.HttpResponse(status, self.hostile_body())],
                    self.expected("vocabulary", "http-status", status, 1, 1),
                    1,
                )
            )
        for status in (401, 403, 429, 503):
            cases.append(
                (
                    f"interpretations-http-{status}",
                    [valid[0], harness.HttpResponse(status, self.hostile_body())],
                    self.expected("interpretations", "http-status", status, 2, 2),
                    2,
                )
            )
            cases.append(
                (
                    f"phrases-http-{status}",
                    [
                        valid[0],
                        valid[1],
                        harness.HttpResponse(status, self.hostile_body()),
                    ],
                    self.expected("phrases", "http-status", status, 3, 3),
                    3,
                )
            )
        return cases

    def run_failure(
        self,
        responses: list[object],
    ) -> tuple[harness.ReadOnlyProbeFailure, FakeTransport]:
        test_credential = self.probe_credential()
        transport = FakeTransport(list(responses))
        with self.assertRaises(harness.ReadOnlyProbeFailure) as context:
            harness.ReadOnlyProbeExecutor(transport).execute(
                test_credential,
                self.probe_gate(test_credential),
            )
        return context.exception, transport

    def rendered_failure(self, failure: harness.ReadOnlyProbeFailure) -> str:
        return "".join(
            (
                json.dumps(failure.safe_summary(), ensure_ascii=False),
                str(failure),
                repr(failure),
                str(failure.diagnostic),
                repr(failure.diagnostic),
                "".join(
                    traceback.format_exception(
                        type(failure), failure, failure.__traceback__
                    )
                ),
            )
        )

    def test_every_failure_point_reports_its_stage_class_status_and_counters(
        self,
    ) -> None:
        for name, responses, expected, request_count in self.failure_cases():
            with self.subTest(case=name):
                failure, transport = self.run_failure(responses)
                self.assertEqual(failure.safe_summary(), expected)
                self.assertEqual(len(transport.requests), request_count)

    def test_no_failure_point_retries_the_failed_get(self) -> None:
        for name, responses, expected, request_count in self.failure_cases():
            with self.subTest(case=name):
                failure, transport = self.run_failure(responses)
                methods = [request.method for request in transport.requests]
                paths = [request.path for request in transport.requests]
                self.assertEqual(methods, ["GET"] * request_count)
                self.assertEqual(len(set(paths)), len(paths))
                self.assertEqual(
                    failure.safe_summary()["requests_attempted"],
                    request_count,
                )
                self.assertEqual(expected["requests_attempted"], request_count)

    def test_no_sentinel_reaches_any_failure_representation(self) -> None:
        for name, responses, _expected, _count in self.failure_cases():
            with self.subTest(case=name):
                failure, _transport = self.run_failure(responses)
                rendered = self.rendered_failure(failure)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
                self.assertNotIn(ACCOUNT_LABEL, rendered)
                self.assertNotIn(self.VOCABULARY_ID, rendered)
                self.assertNotIn(self.PRIVATE_INTERPRETATION, rendered)
                self.assertNotIn(self.PRIVATE_PHRASE, rendered)
                self.assertIsNone(failure.__cause__)
                self.assertIsNone(failure.__context__)

    def run_cli(
        self,
        transport_factory: object,
    ) -> tuple[int, str, str]:
        test_credential = self.probe_credential()
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            exit_code = harness.main(
                self.cli_args(),
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: self.probe_gate(
                    test_credential
                ).expected_confirmation,
                transport_factory=transport_factory,
                stdin_isatty=lambda: True,
            )
        return exit_code, stdout.getvalue(), stderr.getvalue()

    def cli_diagnostic(self, stdout: str) -> dict[str, object]:
        """Parse the single sanitized JSON object printed after the preview."""
        decoder = json.JSONDecoder()
        index = stdout.index("{", stdout.index("}") + 1)
        diagnostic, _end = decoder.raw_decode(stdout[index:])
        return diagnostic

    def test_transport_construction_failure_is_transport_init_with_zero_requests(
        self,
    ) -> None:
        def failing_factory() -> harness.Transport:
            raise RuntimeError(TRANSPORT_EXCEPTION_SENTINEL)

        exit_code, stdout, stderr = self.run_cli(failing_factory)
        self.assertEqual(exit_code, 4)
        self.assertEqual(
            self.cli_diagnostic(stdout),
            self.expected("transport-init", "transport", None, 0, 0),
        )
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, stdout + stderr)

    def test_cli_prints_one_sanitized_object_for_every_failure_point(self) -> None:
        for name, responses, expected, request_count in self.failure_cases():
            with self.subTest(case=name):
                transport = FakeTransport(list(responses))
                exit_code, stdout, stderr = self.run_cli(lambda: transport)
                self.assertEqual(exit_code, 4)
                self.assertEqual(len(transport.requests), request_count)
                self.assertEqual(self.cli_diagnostic(stdout), expected)
                rendered = stdout + stderr
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
                self.assertNotIn(self.VOCABULARY_ID, rendered)
                self.assertNotIn(self.PRIVATE_INTERPRETATION, rendered)
                self.assertNotIn(self.PRIVATE_PHRASE, rendered)
                self.assertNotIn("Traceback", rendered)
                self.assertNotIn("Error", stderr)

    def test_redirect_reports_the_status_number_without_the_location(self) -> None:
        responses = [harness.HttpResponse(302, {"location": REDIRECT_LOCATION_SENTINEL})]
        failure, transport = self.run_failure(responses)
        self.assertEqual(
            failure.safe_summary(),
            self.expected("vocabulary", "http-status", 302, 1, 1),
        )
        self.assertEqual(len(transport.requests), 1)
        self.assertNotIn(REDIRECT_LOCATION_SENTINEL, self.rendered_failure(failure))

        transport = FakeTransport(
            [harness.HttpResponse(302, {"location": REDIRECT_LOCATION_SENTINEL})]
        )
        exit_code, stdout, stderr = self.run_cli(lambda: transport)
        self.assertEqual(exit_code, 4)
        self.assertEqual(len(transport.requests), 1)
        self.assertEqual(
            self.cli_diagnostic(stdout),
            self.expected("vocabulary", "http-status", 302, 1, 1),
        )
        self.assertNotIn(REDIRECT_LOCATION_SENTINEL, stdout + stderr)
        self.assertNotIn("redirect-target", stdout + stderr)

    def test_unknown_server_json_key_never_reaches_a_diagnostic(self) -> None:
        responses = [
            harness.HttpResponse(
                200,
                {
                    "voc": {"id": self.VOCABULARY_ID, "spelling": self.RETURNED_WORD},
                    SERVER_KEY_SENTINEL: {"nested": SERVER_BODY_SENTINEL},
                },
            ),
            harness.HttpResponse(
                200,
                {"interpretations": "not-an-array", SERVER_KEY_SENTINEL: {}},
            ),
        ]
        failure, transport = self.run_failure(responses)
        self.assertEqual(
            failure.safe_summary(),
            self.expected(
                "interpretations", "schema", 200, 2, 2, "other-reviewed-schema"
            ),
        )
        self.assertEqual(len(transport.requests), 2)
        rendered = self.rendered_failure(failure)
        self.assertNotIn(SERVER_KEY_SENTINEL, rendered)
        self.assertNotIn(SERVER_BODY_SENTINEL, rendered)

    def test_local_gate_rejection_is_a_safety_failure_with_no_request(self) -> None:
        test_credential = self.probe_credential()
        wrong_confirmation = harness._read_only_confirmation_for(
            ACCOUNT_LABEL,
            test_credential.fingerprint,
            "differentword",
        )
        transport = FakeTransport(self.responses())
        with self.assertRaises(harness.ReadOnlyProbeFailure) as context:
            harness.ReadOnlyProbeExecutor(transport).execute(
                test_credential,
                self.probe_gate(test_credential, confirmation=wrong_confirmation),
            )
        self.assertEqual(
            context.exception.safe_summary(),
            self.expected("transport-init", "safety", None, 0, 0),
        )
        self.assertEqual(transport.requests, [])

    def production_connection(
        self,
        status: object,
        *,
        body: bytes | None = None,
    ) -> type:
        """A fake http.client connection; the real socket layer is never used."""
        sentinel_body = body

        class FakeSocket:
            def settimeout(self, _timeout: float) -> None:
                return None

        class FakeResponse:
            def __init__(self) -> None:
                self.status = status
                self.reads = 0

            def read(self, _limit: int) -> bytes:
                self.reads += 1
                if sentinel_body is None:
                    raise AssertionError("this response body must not be read")
                return sentinel_body

        class FakeConnection:
            instances: list["FakeConnection"] = []

            def __init__(self, host: str, *, timeout: float) -> None:
                self.host = host
                self.timeout = timeout
                self.sock: FakeSocket | None = None
                self.response = FakeResponse()
                self.closed = False
                self.__class__.instances.append(self)

            def connect(self) -> None:
                self.sock = FakeSocket()

            def request(self, *_args: object, **_kwargs: object) -> None:
                return None

            def getresponse(self) -> FakeResponse:
                return self.response

            def close(self) -> None:
                self.closed = True

        return FakeConnection

    def test_production_transport_keeps_only_the_numeric_rejected_status(self) -> None:
        request = harness.HttpRequest(
            "GET",
            "/open/api/v1/vocabulary?spelling=sampleword",
        )
        test_credential = self.probe_credential()
        html_error = (
            f"<html><body>{SERVER_BODY_SENTINEL} {SERVER_MESSAGE_SENTINEL}"
            "</body></html>"
        ).encode("utf-8")
        cases = (
            ("undecodable-401", 401, html_error, 401),
            ("undecodable-503", 503, html_error, 503),
            ("undecodable-success", 200, html_error, 200),
            ("redirect", 302, None, 302),
            ("non-numeric-status", "401 Unauthorized", None, None),
        )
        for name, status, body, expected_status in cases:
            with self.subTest(case=name):
                connection = self.production_connection(status, body=body)
                with mock.patch.object(
                    harness.http.client, "HTTPSConnection", connection
                ), self.assertRaises(harness.TransportError) as context:
                    harness.ProductionHttpTransport().send(request, test_credential)
                rejected = context.exception
                if expected_status is None:
                    self.assertNotIsInstance(rejected, harness.TransportResponseError)
                else:
                    self.assertIsInstance(rejected, harness.TransportResponseError)
                    self.assertEqual(rejected.http_status, expected_status)
                self.assertTrue(connection.instances[-1].closed)
                rendered = f"{rejected}{rejected!r}"
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_rejected_response_subclass_leaves_the_write_path_contract(self) -> None:
        self.assertTrue(
            issubclass(harness.TransportResponseError, harness.TransportError)
        )
        rejected = harness.TransportResponseError(403)
        self.assertIsInstance(rejected, harness.TransportError)
        self.assertEqual(rejected.http_status, 403)
        for unusable in (None, True, "403", 42, 1000, -1):
            with self.subTest(status=unusable):
                self.assertIsNone(harness.TransportResponseError(unusable).http_status)

    def production_connection_factory(
        self,
        behaviors: list[dict[str, object]],
    ) -> tuple[type, dict[str, object]]:
        """Fake `http.client` connection factory; no real socket is ever used.

        Each behavior describes one sequential request. ``connect_error``,
        ``request_error`` and ``getresponse_error`` raise at that phase; otherwise
        ``status`` and ``body`` drive the response. A ``body`` that is an
        exception raises during the body read, and a ``body`` of ``None`` asserts
        that this response body must never be read at all.
        """
        state: dict[str, object] = {
            "connections": 0,
            "requests": 0,
            "reads": 0,
            "closed": 0,
            "header_names": [],
            "paths": [],
        }

        class FakeSocket:
            def settimeout(self, _timeout: float) -> None:
                return None

        class FakeResponse:
            def __init__(self, behavior: dict[str, object]) -> None:
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
                self.timeout = timeout
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
                headers: dict[str, str] | None = None,
            ) -> None:
                state["requests"] += 1  # type: ignore[operator]
                state["paths"].append((method, path))  # type: ignore[union-attr]
                # Header names only: a header value would hold the credential.
                state["header_names"].append(  # type: ignore[union-attr]
                    tuple(sorted(headers or {}))
                )
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

    def production_body(self, payload: dict[str, object]) -> bytes:
        return json.dumps(payload, ensure_ascii=False).encode("utf-8")

    def production_vocabulary_body(self) -> bytes:
        return self.production_body(
            {"voc": {"id": self.VOCABULARY_ID, "spelling": self.RETURNED_WORD}}
        )

    def production_interpretations_body(self) -> bytes:
        return self.production_body(
            {"interpretations": [self.interpretation_record()]}
        )

    def run_production_probe(
        self,
        behaviors: list[dict[str, object]],
    ) -> tuple[harness.ReadOnlyProbeFailure, dict[str, object]]:
        test_credential = self.probe_credential()
        connection, state = self.production_connection_factory(behaviors)
        with mock.patch.object(
            harness.http.client, "HTTPSConnection", connection
        ), self.assertRaises(harness.ReadOnlyProbeFailure) as context:
            harness.ReadOnlyProbeExecutor(harness.ProductionHttpTransport()).execute(
                test_credential,
                self.probe_gate(test_credential),
            )
        return context.exception, state

    def io_errors(self) -> tuple[tuple[str, BaseException], ...]:
        """Transport-style body-read failures, each with a private sentinel."""
        return (
            ("timeout", TimeoutError(f"{PRODUCTION_IO_SENTINEL}-timeout")),
            ("socket-timeout", socket.timeout(f"{PRODUCTION_IO_SENTINEL}-socket")),
            (
                "incomplete-read",
                http.client.IncompleteRead(
                    f"{PRODUCTION_IO_SENTINEL}-partial".encode("utf-8"), 4096
                ),
            ),
            (
                "connection-reset",
                ConnectionResetError(f"{PRODUCTION_IO_SENTINEL}-reset"),
            ),
            ("ssl-failure", ssl.SSLError(f"{PRODUCTION_IO_SENTINEL}-ssl")),
            ("remote-disconnect", OSError(f"{PRODUCTION_IO_SENTINEL}-disconnect")),
        )

    def test_body_read_io_failure_after_status_stays_transport(self) -> None:
        """Issue #14 review blocker: a body-read failure is never `schema`."""
        for name, error in self.io_errors():
            for status in (200, 401):
                with self.subTest(error=name, status=status):
                    failure, state = self.run_production_probe(
                        [{"status": status, "body": error}]
                    )
                    self.assertEqual(
                        failure.safe_summary(),
                        self.expected("vocabulary", "transport", None, 1, 0),
                    )
                    # Exactly one connection, one request, one read: no retry.
                    self.assertEqual(state["connections"], 1)
                    self.assertEqual(state["requests"], 1)
                    self.assertEqual(state["reads"], 1)
                    self.assertEqual(state["closed"], 1)
                    self.assertEqual(
                        state["paths"],
                        [("GET", "/open/api/v1/vocabulary?spelling=sampleword")],
                    )
                    self.assertEqual(
                        state["header_names"], [("Accept", "Authorization")]
                    )
                    rendered = self.rendered_failure(failure)
                    for sentinel in SENTINELS:
                        self.assertNotIn(sentinel, rendered)
                    self.assertIsNone(failure.__cause__)
                    self.assertIsNone(failure.__context__)

    def test_connect_request_and_getresponse_failures_stay_transport(self) -> None:
        cases = (
            ("connect", "connect_error", 0, 0),
            ("request", "request_error", 1, 0),
            ("getresponse", "getresponse_error", 1, 0),
        )
        for name, key, expected_requests, expected_reads in cases:
            with self.subTest(phase=name):
                failure, state = self.run_production_probe(
                    [
                        {
                            "status": 200,
                            "body": self.production_vocabulary_body(),
                            key: OSError(f"{PRODUCTION_IO_SENTINEL}-{name}"),
                        }
                    ]
                )
                self.assertEqual(
                    failure.safe_summary(),
                    self.expected("vocabulary", "transport", None, 1, 0),
                )
                self.assertEqual(state["connections"], 1)
                self.assertEqual(state["requests"], expected_requests)
                self.assertEqual(state["reads"], expected_reads)
                self.assertEqual(state["closed"], 1)
                rendered = self.rendered_failure(failure)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_completely_received_body_rejections_keep_the_numeric_status(self) -> None:
        oversized = b'{"voc":"' + b"P" * (harness.MAX_RESPONSE_BYTES + 16) + b'"}'
        hostile_json = self.production_body(
            {
                SERVER_KEY_SENTINEL: SERVER_BODY_SENTINEL,
                "message": SERVER_MESSAGE_SENTINEL,
            }
        )
        cases = (
            (
                "success-invalid-json",
                200,
                f"<html>{SERVER_BODY_SENTINEL}</html>".encode("utf-8"),
                self.expected(
                    "vocabulary", "schema", 200, 1, 1, "body-invalid-json"
                ),
            ),
            (
                "success-not-an-object",
                200,
                self.production_body([SERVER_BODY_SENTINEL]),  # type: ignore[arg-type]
                self.expected(
                    "vocabulary", "schema", 200, 1, 1, "body-not-object"
                ),
            ),
            (
                "success-invalid-utf8",
                200,
                b"\xff\xfe" + SERVER_BODY_SENTINEL.encode("utf-16"),
                self.expected(
                    "vocabulary", "schema", 200, 1, 1, "body-invalid-utf8"
                ),
            ),
            (
                "success-oversized",
                200,
                oversized,
                self.expected(
                    "vocabulary", "schema", 200, 1, 1, "body-too-large"
                ),
            ),
            (
                "unauthorized-invalid-json",
                401,
                f"<html>{SERVER_BODY_SENTINEL}</html>".encode("utf-8"),
                self.expected("vocabulary", "http-status", 401, 1, 1),
            ),
            (
                "unauthorized-valid-json",
                401,
                hostile_json,
                self.expected("vocabulary", "http-status", 401, 1, 1),
            ),
            (
                "unavailable-valid-json",
                503,
                hostile_json,
                self.expected("vocabulary", "http-status", 503, 1, 1),
            ),
        )
        for name, status, body, expected in cases:
            with self.subTest(case=name):
                failure, state = self.run_production_probe(
                    [{"status": status, "body": body}]
                )
                self.assertEqual(failure.safe_summary(), expected)
                self.assertEqual(state["connections"], 1)
                self.assertEqual(state["reads"], 1)
                rendered = self.rendered_failure(failure)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)

    def test_production_redirect_keeps_the_status_and_never_reads_the_body(
        self,
    ) -> None:
        for status in (301, 302, 307):
            with self.subTest(status=status):
                # body=None makes any read attempt fail the test outright.
                failure, state = self.run_production_probe(
                    [{"status": status, "body": None}]
                )
                self.assertEqual(
                    failure.safe_summary(),
                    self.expected("vocabulary", "http-status", status, 1, 1),
                )
                self.assertEqual(state["reads"], 0)
                self.assertEqual(state["connections"], 1)
                rendered = self.rendered_failure(failure)
                self.assertNotIn(REDIRECT_LOCATION_SENTINEL, rendered)
                self.assertNotIn("redirect-target", rendered)

    def test_body_io_failure_on_a_later_get_keeps_the_earlier_counters(self) -> None:
        read_error = TimeoutError(f"{PRODUCTION_IO_SENTINEL}-late")
        interpretations_failure, state = self.run_production_probe(
            [
                {"status": 200, "body": self.production_vocabulary_body()},
                {"status": 200, "body": read_error},
            ]
        )
        self.assertEqual(
            interpretations_failure.safe_summary(),
            self.expected("interpretations", "transport", None, 2, 1),
        )
        self.assertEqual(state["connections"], 2)
        self.assertEqual(state["reads"], 2)

        phrases_failure, state = self.run_production_probe(
            [
                {"status": 200, "body": self.production_vocabulary_body()},
                {"status": 200, "body": self.production_interpretations_body()},
                {"status": 200, "body": ConnectionResetError(read_error.args[0])},
            ]
        )
        self.assertEqual(
            phrases_failure.safe_summary(),
            self.expected("phrases", "transport", None, 3, 2),
        )
        self.assertEqual(state["connections"], 3)
        self.assertEqual(state["reads"], 3)
        for failure in (interpretations_failure, phrases_failure):
            rendered = self.rendered_failure(failure)
            for sentinel in SENTINELS:
                self.assertNotIn(sentinel, rendered)

    def test_production_body_io_failure_stays_contained_through_the_cli(self) -> None:
        connection, state = self.production_connection_factory(
            [
                {
                    "status": 200,
                    "body": TimeoutError(f"{PRODUCTION_IO_SENTINEL}-cli"),
                }
            ]
        )
        with mock.patch.object(harness.http.client, "HTTPSConnection", connection):
            exit_code, stdout, stderr = self.run_cli(harness.ProductionHttpTransport)
        self.assertEqual(exit_code, 4)
        self.assertEqual(
            self.cli_diagnostic(stdout),
            self.expected("vocabulary", "transport", None, 1, 0),
        )
        self.assertEqual(state["connections"], 1)
        self.assertEqual(state["reads"], 1)
        rendered = stdout + stderr
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        self.assertNotIn("Traceback", rendered)
        self.assertEqual(stderr, "")

    def test_unclassified_internal_failure_still_stays_contained(self) -> None:
        test_credential = self.probe_credential()
        transport = FakeTransport(self.responses())
        with mock.patch.object(
            harness.ReadOnlyProbeExecutor,
            "_execute",
            side_effect=RuntimeError(TRANSPORT_EXCEPTION_SENTINEL),
        ), self.assertRaises(harness.ReadOnlyProbeFailure) as context:
            harness.ReadOnlyProbeExecutor(transport).execute(
                test_credential,
                self.probe_gate(test_credential),
            )
        failure = context.exception
        self.assertEqual(
            failure.safe_summary(),
            self.expected("transport-init", "safety", None, 0, 0),
        )
        self.assertEqual(transport.requests, [])
        self.assertIsNone(failure.__cause__)
        self.assertIsNone(failure.__context__)
        self.assertNotIn(
            TRANSPORT_EXCEPTION_SENTINEL, self.rendered_failure(failure)
        )

        transport = FakeTransport(self.responses())
        with mock.patch.object(
            harness.ReadOnlyProbeExecutor,
            "_execute",
            side_effect=RuntimeError(TRANSPORT_EXCEPTION_SENTINEL),
        ):
            exit_code, stdout, stderr = self.run_cli(lambda: transport)
        self.assertEqual(exit_code, 4)
        self.assertEqual(
            self.cli_diagnostic(stdout),
            self.expected("transport-init", "safety", None, 0, 0),
        )
        self.assertNotIn(TRANSPORT_EXCEPTION_SENTINEL, stdout + stderr)

    def test_diagnostic_rejects_every_out_of_contract_combination(self) -> None:
        valid = dict(
            failure_stage="vocabulary",
            failure_class="http-status",
            http_status=403,
            requests_attempted=1,
            requests_completed=1,
        )
        self.assertEqual(
            harness.ReadOnlyFailureDiagnostic(**valid).safe_summary()["http_status"],
            403,
        )
        rejected = (
            {"failure_stage": "vocabulary-get"},
            {"failure_stage": "TypeError"},
            {"failure_class": "ssl-error"},
            {"failure_class": "http.client.RemoteDisconnected"},
            {"failure_class": "transport", "http_status": 403},
            {"failure_class": "safety", "http_status": 200},
            {"failure_class": "schema", "http_status": 403},
            {"http_status": 200},
            {"http_status": None},
            {"http_status": 4030},
            {"http_status": True},
            {"http_status": "403"},
            {"requests_attempted": 4, "requests_completed": 4},
            {"requests_attempted": -1, "requests_completed": -1},
            {"requests_attempted": 1, "requests_completed": 2},
            {"requests_attempted": True, "requests_completed": True},
            {"failure_stage": "transport-init"},
            {"requests_completed": 0},
            # Issue #16: only a schema failure may carry a schema reason.
            {"schema_reason": "missing-voc"},
            {"failure_class": "schema", "http_status": 200, "schema_reason": None},
            {
                "failure_class": "schema",
                "http_status": 200,
                "schema_reason": INJECTED_REASON_SENTINEL,
            },
            {"failure_class": "schema", "http_status": 200, "schema_reason": ""},
            {"failure_class": "schema", "http_status": 200, "schema_reason": 7},
            {
                "failure_class": "schema",
                "http_status": 200,
                "schema_reason": ["missing-voc"],
            },
            {
                "failure_class": "transport",
                "http_status": None,
                "requests_completed": 0,
                "schema_reason": "missing-voc",
            },
        )
        for override in rejected:
            with self.subTest(override=tuple(override)):
                with self.assertRaises(harness.SafetyError):
                    harness.ReadOnlyFailureDiagnostic(**{**valid, **override})
        with self.assertRaises(harness.SafetyError):
            harness.ReadOnlyProbeFailure("vocabulary")  # type: ignore[arg-type]

    def test_stage_and_class_enums_stay_project_owned_and_finite(self) -> None:
        self.assertEqual(
            harness.READ_ONLY_FAILURE_STAGES,
            ("transport-init", "vocabulary", "interpretations", "phrases"),
        )
        self.assertEqual(
            harness.READ_ONLY_FAILURE_CLASSES,
            ("transport", "http-status", "schema", "safety"),
        )
        observed_stages = set()
        observed_classes = set()
        for _name, responses, expected, _count in self.failure_cases():
            observed_stages.add(expected["failure_stage"])
            observed_classes.add(expected["failure_class"])
            failure, _transport = self.run_failure(responses)
            self.assertIn(
                failure.safe_summary()["failure_stage"],
                harness.READ_ONLY_FAILURE_STAGES,
            )
            self.assertIn(
                failure.safe_summary()["failure_class"],
                harness.READ_ONLY_FAILURE_CLASSES,
            )
        self.assertEqual(
            observed_stages, {"vocabulary", "interpretations", "phrases"}
        )
        self.assertEqual(
            observed_classes, {"transport", "http-status", "schema", "safety"}
        )

    def test_successful_probe_output_is_unchanged_by_the_diagnostic_patch(self) -> None:
        transport = FakeTransport(self.responses())
        exit_code, stdout, stderr = self.run_cli(lambda: transport)
        self.assertEqual(exit_code, 0)
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(stderr, "")
        result = self.cli_diagnostic(stdout)
        self.assertEqual(result["mode"], "read-only-probe")
        self.assertEqual(result["interpretation_count"], 1)
        self.assertEqual(result["phrase_count"], 1)
        self.assertEqual(
            result["response_statuses"],
            {"vocabulary": 200, "interpretations": 200, "phrases": 200},
        )
        for absent in ("status", "failure_stage", "failure_class", "http_status"):
            self.assertNotIn(absent, result)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, stdout + stderr)

    # ------------------------------------------------------------------
    # Issue #16: pinpoint which reviewed checkpoint a live 200 body violated.
    # Every case below is fake/no-network; no real credential is read and no
    # Maimemo request is ever sent.
    # ------------------------------------------------------------------

    def test_every_vocabulary_schema_reason_is_reported_exactly(self) -> None:
        for name, responses, expected, request_count in (
            self.vocabulary_schema_reason_cases()
        ):
            with self.subTest(case=name):
                failure, transport = self.run_failure(responses)
                summary = failure.safe_summary()
                self.assertEqual(summary, expected)
                # The live shape we are diagnosing: one complete HTTP 200 on the
                # first GET, no follow-up request, no retry.
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["failure_class"], "schema")
                self.assertEqual(summary["http_status"], 200)
                self.assertEqual(summary["requests_attempted"], 1)
                self.assertEqual(summary["requests_completed"], 1)
                self.assertEqual(request_count, 1)
                self.assertEqual(len(transport.requests), 1)
                self.assertEqual(transport.requests[0].method, "GET")
                self.assertIn(
                    summary["schema_reason"], harness.READ_ONLY_SCHEMA_REASONS
                )
                rendered = self.rendered_failure(failure)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
                self.assertNotIn(self.VOCABULARY_ID, rendered)
                self.assertNotIn(self.RETURNED_WORD, rendered)
                self.assertNotIn(ACCOUNT_LABEL, rendered)
                self.assertIsNone(failure.__cause__)
                self.assertIsNone(failure.__context__)

    def test_every_vocabulary_schema_reason_is_covered_by_a_case(self) -> None:
        observed = {
            expected["schema_reason"]
            for _name, _responses, expected, _count in (
                self.vocabulary_schema_reason_cases()
            )
        }
        self.assertEqual(observed, set(harness.READ_ONLY_SCHEMA_REASONS))

    def test_punctuated_string_voc_id_is_local_policy_and_never_echoed(self) -> None:
        """The hypothesis the next owner-authorized run must prove or disprove.

        A voc id that exists, is a non-empty string and would satisfy the
        first-party ``id: string`` contract, but not this project's unchanged
        path-segment policy, must be named `voc-id-local-policy` and must not be
        echoed anywhere.
        """
        body = {
            "voc": {
                "id": VOC_ID_PUNCTUATION_SENTINEL,
                "spelling": self.RETURNED_WORD,
            }
        }
        expected = self.expected(
            "vocabulary", "schema", 200, 1, 1, "voc-id-local-policy"
        )

        failure, transport = self.run_failure([harness.HttpResponse(200, body)])
        self.assertEqual(failure.safe_summary(), expected)
        self.assertEqual(len(transport.requests), 1)
        rendered = self.rendered_failure(failure)
        self.assertNotIn(VOC_ID_PUNCTUATION_SENTINEL, rendered)
        # Not the whole id, and not any distinctive fragment of it either.
        for fragment in ("PRIVATE.ISSUE16", "/VOC", "ID+SENTINEL"):
            self.assertNotIn(fragment, rendered)
        self.assertNotIn(
            hashlib.sha256(VOC_ID_PUNCTUATION_SENTINEL.encode("utf-8")).hexdigest()[
                :16
            ],
            rendered,
        )
        self.assertIsNone(failure.__cause__)
        self.assertIsNone(failure.__context__)

        transport = FakeTransport([harness.HttpResponse(200, body)])
        exit_code, stdout, stderr = self.run_cli(lambda: transport)
        self.assertEqual(exit_code, 4)
        self.assertEqual(len(transport.requests), 1)
        self.assertEqual(self.cli_diagnostic(stdout), expected)
        rendered = stdout + stderr
        self.assertNotIn(VOC_ID_PUNCTUATION_SENTINEL, rendered)
        for fragment in ("PRIVATE.ISSUE16", "/VOC", "ID+SENTINEL"):
            self.assertNotIn(fragment, rendered)
        self.assertNotIn("Traceback", rendered)

    def test_vocabulary_id_acceptance_policy_is_unchanged(self) -> None:
        """Issue #16 diagnoses the mismatch; it must not relax the rule."""
        with self.assertRaises(harness.SafetyError):
            harness._safe_record_id(VOC_ID_PUNCTUATION_SENTINEL, "vocabulary id")
        for accepted in (self.VOCABULARY_ID, "abc", "A-b_9"):
            with self.subTest(voc_id=accepted):
                self.assertEqual(
                    harness._safe_record_id(accepted, "vocabulary id"), accepted
                )
                self.assertEqual(
                    harness._probe_vocabulary_record_id(accepted), accepted
                )
        for rejected in (VOC_ID_PUNCTUATION_SENTINEL, "../unsafe", "a b", "a/b", "a.b"):
            with self.subTest(voc_id=rejected):
                with self.assertRaises(harness.SchemaReasonError) as context:
                    harness._probe_vocabulary_record_id(rejected)
                self.assertEqual(
                    context.exception.schema_reason, "voc-id-local-policy"
                )
                self.assertNotIn(
                    rejected, f"{context.exception}{context.exception!r}"
                )

    def test_schema_reason_enum_stays_closed_and_project_owned(self) -> None:
        self.assertEqual(
            harness.READ_ONLY_SCHEMA_REASONS,
            (
                "body-invalid-utf8",
                "body-invalid-json",
                "body-not-object",
                "body-too-large",
                "missing-voc",
                "voc-not-object",
                "voc-id-missing-or-not-string",
                "voc-id-empty",
                "voc-id-local-policy",
                "spelling-missing-or-not-string",
                "spelling-local-policy",
                "spelling-mismatch",
                "top-level-response-policy",
                "other-reviewed-schema",
            ),
        )
        self.assertEqual(
            len(set(harness.READ_ONLY_SCHEMA_REASONS)),
            len(harness.READ_ONLY_SCHEMA_REASONS),
        )
        # An equal-but-distinct string is replaced by the module-owned constant,
        # so no externally built string object can ever be emitted.
        equal_copy = "".join(["missing", "-", "voc"])
        self.assertIsNot(equal_copy, harness.SCHEMA_REASON_MISSING_VOC)
        emitted = harness.ReadOnlyFailureDiagnostic(
            failure_stage="vocabulary",
            failure_class="schema",
            http_status=200,
            requests_attempted=1,
            requests_completed=1,
            schema_reason=equal_copy,
            response_envelope="unknown-object",
        ).schema_reason
        self.assertIs(emitted, harness.SCHEMA_REASON_MISSING_VOC)

    def test_schema_reason_is_null_exactly_for_non_schema_failures(self) -> None:
        for name, responses, expected, _count in self.failure_cases():
            with self.subTest(case=name):
                summary = self.run_failure(responses)[0].safe_summary()
                self.assertEqual(summary, expected)
                if summary["failure_class"] == "schema":
                    self.assertIn(
                        summary["schema_reason"], harness.READ_ONLY_SCHEMA_REASONS
                    )
                else:
                    self.assertIn(
                        summary["failure_class"],
                        ("transport", "http-status", "safety"),
                    )
                    self.assertIsNone(summary["schema_reason"])

    def test_failure_diagnostic_exposes_only_the_contract_fields(self) -> None:
        for name, responses, _expected, _count in self.failure_cases():
            with self.subTest(case=name):
                self.assertEqual(
                    set(self.run_failure(responses)[0].safe_summary()),
                    {
                        "mode",
                        "status",
                        "failure_stage",
                        "failure_class",
                        "http_status",
                        "schema_reason",
                        "response_envelope",
                        "requests_attempted",
                        "requests_completed",
                    },
                )

    def test_externally_supplied_schema_reason_never_escapes(self) -> None:
        class HostileRejection(harness.TransportResponseError):
            def __init__(self) -> None:
                super().__init__(200)
                self.schema_reason = INJECTED_REASON_SENTINEL

        class HostileSchemaError(harness.SafetyError):
            def __init__(self) -> None:
                super().__init__(SERVER_MESSAGE_SENTINEL)
                self.schema_reason = SERVER_BODY_SENTINEL

        self.assertIsNone(
            harness.TransportResponseError(200, INJECTED_REASON_SENTINEL).schema_reason
        )
        self.assertEqual(
            harness._schema_reason_of(HostileSchemaError()), "other-reviewed-schema"
        )
        with self.assertRaises(harness.SafetyError):
            harness.SchemaReasonError(INJECTED_REASON_SENTINEL, "unused message")

        failure, transport = self.run_failure([HostileRejection()])
        self.assertEqual(
            failure.safe_summary(),
            self.expected(
                "vocabulary", "schema", 200, 1, 1, "other-reviewed-schema"
            ),
        )
        self.assertEqual(len(transport.requests), 1)
        rendered = self.rendered_failure(failure)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)

    def test_body_io_failures_keep_transport_class_with_no_schema_reason(self) -> None:
        """Issue #16 must not regress the PR #15 body-I/O repair."""
        for name, error in self.io_errors():
            for status in (200, 401):
                with self.subTest(error=name, status=status):
                    failure, state = self.run_production_probe(
                        [{"status": status, "body": error}]
                    )
                    summary = failure.safe_summary()
                    self.assertEqual(summary["failure_class"], "transport")
                    self.assertIsNone(summary["schema_reason"])
                    self.assertIsNone(summary["http_status"])
                    self.assertEqual(summary["requests_completed"], 0)
                    self.assertEqual(state["reads"], 1)

    def test_successful_probe_summary_never_gains_a_schema_reason(self) -> None:
        transport = FakeTransport(self.responses())
        exit_code, stdout, stderr = self.run_cli(lambda: transport)
        self.assertEqual(exit_code, 0)
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(stderr, "")
        result = self.cli_diagnostic(stdout)
        self.assertNotIn("schema_reason", result)
        self.assertNotIn("schema_reason", stdout)
        for reason in harness.READ_ONLY_SCHEMA_REASONS:
            self.assertNotIn(reason, stdout)

    def test_fake_token_is_absent_from_every_success_and_failure_output(self) -> None:
        transport = FakeTransport(self.responses())
        _exit_code, stdout, stderr = self.run_cli(lambda: transport)
        self.assertNotIn(FAKE_TOKEN, stdout + stderr)
        for name, responses, _expected, _count in self.failure_cases():
            with self.subTest(case=name):
                _code, failure_stdout, failure_stderr = self.run_cli(
                    lambda responses=responses: FakeTransport(list(responses))
                )
                self.assertNotIn(FAKE_TOKEN, failure_stdout + failure_stderr)

        def failing_factory() -> harness.Transport:
            raise RuntimeError(FAKE_TOKEN)

        _code, init_stdout, init_stderr = self.run_cli(failing_factory)
        self.assertNotIn(FAKE_TOKEN, init_stdout + init_stderr)


class RecordingMapping(Mapping):
    """A mapping that records every key lookup and every full enumeration.

    It proves the Issue #18 classifier reads only the allowlisted key names and
    never walks the server's own key set.
    """

    def __init__(self, data: Mapping, log: list[object]) -> None:
        self._data = dict(data)
        self._log = log

    def __getitem__(self, key: object) -> object:
        self._log.append(key)
        value = self._data[key]
        # Wrap nested objects too, so lookups below the top level are recorded.
        if isinstance(value, Mapping):
            return RecordingMapping(value, self._log)
        return value

    def __contains__(self, key: object) -> bool:
        self._log.append(key)
        return key in self._data

    def __iter__(self) -> Iterator:
        self._log.append(ENUMERATION_MARKER)
        return iter(self._data)

    def __len__(self) -> int:
        return len(self._data)


ENUMERATION_MARKER = "<the classifier enumerated the server key set>"


class HostileMapping(Mapping):
    """A mapping whose every access raises with a private sentinel message."""

    def __getitem__(self, key: object) -> object:
        raise RuntimeError(ENVELOPE_VALUE_SENTINEL)

    def __contains__(self, key: object) -> bool:
        raise RuntimeError(ENVELOPE_VALUE_SENTINEL)

    def __iter__(self) -> Iterator:
        raise RuntimeError(ENVELOPE_VALUE_SENTINEL)

    def __len__(self) -> int:
        raise RuntimeError(ENVELOPE_VALUE_SENTINEL)


class Issue18ResponseEnvelopeTests(ReadOnlyProbeFixtures, unittest.TestCase):
    """Issue #18: classify where an apparent vocabulary record lives.

    The third owner-authorized run returned a complete HTTP 200 JSON object with
    no documented top-level ``voc``. These cases reproduce that shape offline
    with fake transports under the process-level no-network guard: no real
    credential is read and no Maimemo request is ever sent.
    """

    def issue14_suite(self) -> Issue14ReadOnlyDiagnosticTests:
        """Reuse the Issue #14 case table and production-probe fixtures verbatim."""
        return Issue14ReadOnlyDiagnosticTests()

    def run_failure(
        self,
        responses: list[object],
    ) -> tuple[harness.ReadOnlyProbeFailure, FakeTransport]:
        test_credential = self.probe_credential()
        transport = FakeTransport(list(responses))
        with self.assertRaises(harness.ReadOnlyProbeFailure) as context:
            harness.ReadOnlyProbeExecutor(transport).execute(
                test_credential,
                self.probe_gate(test_credential),
            )
        return context.exception, transport

    def rendered_failure(self, failure: harness.ReadOnlyProbeFailure) -> str:
        return "".join(
            (
                json.dumps(failure.safe_summary(), ensure_ascii=False),
                str(failure),
                repr(failure),
                str(failure.diagnostic),
                repr(failure.diagnostic),
                repr(failure.__cause__),
                repr(failure.__context__),
                "".join(
                    traceback.format_exception(
                        type(failure), failure, failure.__traceback__
                    )
                ),
            )
        )

    def run_cli(self, transport: FakeTransport) -> tuple[int, str, str]:
        test_credential = self.probe_credential()
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            exit_code = harness.main(
                [
                    "read-only-probe",
                    "--word",
                    self.WORD,
                    "--account-label",
                    ACCOUNT_LABEL,
                    "--allow-network",
                ],
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: self.probe_gate(
                    test_credential
                ).expected_confirmation,
                transport_factory=lambda: transport,
                stdin_isatty=lambda: True,
            )
        return exit_code, stdout.getvalue(), stderr.getvalue()

    def cli_diagnostic(self, stdout: str) -> dict[str, object]:
        decoder = json.JSONDecoder()
        index = stdout.index("{", stdout.index("}") + 1)
        diagnostic, _end = decoder.raw_decode(stdout[index:])
        return diagnostic

    # ------------------------------------------------------------------
    # The closed enum itself
    # ------------------------------------------------------------------

    def test_response_envelope_enum_stays_closed_and_project_owned(self) -> None:
        self.assertEqual(
            harness.READ_ONLY_RESPONSE_ENVELOPES,
            (
                "direct-voc-object",
                "direct-vocabulary-object",
                "data-voc-wrapper",
                "data-vocabulary-object",
                "result-voc-wrapper",
                "result-vocabulary-object",
                "vocabulary-wrapper",
                "business-error-like",
                "unknown-object",
            ),
        )
        self.assertEqual(
            len(set(harness.READ_ONLY_RESPONSE_ENVELOPES)),
            len(harness.READ_ONLY_RESPONSE_ENVELOPES),
        )
        # An equal-but-distinct string is replaced by the module-owned constant,
        # so no externally built string object can ever be emitted.
        equal_copy = "".join(["unknown", "-", "object"])
        self.assertIsNot(equal_copy, harness.RESPONSE_ENVELOPE_UNKNOWN_OBJECT)
        emitted = harness.ReadOnlyFailureDiagnostic(
            failure_stage="vocabulary",
            failure_class="schema",
            http_status=200,
            requests_attempted=1,
            requests_completed=1,
            schema_reason="missing-voc",
            response_envelope=equal_copy,
        ).response_envelope
        self.assertIs(emitted, harness.RESPONSE_ENVELOPE_UNKNOWN_OBJECT)

    def test_documented_precedence_matches_the_implemented_order(self) -> None:
        self.assertEqual(
            tuple(
                envelope
                for envelope, _key, _descend in (
                    harness._RESPONSE_ENVELOPE_LOCATION_RULES
                )
            ),
            (
                "direct-voc-object",
                "direct-vocabulary-object",
                "data-voc-wrapper",
                "data-vocabulary-object",
                "result-voc-wrapper",
                "result-vocabulary-object",
                "vocabulary-wrapper",
            ),
        )
        # Business metadata is only ever the last resort before unknown-object.
        self.assertEqual(
            harness.READ_ONLY_RESPONSE_ENVELOPES[-2:],
            ("business-error-like", "unknown-object"),
        )

    def test_inspected_key_allowlist_is_small_explicit_and_closed(self) -> None:
        self.assertEqual(
            harness.RESPONSE_ENVELOPE_INSPECTED_KEYS,
            (
                "voc",
                "id",
                "spelling",
                "data",
                "result",
                "vocabulary",
                "code",
                "message",
                "error",
                "status",
                "success",
            ),
        )
        self.assertEqual(
            harness.RESPONSE_ENVELOPE_BUSINESS_KEYS,
            ("code", "message", "error", "status", "success"),
        )

    def test_every_envelope_constant_is_classified_by_a_case(self) -> None:
        observed = {envelope for _n, _b, envelope in vocabulary_envelope_cases()}
        observed.add(
            harness._classify_vocabulary_response_envelope(
                {"voc": envelope_record()}
            )
        )
        self.assertEqual(observed, set(harness.READ_ONLY_RESPONSE_ENVELOPES))

    def test_classifier_returns_only_project_owned_constants(self) -> None:
        bodies: list[object] = [body for _n, body, _e in vocabulary_envelope_cases()]
        bodies.extend(
            [
                {"voc": envelope_record()},
                {"voc": ENVELOPE_VALUE_SENTINEL},
                None,
                [ENVELOPE_VALUE_SENTINEL],
                ENVELOPE_VALUE_SENTINEL,
                7,
                HostileMapping(),
            ]
        )
        for body in bodies:
            with self.subTest(body=type(body).__name__):
                envelope = harness._classify_vocabulary_response_envelope(body)
                self.assertIn(envelope, harness.READ_ONLY_RESPONSE_ENVELOPES)
                # Identity, not equality: the emitted object is the constant.
                self.assertTrue(
                    any(
                        envelope is constant
                        for constant in harness.READ_ONLY_RESPONSE_ENVELOPES
                    )
                )

    def test_direct_voc_object_is_classified_but_never_reaches_missing_voc(
        self,
    ) -> None:
        """Kept for completeness: a usable top-level ``voc`` is not ``missing-voc``."""
        body = {"voc": envelope_record()}
        self.assertEqual(
            harness._classify_vocabulary_response_envelope(body),
            "direct-voc-object",
        )
        # End to end that same body fails a *later* checkpoint, so no envelope
        # is reported at all.
        failure, transport = self.run_failure([harness.HttpResponse(200, body)])
        summary = failure.safe_summary()
        self.assertEqual(summary["schema_reason"], "spelling-mismatch")
        self.assertIsNone(summary["response_envelope"])
        self.assertEqual(len(transport.requests), 1)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, self.rendered_failure(failure))

    # ------------------------------------------------------------------
    # End-to-end classification of the live failure shape
    # ------------------------------------------------------------------

    def test_every_reachable_envelope_is_reported_exactly(self) -> None:
        for name, body, envelope in missing_voc_envelope_cases():
            with self.subTest(case=name):
                failure, transport = self.run_failure(
                    [harness.HttpResponse(200, body)]
                )
                summary = failure.safe_summary()
                self.assertEqual(summary["response_envelope"], envelope)
                self.assertIn(
                    summary["response_envelope"],
                    harness.READ_ONLY_RESPONSE_ENVELOPES,
                )
                # The exact live third-run shape.
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["failure_class"], "schema")
                self.assertEqual(summary["http_status"], 200)
                self.assertEqual(summary["schema_reason"], "missing-voc")
                self.assertEqual(summary["requests_attempted"], 1)
                self.assertEqual(summary["requests_completed"], 1)
                # Exactly one GET, no retry, no follow-up request.
                self.assertEqual(len(transport.requests), 1)
                self.assertEqual(transport.requests[0].method, "GET")
                self.assertIn("/vocabulary?", transport.requests[0].path)
                self.assertIsNone(failure.__cause__)
                self.assertIsNone(failure.__context__)

    def test_no_sentinel_key_or_value_escapes_any_representation(self) -> None:
        for name, body, _envelope in vocabulary_envelope_cases():
            with self.subTest(case=name):
                failure, _transport = self.run_failure(
                    [harness.HttpResponse(200, body)]
                )
                rendered = self.rendered_failure(failure)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
                # Not the whole sentinel and not a distinctive fragment either,
                # and no hash/fingerprint of a server key or value.
                for fragment in ("PRIVATE", "ISSUE18", "SENTINEL", "Traceback"):
                    self.assertNotIn(fragment, rendered)
                for secret in (
                    ENVELOPE_UNKNOWN_KEY_SENTINEL,
                    ENVELOPE_OTHER_KEY_SENTINEL,
                    ENVELOPE_ID_SENTINEL,
                    ENVELOPE_SPELLING_SENTINEL,
                    ENVELOPE_MESSAGE_SENTINEL,
                ):
                    digest = hashlib.sha256(secret.encode("utf-8")).hexdigest()
                    self.assertNotIn(digest, rendered)
                    self.assertNotIn(digest[:16], rendered)

    def test_cli_prints_the_envelope_and_no_sentinel(self) -> None:
        for name, body, envelope in missing_voc_envelope_cases():
            with self.subTest(case=name):
                transport = FakeTransport([harness.HttpResponse(200, body)])
                exit_code, stdout, stderr = self.run_cli(transport)
                self.assertEqual(exit_code, 4)
                self.assertEqual(len(transport.requests), 1)
                diagnostic = self.cli_diagnostic(stdout)
                self.assertEqual(diagnostic["response_envelope"], envelope)
                self.assertEqual(diagnostic["schema_reason"], "missing-voc")
                rendered = stdout + stderr
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
                self.assertNotIn("Traceback", rendered)

    def test_unknown_server_keys_collapse_without_being_exposed(self) -> None:
        body = {
            ENVELOPE_UNKNOWN_KEY_SENTINEL: ENVELOPE_VALUE_SENTINEL,
            ENVELOPE_OTHER_KEY_SENTINEL: {
                "id": ENVELOPE_ID_SENTINEL,
                "spelling": ENVELOPE_SPELLING_SENTINEL,
            },
            f"{ENVELOPE_UNKNOWN_KEY_SENTINEL}-2": [ENVELOPE_VALUE_SENTINEL] * 3,
        }
        failure, _transport = self.run_failure([harness.HttpResponse(200, body)])
        summary = failure.safe_summary()
        # A vocabulary-shaped record under an unreviewed key is *not* promoted,
        # and its container's name is never revealed.
        self.assertIs(
            summary["response_envelope"], harness.RESPONSE_ENVELOPE_UNKNOWN_OBJECT
        )
        rendered = self.rendered_failure(failure)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        # No unknown key name, count or fingerprint of the unknown key set
        # travels with it: the emitted value is exactly the closed constant.
        self.assertEqual(
            json.dumps(summary["response_envelope"]), '"unknown-object"'
        )

    def test_business_error_like_never_exposes_its_values(self) -> None:
        for key in harness.RESPONSE_ENVELOPE_BUSINESS_KEYS:
            with self.subTest(business_key=key):
                body = {key: ENVELOPE_MESSAGE_SENTINEL}
                failure, _transport = self.run_failure(
                    [harness.HttpResponse(200, body)]
                )
                summary = failure.safe_summary()
                self.assertEqual(summary["response_envelope"], "business-error-like")
                rendered = self.rendered_failure(failure)
                self.assertNotIn(ENVELOPE_MESSAGE_SENTINEL, rendered)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
        # Structured, non-string business values are equally contained.
        body = {
            "code": {"nested": ENVELOPE_CODE_SENTINEL},
            "status": [ENVELOPE_STATUS_SENTINEL],
            "success": False,
        }
        failure, _transport = self.run_failure([harness.HttpResponse(200, body)])
        self.assertEqual(
            failure.safe_summary()["response_envelope"], "business-error-like"
        )
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, self.rendered_failure(failure))

    def test_classifier_reads_only_allowlisted_keys_and_never_enumerates(self) -> None:
        for name, body, envelope in vocabulary_envelope_cases():
            with self.subTest(case=name):
                log: list[object] = []
                observed = harness._classify_vocabulary_response_envelope(
                    RecordingMapping(body, log)
                )
                self.assertEqual(observed, envelope)
                self.assertNotIn(ENUMERATION_MARKER, log)
                self.assertTrue(
                    set(log).issubset(set(harness.RESPONSE_ENVELOPE_INSPECTED_KEYS)),
                    f"classifier touched an unreviewed key name in case {name}",
                )

    def test_hostile_mapping_fails_closed_to_unknown_object(self) -> None:
        envelope = harness._classify_vocabulary_response_envelope(HostileMapping())
        self.assertIs(envelope, harness.RESPONSE_ENVELOPE_UNKNOWN_OBJECT)
        self.assertNotIn(ENVELOPE_VALUE_SENTINEL, envelope)

    # ------------------------------------------------------------------
    # The envelope must be null everywhere else
    # ------------------------------------------------------------------

    def test_response_envelope_is_null_for_every_non_missing_voc_failure(self) -> None:
        observed_non_null = set()
        for name, responses, expected, _count in self.issue14_suite().failure_cases():
            with self.subTest(case=name):
                summary = self.run_failure(responses)[0].safe_summary()
                self.assertEqual(summary, expected)
                envelope = summary["response_envelope"]
                if envelope is None:
                    self.assertNotEqual(
                        (
                            summary["failure_stage"],
                            summary["failure_class"],
                            summary["schema_reason"],
                        ),
                        ("vocabulary", "schema", "missing-voc"),
                    )
                    continue
                observed_non_null.add(envelope)
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["failure_class"], "schema")
                self.assertEqual(summary["schema_reason"], "missing-voc")
                self.assertEqual(summary["http_status"], 200)
        self.assertTrue(observed_non_null)

    def test_transport_http_status_and_safety_failures_report_no_envelope(
        self,
    ) -> None:
        cases: list[tuple[str, list[object]]] = [
            ("transport", [harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL)]),
            ("transport-oserror", [OSError(TRANSPORT_EXCEPTION_SENTINEL)]),
            ("safety", [harness.SafetyError(TRANSPORT_EXCEPTION_SENTINEL)]),
            (
                "redirect",
                [harness.HttpResponse(302, {"error": ENVELOPE_VALUE_SENTINEL})],
            ),
            (
                "rejected-without-status",
                [harness.TransportResponseError(None)],
            ),
        ]
        for status in (401, 403, 404, 429, 500, 503):
            cases.append(
                (
                    f"http-{status}",
                    [
                        harness.HttpResponse(
                            status,
                            {
                                "code": ENVELOPE_CODE_SENTINEL,
                                "message": ENVELOPE_MESSAGE_SENTINEL,
                            },
                        )
                    ],
                )
            )
        for name, responses in cases:
            with self.subTest(case=name):
                summary = self.run_failure(responses)[0].safe_summary()
                self.assertIsNone(summary["response_envelope"])
                self.assertIn(
                    summary["failure_class"], ("transport", "http-status", "safety")
                )

    def test_body_level_schema_reasons_report_no_envelope(self) -> None:
        for reason in (
            harness.SCHEMA_REASON_BODY_INVALID_UTF8,
            harness.SCHEMA_REASON_BODY_INVALID_JSON,
            harness.SCHEMA_REASON_BODY_NOT_OBJECT,
            harness.SCHEMA_REASON_BODY_TOO_LARGE,
        ):
            with self.subTest(schema_reason=reason):
                summary = self.run_failure(
                    [harness.TransportResponseError(200, reason)]
                )[0].safe_summary()
                self.assertEqual(summary["schema_reason"], reason)
                self.assertIsNone(summary["response_envelope"])

    def test_pr15_body_io_failures_stay_transport_with_null_status_and_envelope(
        self,
    ) -> None:
        """Issue #18 must not regress the PR #15 body-I/O repair."""
        suite = self.issue14_suite()
        for name, error in suite.io_errors():
            for status in (200, 401):
                with self.subTest(error=name, status=status):
                    failure, state = suite.run_production_probe(
                        [{"status": status, "body": error}]
                    )
                    summary = failure.safe_summary()
                    self.assertEqual(summary["failure_class"], "transport")
                    self.assertIsNone(summary["http_status"])
                    self.assertIsNone(summary["schema_reason"])
                    self.assertIsNone(summary["response_envelope"])
                    self.assertEqual(summary["requests_completed"], 0)
                    self.assertEqual(state["reads"], 1)

    def test_interpretations_and_phrases_schema_failures_report_no_envelope(
        self,
    ) -> None:
        valid = self.responses()
        cases: list[tuple[str, list[object], str]] = [
            (
                "interpretations-not-an-array",
                self.responses(
                    interpretations={"data": {"voc": envelope_record()}}
                ),
                "interpretations",
            ),
            (
                "interpretations-missing-canonical-key",
                [
                    valid[0],
                    harness.HttpResponse(200, {"data": {"voc": envelope_record()}}),
                ],
                "interpretations",
            ),
            (
                "phrases-missing-canonical-key",
                [
                    valid[0],
                    valid[1],
                    harness.HttpResponse(200, {"vocabulary": envelope_record()}),
                ],
                "phrases",
            ),
        ]
        for name, responses, stage in cases:
            with self.subTest(case=name):
                failure, _transport = self.run_failure(responses)
                summary = failure.safe_summary()
                self.assertEqual(summary["failure_stage"], stage)
                self.assertEqual(summary["failure_class"], "schema")
                self.assertEqual(summary["http_status"], 200)
                self.assertIsNone(summary["response_envelope"])
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, self.rendered_failure(failure))

    # ------------------------------------------------------------------
    # Acceptance behavior is deliberately unchanged
    # ------------------------------------------------------------------

    def test_no_classified_envelope_becomes_an_accepted_success_response(self) -> None:
        """Issue #18 is diagnostic only: the contract stays top-level ``voc``."""
        for name, body, _envelope in vocabulary_envelope_cases():
            with self.subTest(case=name):
                with self.assertRaises(harness.SchemaReasonError) as context:
                    harness._validate_probe_vocabulary(body, self.WORD)
                self.assertIs(
                    context.exception.schema_reason,
                    harness.SCHEMA_REASON_MISSING_VOC,
                )
                self.assertNotIn(
                    ENVELOPE_SPELLING_SENTINEL,
                    f"{context.exception}{context.exception!r}",
                )
        # The documented shape still validates exactly as before.
        self.assertEqual(
            harness._validate_probe_vocabulary(
                {"voc": {"id": self.VOCABULARY_ID, "spelling": self.RETURNED_WORD}},
                self.WORD,
            ),
            (self.VOCABULARY_ID, self.RETURNED_WORD),
        )
        # The classifier is deliberately broader than the acceptance policy: it
        # locates a record whose id `_safe_record_id` still rejects, and locating
        # it does not make it acceptable.
        for located_id in (VOC_ID_PUNCTUATION_SENTINEL, 20260808):
            with self.subTest(located_id=type(located_id).__name__):
                self.assertTrue(
                    harness._looks_like_vocabulary_record(
                        {
                            "id": located_id,
                            "spelling": ENVELOPE_SPELLING_SENTINEL,
                        }
                    )
                )
                with self.assertRaises(harness.SafetyError):
                    harness._safe_record_id(located_id, "vocabulary id")
                with self.assertRaises(harness.SchemaReasonError):
                    harness._probe_vocabulary_record_id(located_id)

    def test_successful_probe_output_is_unchanged(self) -> None:
        transport = FakeTransport(self.responses())
        exit_code, stdout, stderr = self.run_cli(transport)
        self.assertEqual(exit_code, 0)
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(stderr, "")
        result = self.cli_diagnostic(stdout)
        self.assertNotIn("response_envelope", result)
        self.assertNotIn("response_envelope", stdout)
        self.assertNotIn("schema_reason", result)
        for envelope in harness.READ_ONLY_RESPONSE_ENVELOPES:
            self.assertNotIn(envelope, stdout)
        self.assertEqual(
            result["response_statuses"],
            {"vocabulary": 200, "interpretations": 200, "phrases": 200},
        )
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, stdout + stderr)

    # ------------------------------------------------------------------
    # Diagnostic contract
    # ------------------------------------------------------------------

    def test_diagnostic_rejects_every_out_of_contract_envelope(self) -> None:
        missing_voc = dict(
            failure_stage="vocabulary",
            failure_class="schema",
            http_status=200,
            requests_attempted=1,
            requests_completed=1,
            schema_reason="missing-voc",
            response_envelope="unknown-object",
        )
        self.assertEqual(
            harness.ReadOnlyFailureDiagnostic(**missing_voc).safe_summary()[
                "response_envelope"
            ],
            "unknown-object",
        )
        rejected = (
            # A missing-voc vocabulary failure must name an envelope.
            {"response_envelope": None},
            # ...and only a project-owned one.
            {"response_envelope": ENVELOPE_INJECTED_SENTINEL},
            {"response_envelope": ""},
            {"response_envelope": 7},
            {"response_envelope": ["unknown-object"]},
            {"response_envelope": "missing-voc"},
            # No other combination may carry an envelope at all.
            {"schema_reason": "voc-not-object"},
            {"schema_reason": "spelling-mismatch"},
            {"schema_reason": "body-not-object"},
            {"failure_stage": "interpretations"},
            {"failure_stage": "phrases"},
            {
                "failure_class": "http-status",
                "http_status": 404,
                "schema_reason": None,
            },
            {
                "failure_class": "transport",
                "http_status": None,
                "schema_reason": None,
                "requests_completed": 0,
            },
            {
                "failure_class": "safety",
                "http_status": None,
                "schema_reason": None,
                "requests_completed": 0,
            },
        )
        for override in rejected:
            with self.subTest(override=tuple(sorted(override))):
                with self.assertRaises(harness.SafetyError):
                    harness.ReadOnlyFailureDiagnostic(**{**missing_voc, **override})

    def test_injected_envelope_never_survives_by_equality(self) -> None:
        """A fabricated reason with no body fails closed instead of guessing."""
        failure, transport = self.run_failure(
            [harness.TransportResponseError(200, harness.SCHEMA_REASON_MISSING_VOC)]
        )
        summary = failure.safe_summary()
        # No decoded body existed, so no envelope could be classified; the
        # contract guard downgrades this to a sanitized safety failure rather
        # than emitting an unverified classification.
        self.assertEqual(summary["failure_class"], "safety")
        self.assertIsNone(summary["response_envelope"])
        self.assertIsNone(summary["schema_reason"])
        self.assertEqual(len(transport.requests), 1)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, self.rendered_failure(failure))

    def test_envelope_contract_fields_are_exactly_the_documented_set(self) -> None:
        for name, body, _envelope in vocabulary_envelope_cases():
            with self.subTest(case=name):
                summary = self.run_failure(
                    [harness.HttpResponse(200, body)]
                )[0].safe_summary()
                self.assertEqual(
                    set(summary),
                    {
                        "mode",
                        "status",
                        "failure_stage",
                        "failure_class",
                        "http_status",
                        "schema_reason",
                        "response_envelope",
                        "requests_attempted",
                        "requests_completed",
                    },
                )

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


class Issue20DataVocCompatibilityTests(ReadOnlyProbeFixtures, unittest.TestCase):
    """Issue #20: accept the observed ``data.voc`` envelope — and nothing else.

    The fourth owner-authorized run reported ``missing-voc`` together with
    ``response_envelope = data-voc-wrapper``, so production structurally answers
    ``{"data": {"voc": {...}}}`` while the first-party documentation still
    records the top-level ``{"voc": {...}}``. Every case below reproduces that
    shape offline with fake transports under the process-level no-network guard:
    no real credential is read and no Maimemo request is ever sent.
    """

    def probe_suite(self) -> Issue18ResponseEnvelopeTests:
        """Reuse the Issue #18 probe/CLI/rendering helpers verbatim."""
        return Issue18ResponseEnvelopeTests()

    def issue14_suite(self) -> Issue14ReadOnlyDiagnosticTests:
        return Issue14ReadOnlyDiagnosticTests()

    def voc_record(self, **overrides: object) -> dict[str, object]:
        """An acceptable vocabulary record carrying private sentinel noise."""
        record: dict[str, object] = {
            "id": self.VOCABULARY_ID,
            "spelling": self.RETURNED_WORD,
            COMPAT_UNKNOWN_KEY_SENTINEL: COMPAT_VALUE_SENTINEL,
        }
        record.update(overrides)
        return record

    def data_voc(self, voc: object, **siblings: object) -> dict[str, object]:
        """The observed production envelope, with private sibling noise."""
        wrapper: dict[str, object] = {"voc": voc}
        wrapper.update(siblings)
        return {
            "data": wrapper,
            COMPAT_UNKNOWN_KEY_SENTINEL: COMPAT_VALUE_SENTINEL,
        }

    def data_voc_responses(self, voc: object | None = None) -> list[object]:
        """The fake three-GET flow with only the vocabulary response wrapped."""
        documented = self.responses()
        return [
            harness.HttpResponse(
                200, self.data_voc(self.voc_record() if voc is None else voc)
            ),
            documented[1],
            documented[2],
        ]

    def run_success(
        self,
        responses: list[object],
    ) -> tuple[harness.ReadOnlyProbeResult, FakeTransport]:
        test_credential = self.probe_credential()
        transport = FakeTransport(list(responses))
        result = harness.ReadOnlyProbeExecutor(transport).execute(
            test_credential,
            self.probe_gate(test_credential),
        )
        return result, transport

    def rendered_result(self, result: harness.ReadOnlyProbeResult) -> str:
        return "".join(
            (
                json.dumps(result.safe_summary(), ensure_ascii=False, sort_keys=True),
                str(result),
                repr(result),
            )
        )

    def failure_summary(self, body: object) -> tuple[dict[str, object], FakeTransport]:
        failure, transport = self.probe_suite().run_failure(
            [harness.HttpResponse(200, body)]
        )
        return failure.safe_summary(), transport

    # ------------------------------------------------------------------
    # The boundary itself
    # ------------------------------------------------------------------

    def test_only_one_compatibility_container_key_exists(self) -> None:
        self.assertEqual(harness.READ_ONLY_COMPATIBILITY_CONTAINER_KEY, "data")
        self.assertEqual(harness.RESPONSE_ENVELOPE_VOC_KEY, "voc")

    def test_top_level_containment_still_guards_the_wrapped_form(self) -> None:
        """The wrapper does not buy a body past the existing top-level checks."""
        for name, body in (
            (
                "sensitive-top-level-field",
                dict(
                    self.data_voc(self.voc_record()),
                    **{f"{SERVER_KEY_SENTINEL}-token": SERVER_BODY_SENTINEL},
                ),
            ),
            (
                "non-string-top-level-key",
                {7: [SERVER_BODY_SENTINEL], "data": {"voc": self.voc_record()}},
            ),
        ):
            with self.subTest(case=name):
                summary, transport = self.failure_summary(body)
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["failure_class"], "schema")
                self.assertIn(
                    summary["schema_reason"],
                    ("top-level-response-policy", "body-not-object"),
                )
                self.assertIsNone(summary["response_envelope"])
                self.assertEqual(len(transport.requests), 1)

    def test_a_hostile_body_never_reaches_the_boundary_and_never_leaks(self) -> None:
        failure, transport = self.probe_suite().run_failure(
            [harness.HttpResponse(200, HostileMapping())]
        )
        summary = failure.safe_summary()
        self.assertEqual(summary["failure_stage"], "vocabulary")
        self.assertEqual(summary["failure_class"], "schema")
        self.assertIsNone(summary["response_envelope"])
        self.assertEqual(len(transport.requests), 1)
        rendered = self.probe_suite().rendered_failure(failure)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        self.assertNotIn("Traceback", rendered)

    def test_canonicalization_relocates_without_mutating_or_copying(self) -> None:
        nested = self.voc_record()
        body = self.data_voc(nested, **{"extra": COMPAT_VALUE_SENTINEL})
        before = json.dumps(body, ensure_ascii=False, sort_keys=True)
        canonical = harness._canonical_probe_vocabulary_body(body)
        # Exactly one project-owned key, holding the very same nested value.
        self.assertEqual(set(canonical), {"voc"})
        self.assertIs(canonical["voc"], nested)
        # The raw body is neither mutated nor handed back.
        self.assertIsNot(canonical, body)
        self.assertEqual(json.dumps(body, ensure_ascii=False, sort_keys=True), before)

    def test_documented_top_level_voc_always_wins_and_is_returned_unchanged(
        self,
    ) -> None:
        for name, documented in (
            ("valid", self.voc_record()),
            ("malformed-not-object", SERVER_BODY_SENTINEL),
            ("malformed-record", {"id": ""}),
        ):
            with self.subTest(case=name):
                body = {"voc": documented, "data": {"voc": self.voc_record()}}
                self.assertIs(harness._canonical_probe_vocabulary_body(body), body)
        # A body with no accepted location is likewise handed on untouched, so
        # the existing `missing-voc` rejection and its envelope are unaffected.
        for name, body in (
            ("no-data", {SERVER_KEY_SENTINEL: SERVER_BODY_SENTINEL}),
            ("data-not-mapping", {"data": COMPAT_VALUE_SENTINEL}),
            ("data-without-voc", {"data": self.voc_record()}),
            ("result-voc", {"result": {"voc": self.voc_record()}}),
        ):
            with self.subTest(case=name):
                self.assertIs(harness._canonical_probe_vocabulary_body(body), body)
        for name, body in (
            ("null", None),
            ("list", [{"voc": self.voc_record()}]),
            ("string", COMPAT_VALUE_SENTINEL),
        ):
            with self.subTest(case=name):
                self.assertIs(harness._canonical_probe_vocabulary_body(body), body)

    # ------------------------------------------------------------------
    # Both accepted envelopes succeed
    # ------------------------------------------------------------------

    def test_documented_top_level_voc_still_succeeds_unchanged(self) -> None:
        result, transport = self.run_success(self.responses())
        summary = result.safe_summary()
        self.assertEqual(summary["requested_spelling"], self.WORD)
        self.assertEqual(summary["returned_spelling"], self.RETURNED_WORD)
        self.assertEqual(
            summary["response_shapes"]["vocabulary"],
            {
                "canonical_key": "voc",
                "canonical_key_present": True,
                "unknown_top_level_field_count": 0,
            },
        )
        self.assertEqual(len(transport.requests), 3)

    def test_observed_data_voc_body_passes_the_vocabulary_stage(self) -> None:
        result, _transport = self.run_success(self.data_voc_responses())
        summary = result.safe_summary()
        self.assertEqual(summary["returned_spelling"], self.RETURNED_WORD)
        self.assertEqual(
            summary["voc_id_fingerprint"],
            hashlib.sha256(self.VOCABULARY_ID.encode("utf-8")).hexdigest()[:16],
        )

    def test_observed_data_voc_reaches_the_interpretations_get(self) -> None:
        failure, transport = self.probe_suite().run_failure(
            [
                harness.HttpResponse(200, self.data_voc(self.voc_record())),
                harness.TransportError(TRANSPORT_EXCEPTION_SENTINEL),
            ]
        )
        summary = failure.safe_summary()
        # The vocabulary stage is behind us: the failure is the *second* GET.
        self.assertEqual(summary["failure_stage"], "interpretations")
        self.assertEqual(summary["failure_class"], "transport")
        self.assertEqual(summary["requests_attempted"], 2)
        self.assertEqual(summary["requests_completed"], 1)
        self.assertIsNone(summary["schema_reason"])
        self.assertIsNone(summary["response_envelope"])
        self.assertEqual(len(transport.requests), 2)
        self.assertEqual(
            transport.requests[1].path,
            harness.build_query_path(
                "interpretations", {"voc_id": self.VOCABULARY_ID}
            ),
        )
        for sentinel in SENTINELS:
            self.assertNotIn(
                sentinel, self.probe_suite().rendered_failure(failure)
            )

    def test_full_three_get_success_matches_the_documented_form_exactly(self) -> None:
        documented, documented_transport = self.run_success(self.responses())
        wrapped, wrapped_transport = self.run_success(self.data_voc_responses())
        # Canonicalization makes the observed envelope indistinguishable in the
        # project-owned output: no wrapper key, count or value leaks into it.
        self.assertEqual(wrapped.safe_summary(), documented.safe_summary())
        for transport in (documented_transport, wrapped_transport):
            self.assertEqual(
                [request.path for request in transport.requests],
                [
                    harness.build_query_path("vocabulary", {"spelling": self.WORD}),
                    harness.build_query_path(
                        "interpretations", {"voc_id": self.VOCABULARY_ID}
                    ),
                    harness.build_query_path(
                        "phrases", {"voc_id": self.VOCABULARY_ID}
                    ),
                ],
            )

    # ------------------------------------------------------------------
    # Precedence: a malformed documented response is never bypassed
    # ------------------------------------------------------------------

    def test_malformed_top_level_voc_never_falls_back_to_data_voc(self) -> None:
        cases: tuple[tuple[str, object, str], ...] = (
            ("voc-not-object", SERVER_BODY_SENTINEL, "voc-not-object"),
            (
                "voc-id-missing",
                {"spelling": self.RETURNED_WORD},
                "voc-id-missing-or-not-string",
            ),
            (
                "voc-id-not-string",
                {"id": 20260808, "spelling": self.RETURNED_WORD},
                "voc-id-missing-or-not-string",
            ),
            ("voc-id-empty", {"id": "", "spelling": self.RETURNED_WORD}, "voc-id-empty"),
            (
                "voc-id-local-policy",
                {"id": VOC_ID_PUNCTUATION_SENTINEL, "spelling": self.RETURNED_WORD},
                "voc-id-local-policy",
            ),
            (
                "spelling-missing",
                {"id": self.VOCABULARY_ID},
                "spelling-missing-or-not-string",
            ),
            (
                "spelling-local-policy",
                {"id": self.VOCABULARY_ID, "spelling": f" {self.RETURNED_WORD} "},
                "spelling-local-policy",
            ),
            (
                "spelling-mismatch",
                {"id": self.VOCABULARY_ID, "spelling": SPELLING_SENTINEL},
                "spelling-mismatch",
            ),
        )
        for name, malformed, reason in cases:
            with self.subTest(case=name):
                body = {"voc": malformed, "data": {"voc": self.voc_record()}}
                # The second candidate is never even considered.
                self.assertIs(harness._canonical_probe_vocabulary_body(body), body)
                summary, transport = self.failure_summary(body)
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["failure_class"], "schema")
                self.assertEqual(summary["http_status"], 200)
                self.assertEqual(summary["schema_reason"], reason)
                self.assertIsNone(summary["response_envelope"])
                # One GET, and never the interpretations follow-up.
                self.assertEqual(len(transport.requests), 1)

    # ------------------------------------------------------------------
    # Everything else stays fail-closed
    # ------------------------------------------------------------------

    def test_missing_top_level_voc_with_non_mapping_data_is_fail_closed(self) -> None:
        for name, wrapper in (
            ("string", COMPAT_VALUE_SENTINEL),
            ("list", [{"voc": self.voc_record()}]),
            ("null", None),
            ("number", 20260808),
            ("bool", True),
        ):
            with self.subTest(case=name):
                summary, transport = self.failure_summary({"data": wrapper})
                self.assertEqual(summary["schema_reason"], "missing-voc")
                self.assertEqual(summary["response_envelope"], "unknown-object")
                self.assertEqual(len(transport.requests), 1)

    def test_data_mapping_without_voc_is_fail_closed(self) -> None:
        for name, body, envelope in (
            ("empty-wrapper", {"data": {}}, "unknown-object"),
            (
                "record-directly-under-data",
                {"data": self.voc_record()},
                "data-vocabulary-object",
            ),
            (
                "only-unreviewed-keys",
                {"data": {COMPAT_UNKNOWN_KEY_SENTINEL: COMPAT_VALUE_SENTINEL}},
                "unknown-object",
            ),
        ):
            with self.subTest(case=name):
                summary, transport = self.failure_summary(body)
                self.assertEqual(summary["schema_reason"], "missing-voc")
                self.assertEqual(summary["response_envelope"], envelope)
                self.assertEqual(len(transport.requests), 1)

    def test_data_voc_that_is_not_a_mapping_uses_the_existing_schema_reason(
        self,
    ) -> None:
        for name, nested in (
            ("string", COMPAT_VALUE_SENTINEL),
            ("list", [self.voc_record()]),
            ("null", None),
            ("number", 20260808),
            ("bool", False),
        ):
            with self.subTest(case=name):
                summary, transport = self.failure_summary(self.data_voc(nested))
                self.assertEqual(summary["schema_reason"], "voc-not-object")
                self.assertIsNone(summary["response_envelope"])
                self.assertEqual(len(transport.requests), 1)

    def test_data_voc_id_failures_use_the_existing_exact_schema_reasons(self) -> None:
        cases: tuple[tuple[str, dict[str, object], str], ...] = (
            (
                "missing",
                {"spelling": self.RETURNED_WORD},
                "voc-id-missing-or-not-string",
            ),
            (
                "not-a-string",
                {"id": 20260808, "spelling": self.RETURNED_WORD},
                "voc-id-missing-or-not-string",
            ),
            (
                "boolean",
                {"id": True, "spelling": self.RETURNED_WORD},
                "voc-id-missing-or-not-string",
            ),
            ("empty", {"id": "", "spelling": self.RETURNED_WORD}, "voc-id-empty"),
            (
                "punctuated",
                {"id": VOC_ID_PUNCTUATION_SENTINEL, "spelling": self.RETURNED_WORD},
                "voc-id-local-policy",
            ),
        )
        for name, nested, reason in cases:
            with self.subTest(case=name):
                summary, transport = self.failure_summary(self.data_voc(nested))
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["schema_reason"], reason)
                self.assertIsNone(summary["response_envelope"])
                self.assertEqual(len(transport.requests), 1)

    def test_data_voc_spelling_failures_use_the_existing_exact_schema_reasons(
        self,
    ) -> None:
        cases: tuple[tuple[str, dict[str, object], str], ...] = (
            (
                "missing",
                {"id": self.VOCABULARY_ID},
                "spelling-missing-or-not-string",
            ),
            (
                "not-a-string",
                {"id": self.VOCABULARY_ID, "spelling": [self.RETURNED_WORD]},
                "spelling-missing-or-not-string",
            ),
            (
                "padded",
                {"id": self.VOCABULARY_ID, "spelling": f" {self.RETURNED_WORD} "},
                "spelling-local-policy",
            ),
            (
                "mismatch",
                {"id": self.VOCABULARY_ID, "spelling": SPELLING_SENTINEL},
                "spelling-mismatch",
            ),
        )
        for name, nested, reason in cases:
            with self.subTest(case=name):
                summary, transport = self.failure_summary(self.data_voc(nested))
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["schema_reason"], reason)
                self.assertIsNone(summary["response_envelope"])
                self.assertEqual(len(transport.requests), 1)

    def test_no_other_envelope_was_enabled(self) -> None:
        """Every reviewed non-``data.voc`` location stays fail-closed.

        The records here are fully *acceptable* ones, so the only reason these
        are rejected is their location — proving the fix was not generalized.
        """
        for name, body, envelope in (
            ("direct-vocabulary-object", self.voc_record(), "direct-vocabulary-object"),
            (
                "data-vocabulary-object",
                {"data": self.voc_record()},
                "data-vocabulary-object",
            ),
            (
                "result-voc-wrapper",
                {"result": {"voc": self.voc_record()}},
                "result-voc-wrapper",
            ),
            (
                "result-vocabulary-object",
                {"result": self.voc_record()},
                "result-vocabulary-object",
            ),
            (
                "vocabulary-wrapper",
                {"vocabulary": self.voc_record()},
                "vocabulary-wrapper",
            ),
            (
                "business-error-like",
                {"code": ENVELOPE_CODE_SENTINEL, "message": ENVELOPE_MESSAGE_SENTINEL},
                "business-error-like",
            ),
            (
                "unknown-object",
                {COMPAT_UNKNOWN_KEY_SENTINEL: COMPAT_VALUE_SENTINEL},
                "unknown-object",
            ),
        ):
            with self.subTest(case=name):
                self.assertIs(harness._canonical_probe_vocabulary_body(body), body)
                summary, transport = self.failure_summary(body)
                self.assertEqual(summary["schema_reason"], "missing-voc")
                self.assertEqual(summary["response_envelope"], envelope)
                self.assertEqual(len(transport.requests), 1)
        # The whole Issue #18 corpus that still reaches `missing-voc` is
        # likewise handed on untouched by the boundary.
        for name, body, envelope in missing_voc_envelope_cases():
            with self.subTest(corpus_case=name):
                self.assertIs(harness._canonical_probe_vocabulary_body(body), body)

    def test_inner_vocabulary_validation_is_completely_unchanged(self) -> None:
        """The Issue #18 locating classifier must not become the validator."""
        for located_id in (VOC_ID_PUNCTUATION_SENTINEL, 20260808, True):
            with self.subTest(located_id=repr(located_id)):
                nested = {"id": located_id, "spelling": self.RETURNED_WORD}
                # The classifier still locates it under the accepted location...
                self.assertIn(
                    harness._classify_vocabulary_response_envelope(
                        {"data": {"voc": nested}}
                    ),
                    harness.READ_ONLY_RESPONSE_ENVELOPES,
                )
                # ...and the unchanged acceptance rules still reject it.
                with self.assertRaises(harness.SchemaReasonError):
                    harness._probe_vocabulary_record_id(located_id)
                with self.assertRaises(harness.SchemaReasonError):
                    harness._validate_probe_vocabulary(
                        harness._canonical_probe_vocabulary_body(
                            self.data_voc(nested)
                        ),
                        self.WORD,
                    )
        # `_validate_probe_vocabulary` itself never learned about `data`: the
        # relocation happens strictly outside it.
        with self.assertRaises(harness.SchemaReasonError) as context:
            harness._validate_probe_vocabulary(
                self.data_voc(self.voc_record()), self.WORD
            )
        self.assertIs(
            context.exception.schema_reason, harness.SCHEMA_REASON_MISSING_VOC
        )

    # ------------------------------------------------------------------
    # No retry, and nothing private in the output
    # ------------------------------------------------------------------

    def test_no_compatibility_path_ever_retries(self) -> None:
        for name, body in (
            ("accepted-but-malformed", self.data_voc({"id": ""})),
            ("rejected-location", {"result": {"voc": self.voc_record()}}),
            ("no-fallback", {"voc": SERVER_BODY_SENTINEL, "data": {"voc": self.voc_record()}}),
        ):
            with self.subTest(case=name):
                summary, transport = self.failure_summary(body)
                self.assertEqual(summary["requests_attempted"], 1)
                self.assertEqual(summary["requests_completed"], 1)
                self.assertEqual(len(transport.requests), 1)
                self.assertEqual(transport.requests[0].method, "GET")
        _result, transport = self.run_success(self.data_voc_responses())
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(
            [request.method for request in transport.requests], ["GET"] * 3
        )

    def test_successful_data_voc_output_reveals_nothing_private(self) -> None:
        result, _transport = self.run_success(self.data_voc_responses())
        rendered = self.rendered_result(result)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        for secret in (
            "data",
            self.VOCABULARY_ID,
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
            FAKE_TOKEN,
            ACCOUNT_LABEL,
        ):
            self.assertNotIn(secret, rendered)
        digest = hashlib.sha256(COMPAT_VALUE_SENTINEL.encode("utf-8")).hexdigest()
        self.assertNotIn(digest, rendered)
        self.assertNotIn(digest[:16], rendered)
        # The project-owned shape summary stays exactly what it was.
        self.assertEqual(
            result.safe_summary()["response_shapes"]["vocabulary"],
            {
                "canonical_key": "voc",
                "canonical_key_present": True,
                "unknown_top_level_field_count": 0,
            },
        )

    def test_cli_success_prints_one_sanitized_object_and_exits_zero(self) -> None:
        transport = FakeTransport(self.data_voc_responses())
        exit_code, stdout, stderr = self.probe_suite().run_cli(transport)
        self.assertEqual(exit_code, 0)
        self.assertEqual(len(transport.requests), 3)
        rendered = stdout + stderr
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        for secret in (
            self.VOCABULARY_ID,
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
        ):
            self.assertNotIn(secret, rendered)
        self.assertNotIn("Traceback", rendered)

    # ------------------------------------------------------------------
    # Untouched neighbours
    # ------------------------------------------------------------------

    def test_the_vocabulary_boundary_stays_vocabulary_only(self) -> None:
        """Issue #22 added the collection boundary; this one did not grow.

        The two collection GETs are canonicalized by their *own* endpoint-keyed
        boundary (see :class:`Issue22DataCollectionCompatibilityTests`). The
        vocabulary boundary still only knows ``voc``, so a wrapped collection
        body is handed back untouched by it, and the wrapped vocabulary body is
        likewise untouched by the collection boundary.
        """
        for name, body in (
            ("data-interpretations", {"data": {"interpretations": []}}),
            ("data-phrases", {"data": {"phrases": []}}),
        ):
            with self.subTest(case=name):
                self.assertIs(harness._canonical_probe_vocabulary_body(body), body)
        wrapped_vocabulary = self.data_voc(self.voc_record())
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            with self.subTest(response_key=response_key):
                self.assertIs(
                    harness._canonical_probe_collection_body(
                        wrapped_vocabulary, response_key
                    ),
                    wrapped_vocabulary,
                )

    def test_pr15_body_io_behavior_remains_unchanged(self) -> None:
        suite = self.issue14_suite()
        for name, error in suite.io_errors():
            for status in (200, 401):
                with self.subTest(error=name, status=status):
                    failure, state = suite.run_production_probe(
                        [{"status": status, "body": error}]
                    )
                    summary = failure.safe_summary()
                    self.assertEqual(summary["failure_class"], "transport")
                    self.assertIsNone(summary["http_status"])
                    self.assertIsNone(summary["schema_reason"])
                    self.assertIsNone(summary["response_envelope"])
                    self.assertEqual(summary["requests_completed"], 0)
                    self.assertEqual(state["reads"], 1)

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


class Issue22DataCollectionCompatibilityTests(
    ReadOnlyProbeFixtures, unittest.TestCase
):
    """Issue #22: accept ``data.<key>`` for the two collection GETs — nothing else.

    The fifth owner-authorized secondary-account GET-only run reported::

        {"failure_stage": "interpretations", "failure_class": "schema",
         "http_status": 200, "schema_reason": "other-reviewed-schema",
         "requests_attempted": 2, "requests_completed": 2,
         "response_envelope": null}

    so the merged ``data.voc`` fix works, vocabulary now succeeds, and the
    interpretations GET completes with HTTP 200 and is then rejected inside
    collection parsing.

    ``data.interpretations`` is therefore a strong *inference* from the directly
    observed ``data.voc`` convention. ``data.phrases`` has **not** been observed
    in production; it is supported proactively so both collection GETs share one
    narrow contract. Every case below reproduces the shapes offline with fake
    transports under the process-level no-network guard: no real credential is
    read and no Maimemo request is ever sent.
    """

    def probe_suite(self) -> Issue18ResponseEnvelopeTests:
        """Reuse the Issue #18 probe/CLI/rendering helpers verbatim."""
        return Issue18ResponseEnvelopeTests()

    def compat_suite(self) -> Issue20DataVocCompatibilityTests:
        """Reuse the Issue #20 vocabulary-wrapper fixtures verbatim."""
        return Issue20DataVocCompatibilityTests()

    def issue14_suite(self) -> Issue14ReadOnlyDiagnosticTests:
        return Issue14ReadOnlyDiagnosticTests()

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------

    def documented(self, response_key: str, collection: object) -> dict[str, object]:
        """The first-party documented shape, with private sibling noise."""
        return {
            response_key: collection,
            COLLECTION_UNKNOWN_KEY_SENTINEL: COLLECTION_VALUE_SENTINEL,
        }

    def data_collection(
        self,
        response_key: str,
        collection: object,
        **siblings: object,
    ) -> dict[str, object]:
        """The compatibility shape, with private sibling noise inside and out."""
        wrapper: dict[str, object] = {response_key: collection}
        wrapper.update(siblings)
        return {
            "data": wrapper,
            COLLECTION_UNKNOWN_KEY_SENTINEL: COLLECTION_VALUE_SENTINEL,
        }

    def interpretation_collection(self) -> list[dict[str, object]]:
        return [self.interpretation_record()]

    def phrase_collection(self) -> list[dict[str, object]]:
        return [self.phrase_record()]

    def wrapped_vocabulary(self) -> harness.HttpResponse:
        compat = self.compat_suite()
        return harness.HttpResponse(200, compat.data_voc(compat.voc_record()))

    def three_data_wrapper_responses(
        self,
        *,
        interpretations: object | None = None,
        phrases: object | None = None,
    ) -> list[object]:
        """The fake three-GET flow with **every** payload under ``data``."""
        return [
            self.wrapped_vocabulary(),
            harness.HttpResponse(
                200,
                self.data_collection(
                    "interpretations",
                    self.interpretation_collection()
                    if interpretations is None
                    else interpretations,
                ),
            ),
            harness.HttpResponse(
                200,
                self.data_collection(
                    "phrases",
                    self.phrase_collection() if phrases is None else phrases,
                ),
            ),
        ]

    def run_success(
        self,
        responses: list[object],
    ) -> tuple[harness.ReadOnlyProbeResult, FakeTransport]:
        return self.compat_suite().run_success(responses)

    def responses_with(
        self,
        response_key: str,
        body: object,
    ) -> list[object]:
        """A flow whose ``response_key`` GET returns ``body`` verbatim."""
        documented = self.responses()
        if response_key == "interpretations":
            return [documented[0], harness.HttpResponse(200, body)]
        return [documented[0], documented[1], harness.HttpResponse(200, body)]

    def collection_failure(
        self,
        response_key: str,
        body: object,
    ) -> tuple[dict[str, object], FakeTransport]:
        failure, transport = self.probe_suite().run_failure(
            self.responses_with(response_key, body)
        )
        return failure.safe_summary(), transport

    def assert_collection_schema_failure(
        self,
        response_key: str,
        body: object,
    ) -> None:
        """Assert one completed-then-rejected GET with no retry and no leak."""
        summary, transport = self.collection_failure(response_key, body)
        expected_requests = 2 if response_key == "interpretations" else 3
        self.assertEqual(summary["failure_stage"], response_key)
        self.assertEqual(summary["failure_class"], "schema")
        self.assertEqual(summary["http_status"], 200)
        self.assertEqual(summary["schema_reason"], "other-reviewed-schema")
        # The Issue #18 locating classifier is never consulted for a collection.
        self.assertIsNone(summary["response_envelope"])
        self.assertEqual(summary["requests_attempted"], expected_requests)
        self.assertEqual(summary["requests_completed"], expected_requests)
        self.assertEqual(len(transport.requests), expected_requests)
        self.assertEqual(
            [request.method for request in transport.requests],
            ["GET"] * expected_requests,
        )

    def expected_shape(self, response_key: str) -> dict[str, object]:
        return {
            "canonical_key": response_key,
            "canonical_key_present": True,
            "unknown_top_level_field_count": 0,
        }

    # ------------------------------------------------------------------
    # The boundary itself
    # ------------------------------------------------------------------

    def test_collection_endpoint_keys_stay_closed_and_project_owned(self) -> None:
        self.assertEqual(
            harness.READ_ONLY_COLLECTION_KEYS, ("interpretations", "phrases")
        )
        # Exactly the endpoints that already own a documented status enum.
        self.assertEqual(
            harness.READ_ONLY_COLLECTION_KEYS, tuple(harness.READ_ONLY_STATUS_ENUMS)
        )
        # One compatibility container, shared with the vocabulary boundary.
        self.assertEqual(harness.READ_ONLY_COMPATIBILITY_CONTAINER_KEY, "data")
        for undocumented in ("vocabulary", "voc", "result", "items", ""):
            with self.subTest(response_key=undocumented):
                with self.assertRaises(harness.SafetyError):
                    harness._canonical_probe_collection_body(
                        {"data": {undocumented: []}}, undocumented
                    )

    def test_an_equal_endpoint_string_never_becomes_the_emitted_key(self) -> None:
        """The canonical key is the module constant, not the caller's string."""
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            with self.subTest(response_key=response_key):
                caller_owned = "".join(response_key)
                self.assertIsNot(caller_owned, response_key)
                canonical = harness._canonical_probe_collection_body(
                    {"data": {caller_owned: []}}, caller_owned
                )
                emitted = next(iter(canonical))
                self.assertIs(emitted, response_key)

    def test_canonicalization_relocates_without_mutating_or_copying(self) -> None:
        for response_key, collection in (
            ("interpretations", self.interpretation_collection()),
            ("phrases", self.phrase_collection()),
        ):
            with self.subTest(response_key=response_key):
                body = self.data_collection(
                    response_key,
                    collection,
                    **{COLLECTION_UNKNOWN_KEY_SENTINEL: COLLECTION_VALUE_SENTINEL},
                )
                before = json.dumps(body, ensure_ascii=False, sort_keys=True)
                canonical = harness._canonical_probe_collection_body(
                    body, response_key
                )
                # Exactly one project-owned key, holding the very same list.
                self.assertEqual(set(canonical), {response_key})
                self.assertIs(canonical[response_key], collection)
                # The raw body is neither mutated nor handed back.
                self.assertIsNot(canonical, body)
                self.assertEqual(
                    json.dumps(body, ensure_ascii=False, sort_keys=True), before
                )

    def test_documented_top_level_collection_always_wins_unchanged(self) -> None:
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            for name, documented in (
                ("valid", []),
                ("malformed-not-a-list", COLLECTION_VALUE_SENTINEL),
                ("malformed-records", [COLLECTION_VALUE_SENTINEL]),
                ("null", None),
            ):
                with self.subTest(response_key=response_key, case=name):
                    body = {
                        response_key: documented,
                        "data": {response_key: [self.interpretation_record()]},
                    }
                    self.assertIs(
                        harness._canonical_probe_collection_body(body, response_key),
                        body,
                    )
        # A body with no accepted location is likewise handed on untouched.
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            for name, body in (
                ("no-data", {COLLECTION_UNKNOWN_KEY_SENTINEL: COLLECTION_VALUE_SENTINEL}),
                ("data-not-mapping", {"data": COLLECTION_VALUE_SENTINEL}),
                ("data-without-the-key", {"data": {"voc": {}}}),
                ("result-wrapper", {"result": {response_key: []}}),
            ):
                with self.subTest(response_key=response_key, case=name):
                    self.assertIs(
                        harness._canonical_probe_collection_body(body, response_key),
                        body,
                    )
            for name, body in (
                ("null", None),
                ("list", [{response_key: []}]),
                ("string", COLLECTION_VALUE_SENTINEL),
            ):
                with self.subTest(response_key=response_key, case=name):
                    self.assertIs(
                        harness._canonical_probe_collection_body(body, response_key),
                        body,
                    )

    def test_each_endpoint_accepts_only_its_own_canonical_key(self) -> None:
        """A cross-endpoint payload never satisfies the other collection GET."""
        for response_key, other in (
            ("interpretations", "phrases"),
            ("phrases", "interpretations"),
        ):
            with self.subTest(response_key=response_key):
                body = {"data": {other: [self.interpretation_record()]}}
                self.assertIs(
                    harness._canonical_probe_collection_body(body, response_key), body
                )

    # ------------------------------------------------------------------
    # Both accepted forms succeed, per endpoint and end to end
    # ------------------------------------------------------------------

    def test_documented_collection_forms_still_succeed_unchanged(self) -> None:
        result, transport = self.run_success(self.responses())
        summary = result.safe_summary()
        self.assertEqual(summary["interpretation_count"], 1)
        self.assertEqual(summary["phrase_count"], 1)
        self.assertEqual(summary["interpretation_statuses"], {"PUBLISHED": 1})
        self.assertEqual(summary["phrase_statuses"], {"PUBLISHED": 1})
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            self.assertEqual(
                summary["response_shapes"][response_key],
                self.expected_shape(response_key),
            )
        self.assertEqual(len(transport.requests), 3)

    def test_data_interpretations_succeeds_and_advances_to_the_phrases_get(
        self,
    ) -> None:
        documented = self.responses()
        result, transport = self.run_success(
            [
                documented[0],
                harness.HttpResponse(
                    200,
                    self.data_collection(
                        "interpretations", self.interpretation_collection()
                    ),
                ),
                documented[2],
            ]
        )
        summary = result.safe_summary()
        self.assertEqual(summary["interpretation_count"], 1)
        self.assertEqual(
            summary["response_shapes"]["interpretations"],
            self.expected_shape("interpretations"),
        )
        # The third GET really was sent, with the documented voc_id query.
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(
            transport.requests[2].path,
            harness.build_query_path("phrases", {"voc_id": self.VOCABULARY_ID}),
        )

    def test_data_phrases_succeeds_in_the_full_flow(self) -> None:
        documented = self.responses()
        result, transport = self.run_success(
            [
                documented[0],
                documented[1],
                harness.HttpResponse(
                    200, self.data_collection("phrases", self.phrase_collection())
                ),
            ]
        )
        summary = result.safe_summary()
        self.assertEqual(summary["phrase_count"], 1)
        self.assertEqual(summary["phrase_statuses"], {"PUBLISHED": 1})
        self.assertEqual(summary["phrase_highlight_shapes"], {"integer-pair-array": 1})
        self.assertEqual(
            summary["response_shapes"]["phrases"], self.expected_shape("phrases")
        )
        self.assertEqual(len(transport.requests), 3)

    def test_full_three_data_wrapper_success_matches_the_documented_form(self) -> None:
        """The key regression target before the next owner-authorized run."""
        documented, documented_transport = self.run_success(self.responses())
        wrapped, wrapped_transport = self.run_success(
            self.three_data_wrapper_responses()
        )
        # Canonicalization makes the wrapped envelopes indistinguishable in the
        # project-owned output: no wrapper key, count or value leaks into it.
        self.assertEqual(wrapped.safe_summary(), documented.safe_summary())
        expected_paths = [
            harness.build_query_path("vocabulary", {"spelling": self.WORD}),
            harness.build_query_path(
                "interpretations", {"voc_id": self.VOCABULARY_ID}
            ),
            harness.build_query_path("phrases", {"voc_id": self.VOCABULARY_ID}),
        ]
        for transport in (documented_transport, wrapped_transport):
            self.assertEqual(
                [request.path for request in transport.requests], expected_paths
            )

    # ------------------------------------------------------------------
    # Precedence: a malformed documented response is never bypassed
    # ------------------------------------------------------------------

    def test_malformed_top_level_collection_never_falls_back_to_data(self) -> None:
        valid_by_key = {
            "interpretations": self.interpretation_collection(),
            "phrases": self.phrase_collection(),
        }
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            record = (
                self.interpretation_record()
                if response_key == "interpretations"
                else self.phrase_record()
            )
            for name, malformed in (
                ("not-a-list", COLLECTION_VALUE_SENTINEL),
                ("mapping", {"0": record}),
                ("null", None),
                ("malformed-item", [COLLECTION_VALUE_SENTINEL]),
                ("unsafe-record-id", [dict(record, id=COLLECTION_RECORD_ID_SENTINEL)]),
                ("duplicate-ids", [record, dict(record)]),
                ("cross-endpoint-status", [dict(record, status="ARCHIVED")]),
            ):
                with self.subTest(response_key=response_key, case=name):
                    body = {
                        response_key: malformed,
                        "data": {response_key: valid_by_key[response_key]},
                    }
                    # The second candidate is never even considered.
                    self.assertIs(
                        harness._canonical_probe_collection_body(body, response_key),
                        body,
                    )
                    self.assert_collection_schema_failure(response_key, body)

    # ------------------------------------------------------------------
    # Everything else stays fail-closed
    # ------------------------------------------------------------------

    def test_data_that_is_not_a_mapping_is_fail_closed(self) -> None:
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            for name, wrapper in (
                ("string", COLLECTION_VALUE_SENTINEL),
                ("list", [{response_key: []}]),
                ("null", None),
                ("number", 20260808),
                ("bool", True),
            ):
                with self.subTest(response_key=response_key, case=name):
                    self.assert_collection_schema_failure(
                        response_key, {"data": wrapper}
                    )

    def test_data_without_the_expected_canonical_key_is_fail_closed(self) -> None:
        for response_key, other in (
            ("interpretations", "phrases"),
            ("phrases", "interpretations"),
        ):
            for name, wrapper in (
                ("empty", {}),
                ("only-unreviewed-keys", {COLLECTION_UNKNOWN_KEY_SENTINEL: []}),
                ("vocabulary-key", {"voc": {"id": "X", "spelling": "X"}}),
                ("cross-endpoint-key", {other: [self.interpretation_record()]}),
                ("nested-again", {"data": {response_key: []}}),
            ):
                with self.subTest(response_key=response_key, case=name):
                    self.assert_collection_schema_failure(
                        response_key, {"data": wrapper}
                    )

    def test_data_canonical_key_with_the_wrong_type_is_fail_closed(self) -> None:
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            for name, collection in (
                ("string", COLLECTION_VALUE_SENTINEL),
                ("mapping", {"0": self.interpretation_record()}),
                ("null", None),
                ("number", 20260808),
                ("bool", False),
            ):
                with self.subTest(response_key=response_key, case=name):
                    body = self.data_collection(response_key, collection)
                    # Relocation still happens; acceptance is unchanged and fails.
                    self.assertEqual(
                        set(
                            harness._canonical_probe_collection_body(
                                body, response_key
                            )
                        ),
                        {response_key},
                    )
                    self.assert_collection_schema_failure(response_key, body)

    def test_no_other_collection_wrapper_was_enabled(self) -> None:
        """Every rejected location carries a fully **valid** collection.

        The only reason these fail is where the payload lives, which proves the
        fix was not generalized into a wrapper-agnostic unwrapper.
        """
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            valid = (
                self.interpretation_collection()
                if response_key == "interpretations"
                else self.phrase_collection()
            )
            bodies: tuple[tuple[str, object], ...] = (
                ("result-wrapper", {"result": {response_key: valid}}),
                ("result-direct", {"result": valid}),
                ("items-wrapper", {"items": valid}),
                ("records-wrapper", {"records": valid}),
                ("vocabulary-wrapper", {"vocabulary": {response_key: valid}}),
                ("data-list", {"data": valid}),
                ("data-result", {"data": {"result": valid}}),
                ("data-items", {"data": {"items": valid}}),
                ("unknown-wrapper", {COLLECTION_UNKNOWN_KEY_SENTINEL: valid}),
                ("empty-object", {}),
            )
            for name, body in bodies:
                with self.subTest(response_key=response_key, case=name):
                    self.assertIs(
                        harness._canonical_probe_collection_body(body, response_key),
                        body,
                    )
                    self.assert_collection_schema_failure(response_key, body)

    def test_a_bare_array_body_is_still_rejected_before_the_boundary(self) -> None:
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            valid = (
                self.interpretation_collection()
                if response_key == "interpretations"
                else self.phrase_collection()
            )
            with self.subTest(response_key=response_key):
                summary, _transport = self.collection_failure(response_key, valid)
                self.assertEqual(summary["failure_stage"], response_key)
                self.assertEqual(summary["schema_reason"], "body-not-object")
                self.assertIsNone(summary["response_envelope"])

    def test_top_level_containment_still_guards_the_wrapped_form(self) -> None:
        """The wrapper does not buy a body past the existing top-level checks."""
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            valid = (
                self.interpretation_collection()
                if response_key == "interpretations"
                else self.phrase_collection()
            )
            for name, body, reason in (
                (
                    "sensitive-top-level-field",
                    dict(
                        self.data_collection(response_key, valid),
                        **{f"{SERVER_KEY_SENTINEL}-token": SERVER_BODY_SENTINEL},
                    ),
                    "top-level-response-policy",
                ),
                (
                    "non-string-top-level-key",
                    {7: [SERVER_BODY_SENTINEL], "data": {response_key: valid}},
                    "body-not-object",
                ),
            ):
                with self.subTest(response_key=response_key, case=name):
                    summary, _transport = self.collection_failure(response_key, body)
                    self.assertEqual(summary["failure_stage"], response_key)
                    self.assertEqual(summary["schema_reason"], reason)
                    self.assertIsNone(summary["response_envelope"])

    # ------------------------------------------------------------------
    # Inner record validation is completely unchanged
    # ------------------------------------------------------------------

    def test_record_id_and_duplicate_rules_are_unchanged_through_the_wrapper(
        self,
    ) -> None:
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            record = (
                self.interpretation_record()
                if response_key == "interpretations"
                else self.phrase_record()
            )
            for name, collection in (
                ("non-mapping-item", [COLLECTION_VALUE_SENTINEL]),
                ("missing-id", [{key: value for key, value in record.items() if key != "id"}]),
                ("non-string-id", [dict(record, id=20260808)]),
                ("empty-id", [dict(record, id="")]),
                ("punctuated-id", [dict(record, id=COLLECTION_RECORD_ID_SENTINEL)]),
                ("duplicate-ids", [record, dict(record)]),
            ):
                with self.subTest(response_key=response_key, case=name):
                    self.assert_collection_schema_failure(
                        response_key, self.data_collection(response_key, collection)
                    )

    def test_status_enums_remain_endpoint_specific_through_the_wrapper(self) -> None:
        documented = self.responses()
        # `UNPUBLISHED` is documented for interpretations only.
        result, _transport = self.run_success(
            [
                documented[0],
                harness.HttpResponse(
                    200,
                    self.data_collection(
                        "interpretations",
                        [
                            self.interpretation_record(status="PUBLISHED"),
                            self.interpretation_record(
                                id="INVALID_ISSUE22_SECOND_ID", status="UNPUBLISHED"
                            ),
                            self.interpretation_record(
                                id="INVALID_ISSUE22_THIRD_ID", status="DELETED"
                            ),
                        ],
                    ),
                ),
                documented[2],
            ]
        )
        self.assertEqual(
            result.safe_summary()["interpretation_statuses"],
            {"PUBLISHED": 1, "UNPUBLISHED": 1, "DELETED": 1},
        )
        for response_key, rejected in (
            ("interpretations", ("ARCHIVED", "published", "", None, True, 1)),
            ("phrases", ("UNPUBLISHED", "ARCHIVED", "published", "", None, True, 1)),
        ):
            record = (
                self.interpretation_record()
                if response_key == "interpretations"
                else self.phrase_record()
            )
            for status in rejected:
                with self.subTest(response_key=response_key, status=repr(status)):
                    self.assert_collection_schema_failure(
                        response_key,
                        self.data_collection(
                            response_key, [dict(record, status=status)]
                        ),
                    )
        # `DELETED` remains documented for phrases.
        result, _transport = self.run_success(
            [
                documented[0],
                documented[1],
                harness.HttpResponse(
                    200,
                    self.data_collection(
                        "phrases", [self.phrase_record(status="DELETED")]
                    ),
                ),
            ]
        )
        self.assertEqual(
            result.safe_summary()["phrase_statuses"], {"DELETED": 1}
        )

    def test_phrase_body_and_highlight_rules_are_unchanged_through_the_wrapper(
        self,
    ) -> None:
        documented = self.responses()
        length = len(self.PRIVATE_PHRASE)
        for name, highlight, shape in (
            ("empty-array", [], "empty-array"),
            ("integer-pair-array", [[0, length]], "integer-pair-array"),
            (
                "object-range-array",
                [{"start": 0, "end": length}],
                "object-range-array",
            ),
        ):
            with self.subTest(case=name):
                result, _transport = self.run_success(
                    [
                        documented[0],
                        documented[1],
                        harness.HttpResponse(
                            200,
                            self.data_collection(
                                "phrases", [self.phrase_record(highlight=highlight)]
                            ),
                        ),
                    ]
                )
                self.assertEqual(
                    result.safe_summary()["phrase_highlight_shapes"], {shape: 1}
                )
        rejected: tuple[tuple[str, dict[str, object]], ...] = (
            ("missing-phrase", {"phrase": None}),
            ("empty-phrase", {"phrase": ""}),
            ("non-string-phrase", {"phrase": [self.PRIVATE_PHRASE]}),
            ("missing-highlight", {"highlight": None}),
            ("highlight-not-an-array", {"highlight": {"start": 0, "end": 1}}),
            ("highlight-end-past-phrase", {"highlight": [[0, length + 1]]}),
            ("highlight-start-past-phrase", {"highlight": [[length, length + 2]]}),
            ("highlight-inverted", {"highlight": [[2, 1]]}),
            ("highlight-negative", {"highlight": [[-1, 2]]}),
            ("highlight-boolean-range", {"highlight": [[True, 2]]}),
            ("highlight-object-out-of-bounds", {"highlight": [{"start": 0, "end": length + 1}]}),
            ("highlight-mixed-shapes", {"highlight": [[0, 1], {"start": 0, "end": 1}]}),
        )
        for name, override in rejected:
            with self.subTest(case=name):
                record = self.phrase_record()
                for key, value in override.items():
                    if value is None:
                        record.pop(key, None)
                    else:
                        record[key] = value
                self.assert_collection_schema_failure(
                    "phrases", self.data_collection("phrases", [record])
                )

    def test_the_locating_classifier_never_becomes_the_collection_validator(
        self,
    ) -> None:
        """No envelope classification may accept or reject a collection body."""
        body = self.data_collection("interpretations", self.interpretation_collection())
        # The classifier has an opinion about this body...
        self.assertIn(
            harness._classify_vocabulary_response_envelope(body),
            harness.READ_ONLY_RESPONSE_ENVELOPES,
        )
        # ...and the collection path neither consults nor reports it.
        result, _transport = self.run_success(
            [self.responses()[0], harness.HttpResponse(200, body), self.responses()[2]]
        )
        self.assertEqual(result.safe_summary()["interpretation_count"], 1)
        summary, _transport = self.collection_failure(
            "interpretations", {"data": {"voc": {"id": "X", "spelling": "X"}}}
        )
        self.assertIsNone(summary["response_envelope"])

    # ------------------------------------------------------------------
    # No retry, and nothing private in the output
    # ------------------------------------------------------------------

    def test_no_compatibility_path_ever_retries(self) -> None:
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            valid = (
                self.interpretation_collection()
                if response_key == "interpretations"
                else self.phrase_collection()
            )
            for name, body in (
                ("accepted-but-malformed", self.data_collection(response_key, {})),
                ("rejected-location", {"result": {response_key: valid}}),
                (
                    "no-fallback",
                    {
                        response_key: COLLECTION_VALUE_SENTINEL,
                        "data": {response_key: valid},
                    },
                ),
            ):
                with self.subTest(response_key=response_key, case=name):
                    self.assert_collection_schema_failure(response_key, body)
        _result, transport = self.run_success(self.three_data_wrapper_responses())
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(
            [request.method for request in transport.requests], ["GET"] * 3
        )

    def test_successful_wrapped_output_reveals_nothing_private(self) -> None:
        result, _transport = self.run_success(self.three_data_wrapper_responses())
        rendered = self.compat_suite().rendered_result(result)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        for secret in (
            "data",
            self.VOCABULARY_ID,
            "INVALID_ISSUE11_INTERPRETATION_ID",
            "INVALID_ISSUE11_PHRASE_ID",
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
            FAKE_TOKEN,
            ACCOUNT_LABEL,
        ):
            self.assertNotIn(secret, rendered)
        digest = hashlib.sha256(COLLECTION_VALUE_SENTINEL.encode("utf-8")).hexdigest()
        self.assertNotIn(digest, rendered)
        self.assertNotIn(digest[:16], rendered)
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            self.assertEqual(
                result.safe_summary()["response_shapes"][response_key],
                self.expected_shape(response_key),
            )

    def test_wrapped_collection_failures_never_leak(self) -> None:
        for response_key in harness.READ_ONLY_COLLECTION_KEYS:
            with self.subTest(response_key=response_key):
                failure, _transport = self.probe_suite().run_failure(
                    self.responses_with(
                        response_key,
                        self.data_collection(
                            response_key,
                            [
                                {
                                    "id": COLLECTION_RECORD_ID_SENTINEL,
                                    "status": SERVER_BODY_SENTINEL,
                                    "phrase": COLLECTION_VALUE_SENTINEL,
                                }
                            ],
                        ),
                    )
                )
                rendered = self.probe_suite().rendered_failure(failure)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, rendered)
                self.assertNotIn("Traceback", rendered)

    def test_cli_success_prints_one_sanitized_object_and_exits_zero(self) -> None:
        transport = FakeTransport(self.three_data_wrapper_responses())
        exit_code, stdout, stderr = self.probe_suite().run_cli(transport)
        self.assertEqual(exit_code, 0)
        self.assertEqual(len(transport.requests), 3)
        rendered = stdout + stderr
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, rendered)
        for secret in (
            self.VOCABULARY_ID,
            self.PRIVATE_INTERPRETATION,
            self.PRIVATE_PHRASE,
        ):
            self.assertNotIn(secret, rendered)
        self.assertNotIn("Traceback", rendered)

    # ------------------------------------------------------------------
    # Untouched neighbours
    # ------------------------------------------------------------------

    def test_vocabulary_stage_parsing_is_untouched(self) -> None:
        """A wrapped *collection* body never satisfies the vocabulary GET."""
        for name, body, envelope in (
            ("data-interpretations", {"data": {"interpretations": []}}, "unknown-object"),
            ("data-phrases", {"data": {"phrases": []}}, "unknown-object"),
        ):
            with self.subTest(case=name):
                summary, transport = self.compat_suite().failure_summary(body)
                self.assertEqual(summary["failure_stage"], "vocabulary")
                self.assertEqual(summary["schema_reason"], "missing-voc")
                self.assertEqual(summary["response_envelope"], envelope)
                self.assertEqual(len(transport.requests), 1)

    def test_pr15_body_io_behavior_remains_unchanged(self) -> None:
        suite = self.issue14_suite()
        for name, error in suite.io_errors():
            for status in (200, 401):
                with self.subTest(error=name, status=status):
                    failure, state = suite.run_production_probe(
                        [{"status": status, "body": error}]
                    )
                    summary = failure.safe_summary()
                    self.assertEqual(summary["failure_class"], "transport")
                    self.assertIsNone(summary["http_status"])
                    self.assertIsNone(summary["schema_reason"])
                    self.assertIsNone(summary["response_envelope"])
                    self.assertEqual(summary["requests_completed"], 0)
                    self.assertEqual(state["reads"], 1)

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


if __name__ == "__main__":
    unittest.main()
