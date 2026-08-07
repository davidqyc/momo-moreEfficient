from __future__ import annotations

import io
import json
import os
from dataclasses import replace
from pathlib import Path
import shutil
import socket
import stat
import sys
import tempfile
import unittest
from unittest import mock


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


class Issue11ReadOnlyProbeTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
