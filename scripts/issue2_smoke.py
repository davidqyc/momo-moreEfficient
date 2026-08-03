#!/usr/bin/env python3
"""Build the Issue #2 smoke-test plan without performing network I/O.

This stage is intentionally incapable of reading credentials or sending HTTP
requests. It accepts only clearly invalid fixture identifiers and prints the
schema-derived payloads that a later, separately approved live tool may use.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, NoReturn


BANNER = "DRY RUN — NO REQUEST SENT"
REQUIRED_TAGS = ("MBA", "BEC", "GMAT")
REQUIRED_CASES = ("exact", "inflected", "multiple")
INVALID_ID_PREFIX = "INVALID_"
CREATED_PHRASE_ID = "$CREATED_PHRASE_ID"
OPEN_API_PREFIX = "/open/api/v1"


class FixtureError(ValueError):
    """Raised when an offline fixture violates the narrow smoke-test schema."""


def _fail(message: str) -> NoReturn:
    raise FixtureError(message)


def _require_object(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail(f"{path} must be an object")
    return value


def _require_exact_keys(
    value: dict[str, Any], expected: set[str], path: str
) -> None:
    actual = set(value)
    if actual == expected:
        return

    problems: list[str] = []
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing:
        problems.append(f"missing {missing}")
    if unexpected:
        problems.append(f"unexpected {unexpected}")
    _fail(f"{path} has invalid fields: {', '.join(problems)}")


def _require_text(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(f"{path} must be a non-empty string")
    return value


def load_fixture(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
        parsed = json.loads(raw)
    except OSError as exc:
        raise FixtureError(f"cannot read fixture: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise FixtureError(f"fixture is not valid JSON: {exc}") from exc
    return validate_fixture(parsed)


def validate_fixture(value: Any) -> dict[str, Any]:
    fixture = _require_object(value, "fixture")
    _require_exact_keys(
        fixture,
        {"fixture_only", "vocabulary", "interpretation", "phrase"},
        "fixture",
    )
    if fixture["fixture_only"] is not True:
        _fail("fixture.fixture_only must be true")

    vocabulary = _require_object(fixture["vocabulary"], "fixture.vocabulary")
    _require_exact_keys(vocabulary, {"id", "spelling"}, "fixture.vocabulary")
    vocabulary_id = _require_text(vocabulary["id"], "fixture.vocabulary.id")
    if not vocabulary_id.startswith(INVALID_ID_PREFIX):
        _fail(
            "fixture.vocabulary.id must start with INVALID_; real-looking IDs "
            "are rejected in the offline stage"
        )
    _require_text(vocabulary["spelling"], "fixture.vocabulary.spelling")

    interpretation = _require_object(
        fixture["interpretation"], "fixture.interpretation"
    )
    _require_exact_keys(interpretation, {"text"}, "fixture.interpretation")
    _require_text(interpretation["text"], "fixture.interpretation.text")

    phrase = _require_object(fixture["phrase"], "fixture.phrase")
    _require_exact_keys(phrase, {"origin", "cases"}, "fixture.phrase")
    _require_text(phrase["origin"], "fixture.phrase.origin")
    cases = phrase["cases"]
    if not isinstance(cases, list):
        _fail("fixture.phrase.cases must be an array")
    if len(cases) != len(REQUIRED_CASES):
        _fail(
            "fixture.phrase.cases must contain exactly the exact, inflected, "
            "and multiple cases"
        )

    names: list[str] = []
    for index, raw_case in enumerate(cases):
        case_path = f"fixture.phrase.cases[{index}]"
        case = _require_object(raw_case, case_path)
        _require_exact_keys(case, {"name", "text", "translation"}, case_path)
        names.append(_require_text(case["name"], f"{case_path}.name"))
        _require_text(case["text"], f"{case_path}.text")
        _require_text(case["translation"], f"{case_path}.translation")

    if tuple(names) != REQUIRED_CASES:
        _fail(
            "fixture.phrase.cases must be ordered as exact, inflected, multiple"
        )
    return fixture


def _phrase_fields(case: dict[str, Any], origin: str) -> dict[str, Any]:
    return {
        "phrase": case["text"],
        "interpretation": case["translation"],
        "tags": list(REQUIRED_TAGS),
        "origin": origin,
    }


def build_plan(fixture: dict[str, Any]) -> dict[str, Any]:
    validated = validate_fixture(fixture)
    vocabulary = validated["vocabulary"]
    interpretation = validated["interpretation"]
    phrase = validated["phrase"]
    cases = phrase["cases"]

    operations: list[dict[str, Any]] = [
        {
            "sequence": 1,
            "action": "create_interpretation",
            "method": "POST",
            "path": f"{OPEN_API_PREFIX}/interpretations",
            "payload": {
                "interpretation": {
                    "voc_id": vocabulary["id"],
                    "interpretation": interpretation["text"],
                    "tags": list(REQUIRED_TAGS),
                    "status": "PUBLISHED",
                }
            },
            "future_live_guard": "preview, confirm, then read back by voc_id",
        },
        {
            "sequence": 2,
            "action": "create_phrase_exact_case",
            "method": "POST",
            "path": f"{OPEN_API_PREFIX}/phrases",
            "payload": {
                "phrase": {
                    "voc_id": vocabulary["id"],
                    **_phrase_fields(cases[0], phrase["origin"]),
                }
            },
            "future_live_guard": "preview, confirm, capture id, then read back",
        },
    ]

    for sequence, case in enumerate(cases[1:], start=3):
        operations.append(
            {
                "sequence": sequence,
                "action": f"update_phrase_{case['name']}_case",
                "method": "POST",
                "path": f"{OPEN_API_PREFIX}/phrases/{CREATED_PHRASE_ID}",
                "payload": {
                    "phrase": _phrase_fields(case, phrase["origin"]),
                },
                "future_live_guard": (
                    "substitute the captured id, preview, confirm, then read back"
                ),
            }
        )

    return {
        "banner": BANNER,
        "mode": "dry-run",
        "network_capability": "absent",
        "credentials_read": False,
        "network_requests_sent": 0,
        "record_scope": {
            "disposable_words": 1,
            "interpretation_records": 1,
            "phrase_records": 1,
            "phrase_updates_reuse_created_record": True,
        },
        "vocabulary": vocabulary,
        "schema_findings": {
            "caller_writable_tags": True,
            "caller_writable_origin": True,
            "caller_writable_english_highlight": False,
            "caller_writable_chinese_range": False,
            "runtime_and_app_behavior_verified": False,
        },
        "operations": operations,
        "manual_live_checks_remaining": [
            "server acceptance of MBA, BEC, and GMAT together",
            "partner-account discovery through each tag",
            "server-returned English highlight for every phrase case",
            "origin round-trip and app display",
            "Chinese character-range support remains undocumented",
        ],
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Print the offline Issue #2 dry-run plan. No HTTP code exists."
    )
    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="path to a fixture-only JSON input",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        plan = build_plan(load_fixture(args.input))
    except FixtureError as exc:
        print(f"ERROR: {exc}")
        return 2

    print(BANNER)
    print(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
