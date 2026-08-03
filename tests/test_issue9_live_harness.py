from __future__ import annotations

import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
FIXTURE = ROOT / "tests" / "fixtures" / "issue2-smoke-input.example.json"
sys.path.insert(0, str(SCRIPTS))

import issue9_live_harness as harness  # noqa: E402


FAKE_TOKEN = "FAKE_TEST_CREDENTIAL_NOT_VALID"
ACCOUNT_LABEL = "issue9-secondary-fixture"


class FakeTransport:
    def __init__(
        self,
        responses: list[harness.HttpResponse] | None = None,
        error: Exception | None = None,
    ) -> None:
        self.responses = list(responses or [])
        self.error = error
        self.requests: list[harness.HttpRequest] = []

    def send(
        self,
        request: harness.HttpRequest,
        _credential: harness.TestAccountCredential,
    ) -> harness.HttpResponse:
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        if not self.responses:
            raise AssertionError("fake transport has no queued response")
        return self.responses.pop(0)


def credential() -> harness.TestAccountCredential:
    return harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL)


def valid_gate() -> harness.ManualAccountGate:
    return harness.ManualAccountGate(
        allow_network=True,
        account_label=ACCOUNT_LABEL,
        confirmation=f"CONFIRM SECONDARY TEST ACCOUNT: {ACCOUNT_LABEL}",
    )


