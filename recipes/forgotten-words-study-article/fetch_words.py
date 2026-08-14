#!/usr/bin/env python3
"""Export today's Maimemo words whose first response was FORGET.

This recipe performs one documented semantic-read POST. It does not expose any
Maimemo mutation operation and never writes the credential to the artifact.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Mapping, Sequence
import urllib.error
import urllib.request


STUDY_TODAY_URL = (
    "https://open.maimemo.com/open/api/v1/study/get_today_items"
)
TOKEN_ENVIRONMENT_VARIABLE = "MAIMEMO_TOKEN"
DEFAULT_OUTPUT = "forgotten-words.json"
REQUEST_LIMIT = 1000
RESPONSE_BYTE_LIMIT = 4 * 1024 * 1024
STUDY_RESPONSES = {
    "FAMILIAR",
    "VAGUE",
    "FORGET",
    "WELL_FAMILIAR",
    "CANCEL_WELL_FAMILIAR",
}


class RecipeError(Exception):
    """A safe, user-facing failure that contains no response or credential data."""


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Keep Authorization on the one reviewed host by refusing redirects."""

    def redirect_request(  # type: ignore[override]
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Mapping[str, str],
        newurl: str,
    ) -> None:
        return None


def _default_opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(_RejectRedirects())


def _read_json_response(response: Any) -> Any:
    raw = response.read(RESPONSE_BYTE_LIMIT + 1)
    if len(raw) > RESPONSE_BYTE_LIMIT:
        raise RecipeError("Maimemo response exceeded the 4 MiB safety limit.")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RecipeError("Maimemo returned malformed JSON; no artifact was written.") from error


def fetch_today_items(token: str, *, opener: Any | None = None) -> Any:
    """Fetch today's study items with the documented semantic-read POST."""

    if not token or token != token.strip() or any(ord(char) < 32 for char in token):
        raise RecipeError(
            f"{TOKEN_ENVIRONMENT_VARIABLE} is missing or contains invalid whitespace."
        )

    body = json.dumps(
        {"is_finished": True, "limit": REQUEST_LIMIT}, separators=(",", ":")
    ).encode("utf-8")
    request = urllib.request.Request(
        STUDY_TODAY_URL,
        data=body,
        method="POST",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "momo-moreEfficient-forgotten-words-recipe/1",
        },
    )

    client = opener if opener is not None else _default_opener()
    try:
        with client.open(request, timeout=30) as response:
            return _read_json_response(response)
    except RecipeError:
        raise
    except urllib.error.HTTPError as error:
        raise RecipeError(
            f"Maimemo request failed with HTTP {error.code}; no artifact was written."
        ) from None
    except Exception:
        # Do not include the underlying exception. Network stacks can attach
        # request objects (and therefore Authorization) to exception details.
        raise RecipeError(
            "Maimemo request failed before a valid response was received; "
            "no artifact was written."
        ) from None


def _plain_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _today_items_from_observed_envelope(payload: Any) -> Any:
    """Unwrap only the root and official-CLI response shapes."""

    if not isinstance(payload, dict):
        raise RecipeError("Malformed response: expected a JSON object.")

    if "errors" in payload:
        errors = payload["errors"]
        if not isinstance(errors, list):
            raise RecipeError("Malformed response: errors must be an array.")
        if errors:
            raise RecipeError("Maimemo reported response errors; no artifact was written.")

    if "success" in payload:
        success = payload["success"]
        if not isinstance(success, bool):
            raise RecipeError("Malformed response: success must be a boolean.")
        if not success:
            raise RecipeError("Maimemo reported an unsuccessful response; no artifact was written.")

    root_claims_items = "today_items" in payload
    wrapped_claims_items = False
    wrapped_items: Any = None
    if "data" in payload:
        data = payload["data"]
        if not isinstance(data, dict):
            raise RecipeError("Malformed response: data must be an object.")
        wrapped_claims_items = "today_items" in data
        if wrapped_claims_items:
            wrapped_items = data["today_items"]

    if root_claims_items and wrapped_claims_items:
        root_items = payload["today_items"]
        if root_items != wrapped_items:
            raise RecipeError(
                "Malformed response: root and wrapped today_items disagree; "
                "no artifact was written."
            )
        return root_items
    if root_claims_items:
        return payload["today_items"]
    if wrapped_claims_items:
        return wrapped_items
    raise RecipeError("Malformed response: expected a today_items array.")


