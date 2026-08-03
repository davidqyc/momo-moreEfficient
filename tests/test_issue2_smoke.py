from __future__ import annotations

import ast
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "issue2_smoke.py"
FIXTURE = ROOT / "tests" / "fixtures" / "issue2-smoke-input.example.json"

SPEC = importlib.util.spec_from_file_location("issue2_smoke", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
issue2_smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(issue2_smoke)


class Issue2SmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.plan = issue2_smoke.build_plan(self.fixture)

    def test_plan_is_explicitly_offline(self) -> None:
        self.assertEqual(self.plan["banner"], "DRY RUN — NO REQUEST SENT")
        self.assertEqual(self.plan["mode"], "dry-run")
        self.assertEqual(self.plan["network_capability"], "absent")
        self.assertFalse(self.plan["credentials_read"])
        self.assertEqual(self.plan["network_requests_sent"], 0)

    def test_source_has_no_network_or_credential_import_path(self) -> None:
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
        imported_roots: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported_roots.update(alias.name.split(".", 1)[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported_roots.add(node.module.split(".", 1)[0])

        self.assertTrue(
            imported_roots.isdisjoint({"http", "socket", "urllib", "requests"})
        )
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("MAIMEMO_ACCESS_TOKEN", source)
        self.assertNotIn("Authorization", source)

    def test_plan_uses_one_interpretation_and_one_reused_phrase(self) -> None:
        scope = self.plan["record_scope"]
        self.assertEqual(scope["disposable_words"], 1)
        self.assertEqual(scope["interpretation_records"], 1)
        self.assertEqual(scope["phrase_records"], 1)
        self.assertTrue(scope["phrase_updates_reuse_created_record"])

        actions = [operation["action"] for operation in self.plan["operations"]]
        self.assertEqual(
            actions,
            [
                "create_interpretation",
                "create_phrase_exact_case",
                "update_phrase_inflected_case",
                "update_phrase_multiple_case",
            ],
        )

    def test_paths_include_the_documented_open_prefix(self) -> None:
        paths = [operation["path"] for operation in self.plan["operations"]]
        self.assertEqual(
            paths,
            [
                "/open/api/v1/interpretations",
                "/open/api/v1/phrases",
                "/open/api/v1/phrases/$CREATED_PHRASE_ID",
                "/open/api/v1/phrases/$CREATED_PHRASE_ID",
            ],
        )
        for path in paths:
            self.assertTrue(path.startswith("/open/api/v1/"))

    def test_payloads_match_the_reviewed_write_schema(self) -> None:
        for operation in self.plan["operations"]:
            payload_text = json.dumps(operation["payload"], ensure_ascii=False)
            self.assertNotIn("highlight", payload_text)
            self.assertNotIn("range", payload_text)

            body = operation["payload"][
                "interpretation"
                if operation["action"] == "create_interpretation"
                else "phrase"
            ]
            self.assertEqual(body["tags"], ["MBA", "BEC", "GMAT"])

        interpretation = self.plan["operations"][0]["payload"]["interpretation"]
        self.assertEqual(
            set(self.plan["operations"][0]["payload"]),
            {"interpretation"},
        )
        self.assertEqual(
            set(interpretation),
            {"voc_id", "interpretation", "tags", "status"},
        )
        self.assertEqual(interpretation["status"], "PUBLISHED")

        create_phrase_payload = self.plan["operations"][1]["payload"]
        self.assertEqual(set(create_phrase_payload), {"phrase"})
        self.assertEqual(
            set(create_phrase_payload["phrase"]),
            {"voc_id", "phrase", "interpretation", "tags", "origin"},
        )

        for operation in self.plan["operations"][2:]:
            self.assertEqual(set(operation["payload"]), {"phrase"})
            self.assertEqual(
                set(operation["payload"]["phrase"]),
                {"phrase", "interpretation", "tags", "origin"},
            )

        for operation in self.plan["operations"][1:]:
            self.assertEqual(
                operation["payload"]["phrase"]["origin"],
                "OFFLINE_FIXTURE_ONLY",
            )

    def test_shared_interpretation_builder_locks_update_schema(self) -> None:
        operation = issue2_smoke.build_interpretation_operation(
            "INVALID_VOCABULARY_ID",
            "OFFLINE FIXTURE INTERPRETATION",
            existing_id="INVALID_INTERPRETATION_ID",
        )
        self.assertEqual(
            operation["path"],
            "/open/api/v1/interpretations/INVALID_INTERPRETATION_ID",
        )
        self.assertEqual(set(operation["payload"]), {"interpretation", "id"})
        self.assertEqual(
            set(operation["payload"]["interpretation"]),
            {"interpretation", "tags", "status"},
        )
        self.assertEqual(operation["payload"]["id"], "INVALID_INTERPRETATION_ID")

    def test_fixture_rejects_real_looking_vocabulary_id(self) -> None:
        self.fixture["vocabulary"]["id"] = "5a7BFf4F63612e5AD9fdebB7a50D3881"
        with self.assertRaisesRegex(issue2_smoke.FixtureError, "must start with INVALID_"):
            issue2_smoke.build_plan(self.fixture)

    def test_fixture_rejects_undocumented_write_fields(self) -> None:
        self.fixture["phrase"]["cases"][0]["highlight"] = [{"start": 4, "end": 14}]
        with self.assertRaisesRegex(issue2_smoke.FixtureError, "unexpected"):
            issue2_smoke.build_plan(self.fixture)

    def test_cli_does_not_echo_environment_token(self) -> None:
        fake_token = "OFFLINE_TEST_TOKEN_MUST_NOT_APPEAR"
        environment = os.environ.copy()
        environment["MAIMEMO_ACCESS_TOKEN"] = fake_token
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--input", str(FIXTURE)],
            cwd=ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("DRY RUN — NO REQUEST SENT", completed.stdout)
        self.assertNotIn(fake_token, completed.stdout)
        self.assertEqual(completed.stderr, "")

    def test_main_fails_closed_for_invalid_fixture(self) -> None:
        output = io.StringIO()
        invalid_path = ROOT / "tests" / "fixtures" / "does-not-exist.json"
        original_stdout = sys.stdout
        try:
            sys.stdout = output
            return_code = issue2_smoke.main(["--input", str(invalid_path)])
        finally:
            sys.stdout = original_stdout
        self.assertEqual(return_code, 2)
        self.assertIn("ERROR:", output.getvalue())


if __name__ == "__main__":
    unittest.main()