class Issue9SafetyTests(unittest.TestCase):
    def setUp(self) -> None:
        harness.PRIVATE_STATE_ROOT.mkdir(parents=True, exist_ok=True)
        self.plan = harness.build_offline_plan(FIXTURE)

    def test_global_test_guard_blocks_socket_creation(self) -> None:
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        with self.assertRaisesRegex(RuntimeError, "network disabled"):
            socket.socket()

    def test_default_cli_is_offline_and_has_no_token_option(self) -> None:
        output = io.StringIO()
        original_stdout = sys.stdout
        try:
            sys.stdout = output
            result = harness.main([])
        finally:
            sys.stdout = original_stdout
        self.assertEqual(result, 0)
        self.assertIn("DRY RUN — NO REQUEST SENT", output.getvalue())
        with self.assertRaises(SystemExit):
            harness.parse_args(["--token", FAKE_TOKEN])

    def test_non_offline_cli_modes_fail_without_loading_credentials(self) -> None:
        for mode in ("read-only", "live-step"):
            output = io.StringIO()
            original_stdout = sys.stdout
            try:
                sys.stdout = output
                result = harness.main(["--mode", mode])
            finally:
                sys.stdout = original_stdout
            self.assertEqual(result, 3)
            self.assertIn("BLOCKED", output.getvalue())
            self.assertNotIn(FAKE_TOKEN, output.getvalue())

    def test_official_schema_has_no_reliable_account_identity_endpoint(self) -> None:
        self.assertEqual(harness.IDENTITY_ENDPOINT_FINDING, "没有找到")

    def test_production_transport_locks_host_prefix_and_finite_timeouts(self) -> None:
        transport = harness.ProductionHttpTransport(
            connect_timeout_seconds=2.0, read_timeout_seconds=3.0
        )
        self.assertEqual(harness.PRODUCTION_HOST, "open.maimemo.com")
        self.assertEqual(harness.OPEN_API_PREFIX, "/open/api/v1")
        self.assertEqual(transport.connect_timeout_seconds, 2.0)
        self.assertEqual(transport.read_timeout_seconds, 3.0)
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest("GET", "/api/v1/phrases?voc_id=INVALID")
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest("GET", "/open/api/v1/unreviewed?fixture=true")
        with self.assertRaises(harness.SafetyError):
            harness.HttpRequest("POST", "/open/api/v1/phrases/INVALID#fragment", {})
        with self.assertRaises(harness.SafetyError):
            harness.ProductionHttpTransport(connect_timeout_seconds=float("inf"))

    def test_manual_account_gate_fails_before_transport(self) -> None:
        blocked_gates = [
            harness.ManualAccountGate(False, ACCOUNT_LABEL, ""),
            harness.ManualAccountGate(True, "main", "CONFIRM SECONDARY TEST ACCOUNT: main"),
            harness.ManualAccountGate(True, ACCOUNT_LABEL, "wrong"),
        ]
        for gate in blocked_gates:
            transport = FakeTransport()
            with self.assertRaises(harness.SafetyError):
                harness.run_read_only_probe(
                    transport,
                    credential(),
                    gate,
                    "/open/api/v1/interpretations?voc_id=INVALID",
                )
            self.assertEqual(transport.requests, [])

        with self.assertRaises(harness.SafetyError):
            harness.TestAccountCredential(
                FAKE_TOKEN, ACCOUNT_LABEL, source_name="main-account"
            )

    def test_read_only_probe_uses_one_documented_get(self) -> None:
        transport = FakeTransport([harness.HttpResponse(200, {"interpretations": []})])
        result = harness.run_read_only_probe(
            transport,
            credential(),
            valid_gate(),
            "/open/api/v1/interpretations?voc_id=INVALID_VOCABULARY_ID",
        )
        self.assertEqual(result, {"status": 200, "response_keys": ["interpretations"]})
        self.assertEqual(len(transport.requests), 1)
        self.assertEqual(transport.requests[0].method, "GET")

    def test_prepare_reuses_issue2_paths_and_exact_payloads(self) -> None:
        create_step = harness.prepare_plan_step(self.plan, 1)
        phrase_step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record={
                "id": "INVALID_PHRASE_ID",
                "phrase": "OFFLINE PREVIOUS PHRASE",
            },
        )
        self.assertEqual(create_step.path, "/open/api/v1/interpretations")
        self.assertEqual(
            phrase_step.path, "/open/api/v1/phrases/INVALID_PHRASE_ID"
        )
        self.assertEqual(
            set(phrase_step.payload),
            {"phrase"},
        )
        self.assertEqual(
            set(phrase_step.payload["phrase"]),
            {"phrase", "interpretation", "tags", "origin"},
        )
        self.assertTrue(create_step.confirmation.startswith("CONFIRM WRITE STEP 1: "))
        self.assertNotIn(
            "OFFLINE PREVIOUS PHRASE",
            json.dumps(phrase_step.pre_update_snapshot),
        )
        with self.assertRaisesRegex(harness.SafetyError, "pre-write record snapshot"):
            harness.prepare_plan_step(
                self.plan, 3, phrase_record_id="INVALID_PHRASE_ID"
            )

    def test_interpretation_choice_is_fail_closed(self) -> None:
        created = harness.choose_interpretation_operation(
            "INVALID_VOCABULARY_ID", "OFFLINE NEW", []
        )
        self.assertEqual(created.operation["action"], "create_interpretation")

        updated = harness.choose_interpretation_operation(
            "INVALID_VOCABULARY_ID",
            "OFFLINE NEW",
            [harness.ExistingInterpretation("INVALID_RECORD_ID", "OFFLINE OLD", True)],
        )
        self.assertEqual(updated.operation["action"], "update_interpretation")
        self.assertEqual(
            updated.operation["path"],
            "/open/api/v1/interpretations/INVALID_RECORD_ID",
        )
        self.assertEqual(set(updated.operation["payload"]), {"interpretation", "id"})
        self.assertNotIn("OFFLINE OLD", json.dumps(updated.existing_snapshot))
        self.assertNotIn("OFFLINE NEW", json.dumps(updated.replacement_preview))

        ambiguous_sets = [
            [harness.ExistingInterpretation(None, "OFFLINE OLD", True)],
            [harness.ExistingInterpretation("INVALID_ID", "OFFLINE OLD", False)],
            [
                harness.ExistingInterpretation("INVALID_ID_1", "OFFLINE OLD 1", True),
                harness.ExistingInterpretation("INVALID_ID_2", "OFFLINE OLD 2", True),
            ],
        ]
        for existing in ambiguous_sets:
            with self.assertRaises(harness.SafetyError):
                harness.choose_interpretation_operation(
                    "INVALID_VOCABULARY_ID", "OFFLINE NEW", existing
                )

    def test_exact_confirmation_then_one_write_and_immediate_readback(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        expected = step.payload["interpretation"]
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretation": {"id": "INVALID_NEW_ID"}}),
                harness.HttpResponse(
                    200,
                    {"interpretations": [{"id": "INVALID_NEW_ID", **expected}]},
                ),
            ]
        )
        executor = harness.SingleStepExecutor(transport)
        result = executor.execute(
            step, step.confirmation, credential(), valid_gate()
        )
        self.assertEqual(result.status, "verified")
        self.assertEqual([request.method for request in transport.requests], ["POST", "GET"])
        with self.assertRaises(harness.SafetyError):
            executor.execute(step, step.confirmation, credential(), valid_gate())
        self.assertEqual(len(transport.requests), 2)

    def test_wrong_confirmation_sends_nothing(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        transport = FakeTransport()
        with self.assertRaises(harness.ConfirmationError):
            harness.SingleStepExecutor(transport).execute(
                step, "yes", credential(), valid_gate()
            )
        self.assertEqual(transport.requests, [])

    def test_uncertain_write_is_never_retried_or_read_back(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        transport = FakeTransport(error=harness.TransportError("fake timeout"))
        with self.assertRaisesRegex(harness.UnknownOutcomeError, "do not retry"):
            harness.SingleStepExecutor(transport).execute(
                step, step.confirmation, credential(), valid_gate()
            )
        self.assertEqual(len(transport.requests), 1)
        self.assertEqual(transport.requests[0].method, "POST")

    def test_update_snapshot_is_persisted_before_an_uncertain_write(self) -> None:
        step = harness.prepare_plan_step(
            self.plan,
            3,
            phrase_record_id="INVALID_PHRASE_ID",
            existing_record={
                "id": "INVALID_PHRASE_ID",
                "phrase": "OFFLINE PREVIOUS PHRASE",
                "interpretation": "OFFLINE PREVIOUS TRANSLATION",
            },
        )
        state_root = Path(
            tempfile.mkdtemp(prefix="issue9-update-", dir=harness.PRIVATE_STATE_ROOT)
        )
        try:
            class InspectingTransport(FakeTransport):
                def send(
                    self,
                    request: harness.HttpRequest,
                    test_credential: harness.TestAccountCredential,
                ) -> harness.HttpResponse:
                    prepared = state_root / "issue9-step-3.json"
                    self.assert_snapshot_saved(prepared)
                    self.requests.append(request)
                    raise harness.TransportError("fake timeout")

                @staticmethod
                def assert_snapshot_saved(path: Path) -> None:
                    content = path.read_text(encoding="utf-8")
                    if '"status": "prepared-not-sent"' not in content:
                        raise AssertionError("snapshot was not saved before transport.send")

            transport = InspectingTransport()
            with self.assertRaises(harness.UnknownOutcomeError):
                harness.SingleStepExecutor(transport).execute(
                    step,
                    step.confirmation,
                    credential(),
                    valid_gate(),
                    state_store=harness.PrivateStateStore(state_root),
                )
            content = (state_root / "issue9-step-3.json").read_text(encoding="utf-8")
            self.assertIn('"status": "write-attempted-outcome-unknown"', content)
            self.assertNotIn("OFFLINE PREVIOUS", content)
            self.assertNotIn(FAKE_TOKEN, content)
            self.assertEqual(len(transport.requests), 1)
        finally:
            shutil.rmtree(state_root)

    def test_readback_mismatch_stops_without_private_state(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretation": {"id": "INVALID_NEW_ID"}}),
                harness.HttpResponse(
                    200,
                    {
                        "interpretations": [
                            {
                                "id": "INVALID_NEW_ID",
                                **step.payload["interpretation"],
                                "status": "DRAFT",
                            }
                        ]
                    },
                ),
            ]
        )
        state_root = Path(
            tempfile.mkdtemp(prefix="issue9-mismatch-", dir=harness.PRIVATE_STATE_ROOT)
        )
        try:
            with self.assertRaises(harness.VerificationError):
                harness.SingleStepExecutor(transport).execute(
                    step,
                    step.confirmation,
                    credential(),
                    valid_gate(),
                    state_store=harness.PrivateStateStore(state_root),
                )
            self.assertEqual(list(state_root.iterdir()), [])
        finally:
            shutil.rmtree(state_root)

    def test_private_state_is_ignored_sanitized_and_contains_no_raw_content(self) -> None:
        step = harness.prepare_plan_step(self.plan, 1)
        expected = step.payload["interpretation"]
        transport = FakeTransport(
            [
                harness.HttpResponse(200, {"interpretation": {"id": "INVALID_NEW_ID"}}),
                harness.HttpResponse(
                    200,
                    {"interpretations": [{"id": "INVALID_NEW_ID", **expected}]},
                ),
            ]
        )
        state_root = Path(
            tempfile.mkdtemp(prefix="issue9-state-", dir=harness.PRIVATE_STATE_ROOT)
        )
        try:
            destination = state_root / "issue9-step-1.json"
            harness.SingleStepExecutor(transport).execute(
                step,
                step.confirmation,
                credential(),
                valid_gate(),
                state_store=harness.PrivateStateStore(state_root),
            )
            content = destination.read_text(encoding="utf-8")
            self.assertNotIn(FAKE_TOKEN, content)
            self.assertNotIn("Authorization", content)
            self.assertNotIn("OFFLINE_FIXTURE", content)
            ignored = subprocess.run(
                ["git", "check-ignore", str(destination)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(ignored.returncode, 0, ignored.stderr)
        finally:
            shutil.rmtree(state_root)

    def test_credential_is_redacted_from_repr_preview_and_error(self) -> None:
        test_credential = credential()
        self.assertNotIn(FAKE_TOKEN, repr(test_credential))
        self.assertNotIn(FAKE_TOKEN, str(test_credential))
        preview = harness.prepare_plan_step(self.plan, 1).preview()
        self.assertNotIn("OFFLINE_FIXTURE", json.dumps(preview))
        transport = FakeTransport(error=harness.TransportError(FAKE_TOKEN))
        step = harness.prepare_plan_step(self.plan, 1)
        with self.assertRaises(harness.UnknownOutcomeError) as context:
            harness.SingleStepExecutor(transport).execute(
                step, step.confirmation, test_credential, valid_gate()
            )
        self.assertNotIn(FAKE_TOKEN, str(context.exception))


if __name__ == "__main__":
    unittest.main()
