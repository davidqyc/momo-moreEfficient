"""Offline contract tests for the forgotten-words recipe."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock


RECIPE_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = RECIPE_ROOT / "fetch_words.py"
SPEC = importlib.util.spec_from_file_location("forgotten_words_fetch", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
fetch_words = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetch_words)

FAKE_TOKEN = "OBVIOUSLY_INVALID_RECIPE_TEST_TOKEN"


def item(
    voc_id: str,
    spelling: str,
    order: int,
    response: str | None,
    *,
    is_new: bool = False,
    is_finished: bool = True,
) -> dict[str, object]:
    result: dict[str, object] = {
        "voc_id": voc_id,
        "voc_spelling": spelling,
        "order": order,
        "is_new": is_new,
        "is_finished": is_finished,
    }
    if response is not None:
        result["first_response"] = response
    return result


class FakeResponse:
    def __init__(self, payload: object):
        self.raw = json.dumps(payload).encode("utf-8")

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self, limit: int) -> bytes:
        return self.raw[:limit]


class FakeOpener:
    def __init__(self, payload: object):
        self.payload = payload
        self.requests: list[tuple[object, int]] = []

    def open(self, request: object, *, timeout: int) -> FakeResponse:
        self.requests.append((request, timeout))
        return FakeResponse(self.payload)


class ForgottenWordsRecipeTests(unittest.TestCase):
    def test_selects_forget_and_excludes_other_or_missing_responses(self) -> None:
        payload = {
            "today_items": [
                item("voc-b", "brittle", 2, "FORGET"),
                item("voc-a", "allocate", 1, "VAGUE"),
                item("voc-c", "candid", 3, None, is_finished=False),
                item("voc-d", "diligent", 4, "FAMILIAR"),
            ]
        }

        self.assertEqual(
            fetch_words.select_forgotten_words(payload),
            [
                {
                    "spelling": "brittle",
                    "first_response": "FORGET",
                }
            ],
        )

    def test_selection_order_is_deterministic(self) -> None:
        payload = {
            "today_items": [
                item("voc-z", "zeal", 5, "FORGET"),
                item("voc-a", "adapt", 1, "FORGET"),
                item("voc-b", "balance", 1, "FORGET"),
            ]
        }
        self.assertEqual(
            [word["spelling"] for word in fetch_words.select_forgotten_words(payload)],
            ["adapt", "balance", "zeal"],
        )

    def test_artifact_schema_is_stable_and_machine_readable(self) -> None:
        words = [
            {
                "spelling": "adapt",
                "first_response": "FORGET",
            }
        ]
        artifact = fetch_words.build_artifact(
            words, generated_at="2026-08-15T00:00:00Z"
        )
        self.assertEqual(
            artifact,
            {
                "schema_version": 1,
                "source": "maimemo",
                "selection": "today-forgotten",
                "generated_at": "2026-08-15T00:00:00Z",
                "words": words,
            },
        )
        self.assertEqual(json.loads(json.dumps(artifact)), artifact)
        self.assertNotIn("voc_id", json.dumps(artifact))

    @unittest.skipUnless(os.name == "posix", "POSIX mode assertion")
    def test_artifact_file_uses_posix_owner_only_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "artifact.json"
            fetch_words.write_artifact(
                output,
                fetch_words.build_artifact([], generated_at="2026-08-15T00:00:00Z"),
            )
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_empty_result_is_a_successful_documented_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "empty.json"
            stdout = io.StringIO()
            with (
                mock.patch.dict("os.environ", {"MAIMEMO_TOKEN": FAKE_TOKEN}, clear=True),
                mock.patch.object(
                    fetch_words,
                    "fetch_today_items",
                    return_value={"today_items": [item("voc-a", "adapt", 1, "VAGUE")]},
                ),
                redirect_stdout(stdout),
            ):
                exit_code = fetch_words.main(["--output", str(output)])

            self.assertEqual(exit_code, 0)
            self.assertIn("nothing to generate", stdout.getvalue())
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["words"], [])

    def test_malformed_responses_fail_closed(self) -> None:
        malformed = [
            None,
            {},
            {"result": {"today_items": []}},
            {"data": None},
            {"data": {"today_items": []}, "errors": {}},
            {"data": {"today_items": []}, "success": "true"},
            {"today_items": {}},
            {"today_items": ["not-an-object"]},
            {"today_items": [item("", "adapt", 1, "FORGET")]},
            {"today_items": [item("voc-a", "bad\nword", 1, "FORGET")]},
            {"today_items": [item("voc-a", "adapt", True, "FORGET")]},
            {"today_items": [item("voc-a", "adapt", 1, "UNKNOWN")]},
        ]
        for payload in malformed:
            with self.subTest(payload=payload):
                with self.assertRaises(fetch_words.RecipeError):
                    fetch_words.select_forgotten_words(payload)

    def test_identical_duplicates_collapse_and_conflicting_duplicates_fail(self) -> None:
        duplicate = item("voc-a", "adapt", 1, "FORGET")
        selected = fetch_words.select_forgotten_words(
            {"today_items": [duplicate, dict(duplicate)]}
        )
        self.assertEqual(len(selected), 1)

        with self.assertRaises(fetch_words.RecipeError):
            fetch_words.select_forgotten_words(
                {
                    "today_items": [
                        item("voc-a", "adapt", 1, "FORGET"),
                        item("voc-a", "altered", 1, "FORGET"),
                    ]
                }
            )

    def test_fetch_uses_only_reviewed_semantic_read_request(self) -> None:
        opener = FakeOpener({"today_items": []})
        payload = fetch_words.fetch_today_items(FAKE_TOKEN, opener=opener)
        self.assertEqual(payload, {"today_items": []})
        self.assertEqual(len(opener.requests), 1)
        request, timeout = opener.requests[0]
        self.assertEqual(
            request.full_url,
            "https://open.maimemo.com/open/api/v1/study/get_today_items",
        )
        self.assertEqual(request.full_url, fetch_words.STUDY_TODAY_URL)
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(
            json.loads(request.data), {"is_finished": True, "limit": 1000}
        )
        self.assertEqual(request.get_header("Authorization"), f"Bearer {FAKE_TOKEN}")
        self.assertEqual(timeout, 30)

    def test_token_never_enters_artifact_or_error_output(self) -> None:
        opener = FakeOpener(
            {"today_items": [item("voc-a", "adapt", 1, "FORGET")]}
        )
        payload = fetch_words.fetch_today_items(FAKE_TOKEN, opener=opener)
        artifact = fetch_words.build_artifact(
            fetch_words.select_forgotten_words(payload),
            generated_at="2026-08-15T00:00:00Z",
        )
        self.assertNotIn(FAKE_TOKEN, json.dumps(artifact))

        class HostileOpener:
            def open(self, *_args: object, **_kwargs: object) -> object:
                raise RuntimeError(f"must remain private: {FAKE_TOKEN}")

        with self.assertRaises(fetch_words.RecipeError) as raised:
            fetch_words.fetch_today_items(FAKE_TOKEN, opener=HostileOpener())
        self.assertNotIn(FAKE_TOKEN, str(raised.exception))

    def test_recipe_code_contains_no_mutation_endpoint(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        forbidden = (
            "study/add_words",
            "study/advance_study",
            "/interpretations",
            "/phrases",
            "/notes",
            "/notepads",
        )
        for fragment in forbidden:
            with self.subTest(fragment=fragment):
                self.assertNotIn(fragment, source)

    def test_accepts_exact_first_party_root_and_wrapped_variants(self) -> None:
        # memo-skills uses a root collection and voc_spelling.
        root = {
            "today_items": [item("voc-a", "adapt", 1, "FORGET")],
        }
        # memo-api-cli unwraps data and its Study fixture uses spelling.
        wrapped = {
            "data": {
                "today_items": [
                    {
                        "voc_id": "voc-a",
                        "spelling": "adapt",
                        "order": 1,
                        "first_response": "FORGET",
                        "is_new": False,
                        "is_finished": True,
                    }
                ]
            },
            "errors": [],
            "success": True,
        }
        expected = [{"spelling": "adapt", "first_response": "FORGET"}]
        self.assertEqual(fetch_words.select_forgotten_words(root), expected)
        self.assertEqual(fetch_words.select_forgotten_words(wrapped), expected)

    def test_accepts_agreeing_root_wrapper_and_spelling_aliases(self) -> None:
        observed_item = item("voc-a", "adapt", 1, "FORGET")
        observed_item["spelling"] = "adapt"
        payload = {
            "today_items": [observed_item],
            "data": {"today_items": [dict(observed_item)]},
            "errors": [],
            "success": True,
        }
        self.assertEqual(
            fetch_words.select_forgotten_words(payload),
            [{"spelling": "adapt", "first_response": "FORGET"}],
        )

    def test_first_party_error_and_conflict_variants_fail_closed(self) -> None:
        valid_items = [item("voc-a", "adapt", 1, "FORGET")]
        failures = [
            {"data": {"today_items": valid_items}, "errors": [], "success": False},
            {
                "data": {"today_items": valid_items},
                "errors": [{"code": "synthetic"}],
                "success": True,
            },
            {
                "today_items": valid_items,
                "data": {"today_items": [item("voc-b", "brittle", 1, "FORGET")]},
                "errors": [],
                "success": True,
            },
            {
                "today_items": [
                    {
                        **item("voc-a", "adapt", 1, "FORGET"),
                        "spelling": "conflict",
                    }
                ]
            },
        ]
        for payload in failures:
            with self.subTest(payload=payload):
                with self.assertRaises(fetch_words.RecipeError):
                    fetch_words.select_forgotten_words(payload)

    def test_unfinished_forget_row_is_never_exported(self) -> None:
        payload = {
            "today_items": [
                item("voc-a", "adapt", 1, "FORGET", is_finished=False),
                item("voc-b", "brittle", 2, "FORGET", is_finished=True),
            ]
        }
        self.assertEqual(
            fetch_words.select_forgotten_words(payload),
            [{"spelling": "brittle", "first_response": "FORGET"}],
        )

    def test_cli_error_is_safe_and_does_not_write_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "must-not-exist.json"
            stderr = io.StringIO()
            with (
                mock.patch.dict("os.environ", {"MAIMEMO_TOKEN": FAKE_TOKEN}, clear=True),
                mock.patch.object(
                    fetch_words,
                    "fetch_today_items",
                    side_effect=fetch_words.RecipeError("safe failure"),
                ),
                redirect_stderr(stderr),
            ):
                exit_code = fetch_words.main(["--output", str(output)])
            self.assertEqual(exit_code, 1)
            self.assertFalse(output.exists())
            self.assertNotIn(FAKE_TOKEN, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
