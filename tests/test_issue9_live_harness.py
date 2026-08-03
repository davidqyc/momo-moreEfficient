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
        "highlight": highlight,
    }


def responses_for_step(
    step: harness.PreparedStep,
    readback_record: dict[str, object],
    *,
    preflight_record: dict[str, object] | None = None,
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
    responses.extend(
        [
            harness.HttpResponse(200, {singular: {"id": record_id}}),
            harness.HttpResponse(200, {step.response_key: [readback_record]}),
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
            harness.ManualAccountGate(False, ACCOUNT_LABEL, test_credential.fingerprint, ""),
            harness.ManualAccountGate(
                True,
                "main",
                test_credential.fingerprint,
                f"CONFIRM SECONDARY TEST ACCOUNT: main TOKEN-FP: {test_credential.fingerprint}",
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
        self.assertNotIn(FAKE_TOKEN, valid_gate(test_credential).expected_confirmation)

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
            result, {"status": 200, "response_keys": ["interpretations"]}
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
        state_store.begin(step, test_credential.fingerprint)
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
            expected = (
                "prepared-not-sent"
                if index == 0
                else "write-succeeded-readback-unverified"
            )
            self.assertEqual(state_store.read(1)["status"], expected)

        transport = FakeTransport(
            [
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
                transport = FakeTransport([response])
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
                self.assertEqual(len(transport.requests), 1)
                self.assertEqual(transport.requests[0].method, "POST")
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
                persisted = state_store.read(sequence)
                self.assertEqual(persisted["status"], "verified")
                self.assertEqual(
                    persisted["result"]["payload_readback_status"], "verified"
                )
                self.assertEqual(
                    persisted["result"]["highlight_observation"]["raw_shape"],
                    raw_shape,
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
        transport = FakeTransport([harness.TransportError(FAKE_TOKEN)])
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


if __name__ == "__main__":
    unittest.main()