def select_forgotten_words(payload: Any) -> list[dict[str, str]]:
    """Validate the documented response and deterministically select FORGET items."""

    today_items = _today_items_from_observed_envelope(payload)
    if not isinstance(today_items, list):
        raise RecipeError("Malformed response: expected a today_items array.")

    unique: dict[str, tuple[str, int, str | None, bool, bool]] = {}
    for index, item in enumerate(today_items):
        if not isinstance(item, dict):
            raise RecipeError(f"Malformed response: today_items[{index}] is not an object.")

        voc_id = item.get("voc_id")
        has_voc_spelling = "voc_spelling" in item
        has_spelling = "spelling" in item
        if has_voc_spelling and has_spelling and item["voc_spelling"] != item["spelling"]:
            raise RecipeError(
                f"Malformed response: today_items[{index}] spelling fields disagree."
            )
        if has_voc_spelling:
            spelling = item["voc_spelling"]
        elif has_spelling:
            spelling = item["spelling"]
        else:
            spelling = None
        order = item.get("order")
        is_new = item.get("is_new")
        is_finished = item.get("is_finished")
        if not isinstance(voc_id, str) or not voc_id:
            raise RecipeError(f"Malformed response: today_items[{index}].voc_id is invalid.")
        if not isinstance(spelling, str) or not spelling:
            raise RecipeError(
                f"Malformed response: today_items[{index}].voc_spelling is invalid."
            )
        if any(ord(char) < 32 or ord(char) == 127 for char in voc_id + spelling):
            raise RecipeError(
                f"Malformed response: today_items[{index}] contains control characters."
            )
        if not _plain_integer(order) or order < 0:
            raise RecipeError(f"Malformed response: today_items[{index}].order is invalid.")
        if not isinstance(is_new, bool) or not isinstance(is_finished, bool):
            raise RecipeError(
                f"Malformed response: today_items[{index}] has invalid boolean fields."
            )

        first_response: str | None = None
        if "first_response" in item:
            first_response = item["first_response"]
            if not isinstance(first_response, str) or first_response not in STUDY_RESPONSES:
                raise RecipeError(
                    f"Malformed response: today_items[{index}].first_response is invalid."
                )

        normalized = (spelling, order, first_response, is_new, is_finished)
        previous = unique.get(voc_id)
        if previous is not None and previous != normalized:
            raise RecipeError(
                "Malformed response: duplicate voc_id entries disagree; "
                "no artifact was written."
            )
        unique[voc_id] = normalized

    forgotten = [
        {
            "spelling": spelling,
            "first_response": "FORGET",
        }
        for voc_id, (spelling, order, response, _is_new, _is_finished) in sorted(
            unique.items(), key=lambda entry: (entry[1][1], entry[1][0].casefold(), entry[0])
        )
        if response == "FORGET" and _is_finished
    ]
    return forgotten


def build_artifact(
    words: Sequence[Mapping[str, str]], *, generated_at: str | None = None
) -> dict[str, Any]:
    timestamp = generated_at or datetime.now(timezone.utc).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")
    return {
        "schema_version": 1,
        "source": "maimemo",
        "selection": "today-forgotten",
        "generated_at": timestamp,
        "words": [dict(word) for word in words],
    }


def write_artifact(path: Path, artifact: Mapping[str, Any]) -> None:
    """Atomically write JSON through a restricted temporary file."""

    path = path.expanduser()
    serialized = json.dumps(artifact, ensure_ascii=False, indent=2) + "\n"
    descriptor: int | None = None
    temporary_path: Path | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
        )
        temporary_path = Path(temporary_name)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            descriptor = None
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    except Exception:
        if descriptor is not None:
            os.close(descriptor)
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        raise RecipeError("Could not safely write the output artifact.") from None


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Export today's Maimemo words whose first response was FORGET."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(DEFAULT_OUTPUT),
        help=f"JSON destination (default: {DEFAULT_OUTPUT})",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    token = os.environ.get(TOKEN_ENVIRONMENT_VARIABLE, "")
    try:
        payload = fetch_today_items(token)
        words = select_forgotten_words(payload)
        write_artifact(args.output, build_artifact(words))
    except RecipeError as error:
        print(f"ERROR: {error}", file=os.sys.stderr)
        return 1

    if words:
        print(f"Wrote {len(words)} forgotten word(s) to {args.output}.")
    else:
        print(
            f"No forgotten words were found today. Wrote an empty artifact to {args.output}; "
            "there is nothing to generate."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
