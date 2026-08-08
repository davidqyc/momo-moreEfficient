"""Issue #32/#39/#51 — the small-batch interpretation importer.

Every test here runs offline against an injected fake transport, under the
process-level no-network guard, with an obviously fake credential. No real
Maimemo request is possible and no real Token is read.

The suite is organized around the product contract rather than around functions:
the parser never rewrites the owner's text; the whole batch is preflighted before
any write can exist; a dry-run cannot POST at all; a create batch is bound to one
confirmation and structurally capped at one POST per item with no retry; an
uncertain POST is resolved GET-only; and the first write-phase failure stops the
remaining batch without rollback. Every emitted field is a project-owned closed
enum, a bounded count, a boolean, owner-provided content or a fingerprint — so a
hostile production response, a raw voc_id, a raw record id or the Token can never
escape through stdout, stderr, a repr, a traceback or the local report.

Issue #39 adds update mode under the same contract: exactly one existing
authenticated-user record per item, the target id chosen only from the
authenticated GET, an already-matching item as a satisfied zero-request no-op, a
whole-batch abort before the first POST if anything is blocked, a confirmation
bound to the exact pre-update snapshot, one POST to `/interpretations/{id}` with
no voc_id and no retry, a same-record strict readback, and a private report that
keeps the replaced text for MANUAL restoration without ever keeping a raw id.

Issue #51 adds the explicit main-account opt-in beside all of that, and the tests
are written to prove it is a SEPARATE path rather than a relaxed one: the frozen
secondary label policy, preview line and CREATE/UPDATE confirmation strings are
re-asserted byte for byte; main-account mode needs both `--allow-main-account`
and a reviewed main-account label, and either one alone fails closed before a
Token prompt or a transport exists; neither account mode's confirmation or
credential can satisfy the other; and the main path reuses the same one-POST /
no-retry / immediate-readback machinery rather than a second copy of it.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import re
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
import interpretation_batch_importer as importer  # noqa: E402


FAKE_TOKEN = "FAKE_ISSUE32_CREDENTIAL_NOT_VALID"
ACCOUNT_LABEL = "issue32-secondary-test"
# Issue #51 — the explicit main-account opt-in. The Token is as obviously fake as
# the secondary one; no real credential is ever read by this suite.
MAIN_TOKEN = "FAKE_ISSUE51_MAIN_CREDENTIAL_NOT_VALID"
MAIN_LABEL = "主账号"
MAIN_LABELS = ("主账号", "main-account", "MAIN-ACCOUNT")
VOC_A = "INVALID_ISSUE32_VOC_A"
VOC_B = "INVALID_ISSUE32_VOC_B"
VOC_C = "INVALID_ISSUE32_VOC_C"
RECORD_A = "INVALID_ISSUE32_RECORD_A"
RECORD_B = "INVALID_ISSUE32_RECORD_B"
RECORD_C = "INVALID_ISSUE32_RECORD_C"
OTHER_RECORD = "INVALID_ISSUE32_OTHER_RECORD"

# Hostile values a production response, a server key name or an external library
# exception could carry. None may appear in ordinary output, the report, a
# repr/str or a formatted traceback.
SERVER_KEY = "PRIVATE-ISSUE32-UNKNOWN-SERVER-KEY-SENTINEL"
SERVER_VALUE = "PRIVATE ISSUE32 SERVER VALUE SENTINEL"
TRANSPORT_SENTINEL = "PRIVATE-ISSUE32-TRANSPORT-EXCEPTION-SENTINEL"
UNSAFE_ID = "PRIVATE.ISSUE32/RECORD ID+SENTINEL"
RAW_IDS = (VOC_A, VOC_B, VOC_C, RECORD_A, RECORD_B, RECORD_C, OTHER_RECORD)
SENTINELS = (FAKE_TOKEN, SERVER_KEY, SERVER_VALUE, TRANSPORT_SENTINEL, UNSAFE_ID) + RAW_IDS

SPELLING_A, TEXT_A = "acquisition", "n. 收购；购置；获得"
SPELLING_B, TEXT_B = "leverage", "n. 杠杆作用\nv. 利用；借助"
SPELLING_C, TEXT_C = "amortization", "n. 摊销；分期偿还"
# The pre-update state of an existing authenticated-user custom interpretation.
OLD_A = "n. 收购（旧版释义）"
OLD_B = "n. 杠杆（旧版释义）"
OLD_TAGS = ["考研"]
TWO_ENTRY_DOCUMENT = (
    f"## {SPELLING_A}\n{TEXT_A}\n\n## {SPELLING_B}\n{TEXT_B}\n"
)
THREE_ENTRY_DOCUMENT = TWO_ENTRY_DOCUMENT + f"\n## {SPELLING_C}\n{TEXT_C}\n"

VOCABULARY_PATH = "/open/api/v1/vocabulary"
INTERPRETATIONS_PATH = "/open/api/v1/interpretations"


def voc_response(vocabulary_id, spelling, status=200):
    return harness.HttpResponse(status, {"voc": {"id": vocabulary_id, "spelling": spelling}})


def wrapped_voc_response(vocabulary_id, spelling):
    """The observed production `data.voc` compatibility envelope."""
    return harness.HttpResponse(
        200, {"data": {"voc": {"id": vocabulary_id, "spelling": spelling}}}
    )


def record(record_id, text, *, tags=None, status="PUBLISHED"):
    return {
        "id": record_id,
        "interpretation": text,
        # Server ordering is deliberately different from the intended tuple.
        "tags": list(tags) if tags is not None else ["GMAT", "MBA", "BEC"],
        "status": status,
    }


def collection(records, status=200):
    return harness.HttpResponse(status, {"interpretations": list(records)})


def wrapped_collection(records):
    """The observed production `data.interpretations` compatibility envelope."""
    return harness.HttpResponse(200, {"data": {"interpretations": list(records)}})


class FakeTransport:
    """Queued in-memory transport. It never touches a socket."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.payloads = []

    def send(self, request, _credential):
        self.requests.append(request)
        self.payloads.append(
            None if request.payload is None else harness._thaw_json(request.payload)
        )
        if not self.responses:
            raise AssertionError("the fake transport received an unexpected request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response

    def calls(self):
        return [(request.method, request.path) for request in self.requests]

    def methods(self):
        return [request.method for request in self.requests]


class ImporterFixtures:
    """Shared offline plumbing: fake credential, fake transport, recorded output."""

    def setUp(self):
        super().setUp()
        self.credential = harness.TestAccountCredential(FAKE_TOKEN, ACCOUNT_LABEL)
        self.slept = []
        self.confirmations = []

    def entries(self, document=TWO_ENTRY_DOCUMENT):
        return importer.parse_batch(document)

    def preflight_pair(self, first_records=(), second_records=()):
        return [
            voc_response(VOC_A, SPELLING_A),
            collection(first_records),
            voc_response(VOC_B, SPELLING_B),
            collection(second_records),
        ]

    def confirm(self, plan):
        self.confirmations.append(plan.expected_confirmation)
        return plan.expected_confirmation

    def drive(
        self,
        responses,
        *,
        mode=importer.MODE_DRY_RUN,
        document=TWO_ENTRY_DOCUMENT,
        confirm=None,
        report=None,
        now=None,
    ):
        transport = FakeTransport(responses)
        lines = []
        result = importer.run_batch(
            mode=mode,
            entries=self.entries(document),
            transport=transport,
            credential=self.credential,
            account_label=ACCOUNT_LABEL,
            confirm=confirm if confirm is not None else self.confirm,
            emit=lines.append,
            sleep=self.slept.append,
            report=report,
            now=now,
        )
        return result, transport, "\n".join(lines)

    def private_report(self):
        """A BatchRunReport rooted in a temporary private directory."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / "private"
        patch = mock.patch.object(harness, "PRIVATE_STATE_ROOT", root)
        patch.start()
        self.addCleanup(patch.stop)
        return importer.BatchRunReport(root)


# --------------------------------------------------------------------------- #
# Parser
# --------------------------------------------------------------------------- #


class ParserTests(ImporterFixtures, unittest.TestCase):
    def test_one_entry_parses_into_one_frozen_record(self):
        entries = importer.parse_batch(f"## {SPELLING_A}\n{TEXT_A}\n")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].ordinal, 1)
        self.assertEqual(entries[0].spelling, SPELLING_A)
        self.assertEqual(entries[0].interpretation, TEXT_A)
        with self.assertRaises(Exception):
            entries[0].spelling = "changed"

    def test_fifteen_entries_keep_their_input_order(self):
        document = "".join(f"## word{index}\nn. 释义 {index}\n\n" for index in range(1, 16))
        entries = importer.parse_batch(document)
        self.assertEqual(len(entries), 15)
        self.assertEqual([entry.ordinal for entry in entries], list(range(1, 16)))
        self.assertEqual([entry.spelling for entry in entries],
                         [f"word{index}" for index in range(1, 16)])
        self.assertEqual(entries[14].interpretation, "n. 释义 15")

    def test_multi_line_interpretations_are_preserved_exactly(self):
        body = "n. 杠杆作用\n\nv. 利用；借助\n   缩进保留"
        entries = importer.parse_batch(f"## {SPELLING_B}\n{body}\n\n")
        self.assertEqual(entries[0].interpretation, body)
        self.assertIn("\n\n", entries[0].interpretation)
        self.assertTrue(entries[0].interpretation.endswith("   缩进保留"))

    def test_only_the_outer_newline_boundary_is_normalized(self):
        entries = importer.parse_batch(
            f"\n\n## {SPELLING_B}\r\n{TEXT_B}\r\n\r\n\r\n"
        )
        self.assertEqual(entries[0].interpretation, TEXT_B)

    def test_malformed_headings_are_rejected_with_a_line_number(self):
        for document, line in (
            (f"# {SPELLING_A}\n{TEXT_A}\n", 1),
            (f"### {SPELLING_A}\n{TEXT_A}\n", 1),
            (f"##{SPELLING_A}\n{TEXT_A}\n", 1),
            ("## \nbody\n", 1),
            (f"## {SPELLING_A}\n{TEXT_A}\n#### x\nbody\n", 3),
        ):
            with self.subTest(document=document.splitlines()[0]):
                with self.assertRaises(importer.BatchFormatError) as context:
                    importer.parse_batch(document)
                self.assertEqual(context.exception.reason, "malformed-heading")
                self.assertEqual(context.exception.line, line)

    def test_empty_interpretations_are_rejected(self):
        for document in (
            f"## {SPELLING_A}\n",
            f"## {SPELLING_A}\n\n\n## {SPELLING_B}\n{TEXT_B}\n",
            f"## {SPELLING_A}\n   \n\t\n",
        ):
            with self.subTest(document=document):
                with self.assertRaises(importer.BatchFormatError) as context:
                    importer.parse_batch(document)
                self.assertEqual(context.exception.reason, "empty-interpretation")

    def test_duplicate_spellings_are_rejected_case_insensitively(self):
        for second in (SPELLING_A, SPELLING_A.upper(), SPELLING_A.capitalize()):
            with self.subTest(second=second):
                with self.assertRaises(importer.BatchFormatError) as context:
                    importer.parse_batch(
                        f"## {SPELLING_A}\n{TEXT_A}\n\n## {second}\n{TEXT_B}\n"
                    )
                self.assertEqual(context.exception.reason, "duplicate-spelling")
                self.assertEqual(context.exception.line, 4)

    def test_thirty_entries_are_accepted_and_thirty_one_are_rejected(self):
        def document(count):
            return "".join(f"## word{index}\nn. 释义\n\n" for index in range(count))

        self.assertEqual(len(importer.parse_batch(document(30))), 30)
        with self.assertRaises(importer.BatchFormatError) as context:
            importer.parse_batch(document(31))
        self.assertEqual(context.exception.reason, "batch-too-large")

    def test_structurally_empty_documents_and_stray_content_are_rejected(self):
        with self.assertRaises(importer.BatchFormatError) as empty:
            importer.parse_batch("\n\n   \n")
        self.assertEqual(empty.exception.reason, "empty-document")
        with self.assertRaises(importer.BatchFormatError) as stray:
            importer.parse_batch(f"stray note\n## {SPELLING_A}\n{TEXT_A}\n")
        self.assertEqual(stray.exception.reason, "content-before-first-heading")
        self.assertEqual(stray.exception.line, 1)

    def test_unsafe_spellings_and_interpretations_are_rejected_not_rewritten(self):
        with self.assertRaises(importer.BatchFormatError) as spelling:
            importer.parse_batch(f"## {'a' * 300}\n{TEXT_A}\n")
        self.assertEqual(spelling.exception.reason, "spelling-policy")
        with self.assertRaises(importer.BatchFormatError) as control:
            importer.parse_batch(f"## {SPELLING_A}\nn. 收购\x07\n")
        self.assertEqual(control.exception.reason, "interpretation-policy")
        with self.assertRaises(importer.BatchFormatError) as oversized:
            importer.parse_batch(f"## {SPELLING_A}\n{'释' * 2100}\n")
        self.assertEqual(oversized.exception.reason, "interpretation-policy")

    def test_a_parse_rejection_never_echoes_the_offending_content(self):
        with self.assertRaises(importer.BatchFormatError) as context:
            importer.parse_batch(f"## {SPELLING_A}\n{TEXT_A}\n\n## {SPELLING_A}\n{TEXT_B}\n")
        rendered = str(context.exception) + repr(context.exception) + "".join(
            traceback.format_exception_only(type(context.exception), context.exception)
        )
        for fragment in (TEXT_A, TEXT_B, SPELLING_A):
            self.assertNotIn(fragment, rendered)
        self.assertIn("duplicate-spelling", rendered)
        self.assertIn("line 4", rendered)

    def test_load_batch_reads_one_small_utf8_file_and_fails_closed_otherwise(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "batch.md"
            path.write_text(TWO_ENTRY_DOCUMENT, encoding="utf-8")
            self.assertEqual(len(importer.load_batch(path)), 2)
            for bad in (Path(directory) / "missing.md", Path(directory)):
                with self.subTest(bad=bad.name):
                    with self.assertRaises(importer.BatchFormatError) as context:
                        importer.load_batch(bad)
                    self.assertEqual(context.exception.reason, "input-unreadable")
            oversized = Path(directory) / "big.md"
            oversized.write_text("#" * (importer.MAX_INPUT_BYTES + 1), encoding="utf-8")
            with self.assertRaises(importer.BatchFormatError) as context:
                importer.load_batch(oversized)
            self.assertEqual(context.exception.reason, "input-unreadable")

    def test_the_batch_digest_binds_order_content_and_size(self):
        base = importer.batch_digest(self.entries())
        reordered = importer.parse_batch(
            f"## {SPELLING_B}\n{TEXT_B}\n\n## {SPELLING_A}\n{TEXT_A}\n"
        )
        edited = importer.parse_batch(
            f"## {SPELLING_A}\n{TEXT_A}。\n\n## {SPELLING_B}\n{TEXT_B}\n"
        )
        self.assertRegex(base, r"^[0-9a-f]{64}$")
        self.assertNotEqual(base, importer.batch_digest(reordered))
        self.assertNotEqual(base, importer.batch_digest(edited))
        self.assertEqual(base, importer.batch_digest(self.entries()))


# --------------------------------------------------------------------------- #
# Dry-run
# --------------------------------------------------------------------------- #


class DryRunTests(ImporterFixtures, unittest.TestCase):
    def test_the_dry_run_sends_exactly_two_gets_per_item_and_no_write(self):
        result, transport, output = self.drive(self.preflight_pair())
        self.assertEqual(transport.calls(), [
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_A}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
        ])
        self.assertEqual(transport.methods(), ["GET"] * 4)
        self.assertEqual((result.get_count, result.post_count), (4, 0))
        self.assertEqual(result.status, "ready")
        self.assertIn("READY 2", output)
        self.assertIn("BLOCKED 0", output)
        self.assertIn("WRITES 0", output)

    def test_the_dry_run_accepts_the_observed_data_wrappers(self):
        result, transport, _output = self.drive([
            wrapped_voc_response(VOC_A, SPELLING_A),
            wrapped_collection([]),
            wrapped_voc_response(VOC_B, SPELLING_B),
            wrapped_collection([record(OTHER_RECORD, "n. 别的释义")]),
        ])
        self.assertEqual(len(transport.calls()), 4)
        self.assertEqual([item.state for item in result.preflight],
                         [importer.READY_CREATE, importer.BLOCK_EXISTING])

    def test_a_dry_run_can_never_arm_or_dispatch_a_post(self):
        guard = importer.BatchWriteGuard(
            FakeTransport([]), max_gets=4, max_posts=0, sleep=self.slept.append
        )
        self.assertFalse(guard.posts_allowed)
        with self.assertRaises(harness.SafetyError):
            guard.arm(1)
        with self.assertRaises(harness.SafetyError):
            guard.send(
                harness.HttpRequest(
                    "POST", importer.CREATE_PATH, importer.create_body(VOC_A, TEXT_A)
                ),
                self.credential,
            )
        self.assertEqual((guard.get_count, guard.post_count), (0, 0))

    def test_preflight_classifies_zero_one_and_many_existing_interpretations(self):
        cases = (
            ([], importer.READY_CREATE, 0),
            ([record(RECORD_A, TEXT_A)], importer.BLOCK_EXISTING, 1),
            ([record(RECORD_A, TEXT_A), record(RECORD_B, "n. 另一条")],
             importer.BLOCK_AMBIGUOUS, 2),
        )
        for records, state, count in cases:
            with self.subTest(state=state):
                result, _transport, output = self.drive(
                    self.preflight_pair(second_records=records)
                )
                self.assertEqual(result.preflight[1].state, state)
                self.assertEqual(result.preflight[1].existing_count, count)
                self.assertEqual(result.status, "ready" if count == 0 else "blocked")
                self.assertIn(importer._STATE_LABELS[state], output)

    def test_every_preflight_failure_class_is_reported_without_server_content(self):
        cases = (
            ([harness.TransportError(TRANSPORT_SENTINEL)], "transport", None),
            ([harness.HttpResponse(503, {SERVER_KEY: SERVER_VALUE})], "http-status", 503),
            ([harness.HttpResponse(200, {SERVER_KEY: SERVER_VALUE})], "schema", 200),
            ([voc_response(VOC_A, SPELLING_A),
              harness.HttpResponse(200, {"interpretations": SERVER_VALUE})], "schema", 200),
            ([voc_response(UNSAFE_ID, SPELLING_A)], "schema", 200),
            ([voc_response(VOC_A, "different-word")], "schema", 200),
        )
        for responses, error_class, status in cases:
            with self.subTest(error_class=error_class, count=len(responses)):
                tail = [voc_response(VOC_B, SPELLING_B), collection([])]
                result, _transport, output = self.drive(list(responses) + tail)
                first = result.preflight[0]
                self.assertEqual(first.state, importer.BLOCK_ERROR)
                self.assertEqual(first.error_class, error_class)
                self.assertEqual(first.http_status, status)
                self.assertEqual(result.status, "blocked")
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, output)

    def test_the_preview_shows_owner_content_states_and_fingerprints_only(self):
        _result, _transport, output = self.drive(
            self.preflight_pair(second_records=[record(RECORD_B, "n. 已存在")])
        )
        self.assertIn(SPELLING_A, output)
        self.assertIn(TEXT_A, output)
        for line in TEXT_B.split("\n"):
            self.assertIn(line, output)
        self.assertIn("MBA BEC GMAT", output)
        self.assertIn("PUBLISHED", output)
        self.assertIn("account [REDACTED]", output)
        self.assertIn(importer._short_fingerprint(VOC_A), output)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, output)

    def test_the_whole_batch_is_preflighted_even_when_an_early_item_blocks(self):
        result, transport, _output = self.drive(
            [harness.TransportError(TRANSPORT_SENTINEL)]
            + [voc_response(VOC_B, SPELLING_B), collection([])],
            document=TWO_ENTRY_DOCUMENT,
        )
        self.assertEqual(len(result.preflight), 2)
        self.assertEqual(result.preflight[0].state, importer.BLOCK_ERROR)
        self.assertEqual(result.preflight[1].state, importer.READY_CREATE)
        self.assertEqual(len(transport.calls()), 3)

    def test_the_dry_run_report_records_zero_write_attempts(self):
        report = self.private_report()
        result, _transport, output = self.drive(
            self.preflight_pair(second_records=[record(RECORD_B, "n. 已存在")]),
            report=report,
        )
        document = json.loads(result.report_path.read_text(encoding="utf-8"))
        self.assertEqual(document["mode"], importer.MODE_DRY_RUN)
        self.assertEqual(document["post_count"], 0)
        self.assertEqual(document["retries"], 0)
        self.assertEqual([item["post_attempted"] for item in document["items"]],
                         [False, False])
        self.assertEqual([item["preflight"] for item in document["items"]],
                         [importer.READY_CREATE, importer.BLOCK_EXISTING])
        self.assertEqual(document["items"][0]["interpretation"], TEXT_A)
        self.assertEqual(document["items"][0]["tags"], ["MBA", "BEC", "GMAT"])
        self.assertEqual(document["items"][0]["status"], "PUBLISHED")
        self.assertIn(str(result.report_path), output)


# --------------------------------------------------------------------------- #
# Create
# --------------------------------------------------------------------------- #


class CreateTests(ImporterFixtures, unittest.TestCase):
    def created(self, records=None, *, post_status=201, second_records=None):
        """Responses for a clean two-item create batch."""
        first = records if records is not None else [record(RECORD_A, TEXT_A)]
        second = second_records if second_records is not None else [record(RECORD_B, TEXT_B)]
        return self.preflight_pair() + [
            harness.HttpResponse(post_status, {}),
            collection(first),
            harness.HttpResponse(post_status, {}),
            collection(second),
        ]

    def test_a_clean_batch_posts_the_exact_documented_body_for_each_item(self):
        result, transport, output = self.drive(self.created(), mode=importer.MODE_CREATE)
        self.assertEqual(result.status, "verified")
        self.assertEqual(result.verified_count, 2)
        self.assertIn("VERIFIED 2/2", output)
        posts = [payload for payload in transport.payloads if payload is not None]
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[0], {"interpretation": {
            "voc_id": VOC_A, "interpretation": TEXT_A,
            "tags": ["MBA", "BEC", "GMAT"], "status": "PUBLISHED",
        }})
        self.assertEqual(posts[1]["interpretation"]["interpretation"], TEXT_B)
        for payload in posts:
            entity = payload["interpretation"]
            self.assertEqual(set(entity), set(importer.BODY_FIELDS))
            self.assertEqual(entity["tags"], ["MBA", "BEC", "GMAT"])
            self.assertEqual(entity["status"], "PUBLISHED")

    def test_the_write_sequence_is_post_then_readback_per_item_in_input_order(self):
        _result, transport, _output = self.drive(self.created(), mode=importer.MODE_CREATE)
        self.assertEqual(transport.calls(), [
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_A}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
            ("POST", INTERPRETATIONS_PATH),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("POST", INTERPRETATIONS_PATH),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
        ])

    def test_one_blocked_item_blocks_the_whole_batch_before_the_first_post(self):
        for records, state in (
            ([record(RECORD_B, TEXT_B)], importer.BLOCK_EXISTING),
            ([record(RECORD_B, TEXT_B), record(OTHER_RECORD, "n. 另一条")],
             importer.BLOCK_AMBIGUOUS),
        ):
            with self.subTest(state=state):
                result, transport, output = self.drive(
                    self.preflight_pair(second_records=records),
                    mode=importer.MODE_CREATE,
                )
                self.assertEqual(result.status, "blocked")
                self.assertEqual(result.post_count, 0)
                self.assertEqual(transport.methods(), ["GET"] * 4)
                self.assertEqual(result.outcomes, ())
                self.assertIn("ABORTED BEFORE THE FIRST POST", output)
                self.assertIn("WRITES 0", output)
                self.assertEqual(self.confirmations, [])

    def test_a_preflight_error_also_blocks_the_batch_before_any_post(self):
        result, transport, output = self.drive(
            self.preflight_pair()[:2] + [harness.TransportError(TRANSPORT_SENTINEL),
                                        voc_response(VOC_B, SPELLING_B)],
            mode=importer.MODE_CREATE,
        )
        self.assertEqual(result.status, "blocked")
        self.assertEqual(result.post_count, 0)
        self.assertNotIn("POST", transport.methods())
        self.assertIn("ABORTED BEFORE THE FIRST POST", output)

    def test_exactly_one_batch_confirmation_covers_the_whole_batch(self):
        result, _transport, output = self.drive(
            self.created(), mode=importer.MODE_CREATE, document=TWO_ENTRY_DOCUMENT
        )
        self.assertEqual(len(self.confirmations), 1)
        self.assertEqual(result.status, "verified")
        confirmation = self.confirmations[0]
        self.assertTrue(confirmation.startswith(importer.CONFIRMATION_PREFIX))
        self.assertIn("ITEMS: 2", confirmation)
        self.assertIn(f"TOKEN-FP: {self.credential.fingerprint}", confirmation)
        self.assertIn(harness.WRITE_PRICING_TERMS_CLAUSE, confirmation)
        self.assertIn(importer.BATCH_ONE_POST_CLAUSE, confirmation)
        self.assertIn(confirmation, output)
        self.assertIn(importer.PRICING_TERMS_GATE, output)

    def test_the_displayed_confirmation_line_is_pasteable_without_editing(self):
        plan = self.plan()
        lines = importer.confirmation_lines(plan)
        displayed = [line for line in lines if importer.CONFIRMATION_PREFIX in line]
        self.assertEqual(len(displayed), 1)
        shown = displayed[0]
        # What the owner sees is byte-for-byte what validation demands: copying
        # the line literally must not need trimming, unquoting or unindenting.
        self.assertEqual(shown, plan.expected_confirmation)
        self.assertEqual(shown, shown.strip())
        plan.validate_confirmation(shown)

    def test_the_create_confirmation_string_is_frozen_byte_for_byte(self):
        """Issue #42 changed UPDATE only. CREATE is already live-validated.

        This freezes the whole rendered CREATE string, not just its shape, so
        any future edit to the prefix, clause order, counts, Token-fingerprint
        rendering or the confirmation binding shows up here immediately.
        """
        plan = self.plan()
        self.assertEqual(
            plan.expected_confirmation,
            "CONFIRM BATCH INTERPRETATION CREATE: cdbef87c197476cf ITEMS: 2 "
            "TOKEN-FP: 632caaac01f6049e PRICING-TERMS-CHECKED: YES "
            "EXACTLY-ONE-POST-PER-ITEM-NO-RETRY-IMMEDIATE-READBACK",
        )
        self.assertEqual(len(plan.expected_confirmation), 170)
        self.assertEqual(plan.binding_digest, "cdbef87c197476cf")
        # The displayed CREATE block is also unchanged: five lines plus the
        # trailing blank, with the confirmation on its own undecorated line.
        lines = importer.confirmation_lines(plan)
        self.assertEqual(lines, [
            "CREATE CONFIRMATION — 2 items, one POST each, no retry",
            f"batch digest {plan.digest}",
            f"MANUAL GATE: {importer.PRICING_TERMS_GATE}",
            "Copy the next line exactly into the hidden prompt:",
            plan.expected_confirmation,
            "",
        ])

    def test_the_confirmation_binds_every_field_that_could_change_the_outcome(self):
        plan = self.plan()
        baseline = plan.expected_confirmation
        variants = (
            ("spelling", {"spelling": "different"}),
            ("interpretation", {"interpretation": TEXT_A + "。"}),
            ("vocabulary_id", {"vocabulary_id": VOC_C}),
        )
        for name, changes in variants:
            with self.subTest(field=name):
                mutated = self.plan(**{f"first_{key}": value for key, value in changes.items()})
                self.assertNotEqual(baseline, mutated.expected_confirmation)
        other_label = harness._validate_account_label_shape("issue32-secondary-test-two")
        self.assertNotEqual(
            baseline,
            importer.BatchPlan(
                account_label=other_label,
                credential_fingerprint=plan.credential_fingerprint,
                items=plan.items,
                digest=plan.digest,
            ).expected_confirmation,
        )

    def plan(self, *, first_spelling=None, first_interpretation=None,
             first_vocabulary_id=None):
        entries = self.entries()
        first = importer.PlannedItem(
            ordinal=1,
            spelling=first_spelling or SPELLING_A,
            returned_spelling=first_spelling or SPELLING_A,
            vocabulary_id=first_vocabulary_id or VOC_A,
            interpretation=first_interpretation or TEXT_A,
            request_body=importer.create_body(
                first_vocabulary_id or VOC_A, first_interpretation or TEXT_A
            ),
        )
        second = importer.PlannedItem(
            ordinal=2, spelling=SPELLING_B, returned_spelling=SPELLING_B,
            vocabulary_id=VOC_B, interpretation=TEXT_B,
            request_body=importer.create_body(VOC_B, TEXT_B),
        )
        return importer.BatchPlan(
            account_label=ACCOUNT_LABEL,
            credential_fingerprint=self.credential.fingerprint,
            items=(first, second),
            digest=importer.batch_digest(entries),
        )

    def test_mutating_an_item_after_the_preview_invalidates_the_confirmation(self):
        plan = self.plan()
        accepted = plan.expected_confirmation
        plan.validate_confirmation(accepted)
        object.__setattr__(plan.items[0], "interpretation", TEXT_A + "（改动）")
        with self.assertRaises(harness.SafetyError):
            plan.revalidate()
        with self.assertRaises(harness.SafetyError):
            plan.expected_confirmation
        guard = importer.BatchWriteGuard(
            FakeTransport([]), max_gets=6, max_posts=2, sleep=self.slept.append
        )
        outcome = importer.write_item(guard, plan.items[0], self.credential, accepted, plan)
        self.assertEqual(outcome.outcome, importer.NOT_ATTEMPTED)
        self.assertEqual(outcome.failure_class, "safety")
        self.assertEqual(guard.post_count, 0)

    def test_a_stale_or_wrong_confirmation_aborts_with_zero_posts(self):
        for provided in ("", "CONFIRM BATCH INTERPRETATION CREATE: wrong",
                         harness.WRITE_CONFIRMATION_PREFIX):
            with self.subTest(provided=provided[:24]):
                result, transport, output = self.drive(
                    self.created(), mode=importer.MODE_CREATE,
                    confirm=lambda _plan, value=provided: value,
                )
                self.assertEqual(result.status, "blocked")
                self.assertEqual(result.post_count, 0)
                self.assertNotIn("POST", transport.methods())
                self.assertIn("ABORTED BEFORE THE FIRST POST", output)

    def test_each_item_has_a_structural_maximum_of_one_post(self):
        guard = importer.BatchWriteGuard(
            FakeTransport([harness.HttpResponse(201, {})] * 3),
            max_gets=6, max_posts=2, sleep=self.slept.append,
        )
        request = harness.HttpRequest(
            "POST", importer.CREATE_PATH, importer.create_body(VOC_A, TEXT_A)
        )
        guard.arm(1)
        guard.send(request, self.credential)
        with self.assertRaises(harness.SafetyError):
            guard.send(request, self.credential)
        with self.assertRaises(harness.SafetyError):
            guard.arm(1)
        guard.arm(2)
        guard.send(request, self.credential)
        self.assertEqual(guard.post_count, 2)
        self.assertEqual(guard.posted_ordinals, {1, 2})
        with self.assertRaises(harness.SafetyError):
            guard.arm(3)

    def test_a_verified_item_requires_an_exact_readback_record(self):
        cases = (
            ("wrong text", [record(RECORD_A, "n. 不一样")], importer.NOT_VERIFIED, "mismatch"),
            ("missing tag", [record(RECORD_A, TEXT_A, tags=["MBA", "BEC"])],
             importer.NOT_VERIFIED, "mismatch"),
            ("extra tag", [record(RECORD_A, TEXT_A, tags=["MBA", "BEC", "GMAT", "IELTS"])],
             importer.NOT_VERIFIED, "mismatch"),
            ("duplicate tag", [record(RECORD_A, TEXT_A, tags=["MBA", "MBA", "BEC"])],
             importer.NOT_VERIFIED, "mismatch"),
            ("unpublished", [record(RECORD_A, TEXT_A, status="UNPUBLISHED")],
             importer.NOT_VERIFIED, "mismatch"),
            ("no record", [], importer.NOT_VERIFIED, "unknown-write-outcome"),
            ("two records", [record(RECORD_A, TEXT_A), record(OTHER_RECORD, TEXT_A)],
             importer.AMBIGUOUS, "ambiguous"),
        )
        for name, records, outcome, failure in cases:
            with self.subTest(case=name):
                result, transport, output = self.drive(
                    self.created(records=records), mode=importer.MODE_CREATE
                )
                self.assertEqual(result.status, "stopped")
                self.assertEqual(result.verified_count, 0)
                self.assertEqual(result.outcomes[0].outcome, outcome)
                self.assertEqual(result.outcomes[0].failure_class, failure)
                # Exactly one POST happened and the batch stopped immediately.
                self.assertEqual(result.post_count, 1)
                self.assertEqual(transport.methods().count("POST"), 1)
                self.assertEqual(result.outcomes[1].outcome, importer.NOT_ATTEMPTED)
                self.assertIn(f"STOPPED ON 1: {SPELLING_A}", output)
                self.assertIn("REMAINING NOT ATTEMPTED 1", output)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, output)

    def test_an_uncertain_post_is_resolved_by_one_get_only_recovery(self):
        for name, failure in (
            ("transport", harness.TransportError(TRANSPORT_SENTINEL)),
            ("response", harness.TransportResponseError(502)),
            ("non-2xx", harness.HttpResponse(500, {SERVER_KEY: SERVER_VALUE})),
        ):
            with self.subTest(case=name):
                responses = self.preflight_pair() + [
                    failure, collection([record(RECORD_A, TEXT_A)]),
                    harness.HttpResponse(201, {}), collection([record(RECORD_B, TEXT_B)]),
                ]
                result, transport, output = self.drive(responses, mode=importer.MODE_CREATE)
                self.assertEqual(result.status, "verified")
                self.assertEqual(result.outcomes[0].outcome, importer.RECOVERED)
                self.assertEqual(result.outcomes[1].outcome, importer.CONFIRMED)
                self.assertEqual(transport.methods().count("POST"), 2)
                self.assertIn("VERIFIED 2/2", output)

    def test_an_uncertain_post_without_an_exact_record_fails_closed_and_stops(self):
        cases = (
            ("zero", [], importer.NOT_VERIFIED, "unknown-write-outcome"),
            ("mismatch", [record(RECORD_A, "n. 不一样")], importer.NOT_VERIFIED, "mismatch"),
            ("multiple", [record(RECORD_A, TEXT_A), record(OTHER_RECORD, TEXT_A)],
             importer.AMBIGUOUS, "ambiguous"),
        )
        for name, records, outcome, failure in cases:
            with self.subTest(case=name):
                responses = self.preflight_pair() + [
                    harness.TransportError(TRANSPORT_SENTINEL), collection(records),
                ]
                result, transport, _output = self.drive(responses, mode=importer.MODE_CREATE)
                self.assertEqual(result.status, "stopped")
                self.assertEqual(result.outcomes[0].outcome, outcome)
                self.assertEqual(result.outcomes[0].failure_class, failure)
                self.assertEqual(transport.methods().count("POST"), 1)
                self.assertEqual(transport.methods().count("GET"), 5)

    def test_an_unreadable_readback_never_becomes_a_second_post(self):
        for name, response, failure in (
            ("transport", harness.TransportError(TRANSPORT_SENTINEL), "transport"),
            ("http", harness.HttpResponse(503, {SERVER_KEY: SERVER_VALUE}), "http-status"),
            ("schema", harness.HttpResponse(200, {SERVER_KEY: SERVER_VALUE}), "schema"),
        ):
            with self.subTest(case=name):
                responses = self.preflight_pair() + [
                    harness.HttpResponse(201, {}), response
                ]
                result, transport, _output = self.drive(responses, mode=importer.MODE_CREATE)
                self.assertEqual(result.outcomes[0].outcome, importer.NOT_VERIFIED)
                self.assertEqual(result.outcomes[0].failure_class, failure)
                self.assertEqual(transport.methods().count("POST"), 1)
                self.assertEqual(result.status, "stopped")

    def test_a_later_runtime_failure_stops_the_batch_and_keeps_earlier_successes(self):
        report = self.private_report()
        responses = self.preflight_pair() + [
            harness.HttpResponse(201, {}), collection([record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(201, {}), collection([record(RECORD_B, "n. 不一样")]),
        ]
        result, transport, output = self.drive(
            responses, mode=importer.MODE_CREATE, report=report
        )
        self.assertEqual(result.status, "stopped")
        self.assertEqual(result.verified_count, 1)
        self.assertEqual(result.outcomes[0].outcome, importer.CONFIRMED)
        self.assertEqual(result.outcomes[1].outcome, importer.NOT_VERIFIED)
        self.assertEqual(transport.methods().count("POST"), 2)
        self.assertIn("VERIFIED 1/2", output)
        self.assertIn(f"STOPPED ON 2: {SPELLING_B}", output)
        self.assertIn("REMAINING NOT ATTEMPTED 0", output)
        self.assertIn("Nothing was rolled back or deleted", output)
        document = json.loads(result.report_path.read_text(encoding="utf-8"))
        self.assertEqual(document["stopped_on_ordinal"], 2)
        self.assertEqual(document["verified_count"], 1)
        self.assertEqual([item["outcome"] for item in document["items"]],
                         [importer.CONFIRMED, importer.NOT_VERIFIED])

    def test_a_three_item_batch_never_attempts_items_after_the_stopping_point(self):
        responses = [
            voc_response(VOC_A, SPELLING_A), collection([]),
            voc_response(VOC_B, SPELLING_B), collection([]),
            voc_response(VOC_C, SPELLING_C), collection([]),
            harness.HttpResponse(201, {}), collection([record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(201, {}), collection([]),
        ]
        result, transport, output = self.drive(
            responses, mode=importer.MODE_CREATE, document=THREE_ENTRY_DOCUMENT
        )
        self.assertEqual(result.status, "stopped")
        self.assertEqual(result.verified_count, 1)
        self.assertEqual([item.outcome for item in result.outcomes],
                         [importer.CONFIRMED, importer.NOT_VERIFIED,
                          importer.NOT_ATTEMPTED])
        self.assertEqual(transport.methods().count("POST"), 2)
        self.assertFalse(result.outcomes[2].post_attempted)
        self.assertFalse(result.outcomes[2].readback_attempted)
        self.assertIn("STOPPED ON 2", output)
        self.assertIn("REMAINING NOT ATTEMPTED 1", output)

    def test_a_rerun_of_an_already_created_batch_blocks_during_preflight(self):
        result, transport, output = self.drive(
            [voc_response(VOC_A, SPELLING_A), collection([record(RECORD_A, TEXT_A)]),
             voc_response(VOC_B, SPELLING_B), collection([record(RECORD_B, TEXT_B)])],
            mode=importer.MODE_CREATE,
        )
        self.assertEqual(result.status, "blocked")
        self.assertEqual(result.post_count, 0)
        self.assertEqual([item.state for item in result.preflight],
                         [importer.BLOCK_EXISTING, importer.BLOCK_EXISTING])
        self.assertEqual(transport.methods(), ["GET"] * 4)
        self.assertIn("BLOCKED 2", output)

    def test_conservative_pacing_is_injectable_and_never_gates_correctness(self):
        result, transport, _output = self.drive(self.created(), mode=importer.MODE_CREATE)
        self.assertEqual(result.status, "verified")
        # One pause between consecutive production requests, never before the first.
        self.assertEqual(len(self.slept), len(transport.calls()) - 1)
        self.assertEqual(set(self.slept), {importer.PACING_SECONDS})

    def test_the_production_pacing_floor_stays_conservative(self):
        # A 15-item CREATE batch sends up to 60 requests; the fixed pause must
        # keep it inside the published 10-second and 60-second request windows
        # without depending on how slow the network happens to be.
        self.assertGreaterEqual(importer.PACING_SECONDS, 1.6)

    def test_the_plan_rejects_anything_that_is_not_a_fully_ready_batch(self):
        entries = self.entries()
        blocked = (
            importer.PreflightItem(
                ordinal=1, spelling=SPELLING_A, interpretation=TEXT_A,
                state=importer.BLOCK_EXISTING, existing_count=1, vocabulary_id=VOC_A,
                returned_spelling=SPELLING_A,
            ),
            importer.PreflightItem(
                ordinal=2, spelling=SPELLING_B, interpretation=TEXT_B,
                state=importer.READY_CREATE, existing_count=0, vocabulary_id=VOC_B,
                returned_spelling=SPELLING_B,
            ),
        )
        with self.assertRaises(harness.SafetyError):
            importer.build_plan(
                account_label=ACCOUNT_LABEL,
                credential_fingerprint=self.credential.fingerprint,
                entries=entries, preflight=blocked,
            )

    def test_the_create_body_validator_rejects_caller_supplied_tags_or_status(self):
        for body in (
            {"interpretation": {"voc_id": VOC_A, "interpretation": TEXT_A,
                                "tags": ["MBA"], "status": "PUBLISHED"}},
            {"interpretation": {"voc_id": VOC_A, "interpretation": TEXT_A,
                                "tags": ["MBA", "BEC", "GMAT"], "status": "UNPUBLISHED"}},
            {"interpretation": {"voc_id": VOC_A, "interpretation": TEXT_A,
                                "tags": ["MBA", "BEC", "GMAT"], "status": "PUBLISHED",
                                "origin": "自编"}},
            {"interpretation": {"voc_id": VOC_B, "interpretation": TEXT_A,
                                "tags": ["MBA", "BEC", "GMAT"], "status": "PUBLISHED"}},
            {"phrase": {"voc_id": VOC_A, "phrase": "x", "interpretation": TEXT_A,
                        "tags": ["MBA", "BEC", "GMAT"], "origin": "自编"}},
        ):
            with self.subTest(body=sorted(body)[0]):
                with self.assertRaises(harness.SafetyError):
                    importer.validate_create_body(body, VOC_A, TEXT_A)
        importer.validate_create_body(importer.create_body(VOC_A, TEXT_A), VOC_A, TEXT_A)


# --------------------------------------------------------------------------- #
# Update
# --------------------------------------------------------------------------- #


class UpdateTests(ImporterFixtures, unittest.TestCase):
    """Issue #39: replace exactly one existing authenticated-user record."""

    def existing(self, record_id, text, *, tags=None, status="PUBLISHED"):
        return record(record_id, text, tags=tags or OLD_TAGS, status=status)

    def update_pair(self, first=None, second=None):
        """Preflight responses where both items already have one stale record."""
        return [
            voc_response(VOC_A, SPELLING_A),
            collection(first if first is not None else [self.existing(RECORD_A, OLD_A)]),
            voc_response(VOC_B, SPELLING_B),
            collection(second if second is not None else [self.existing(RECORD_B, OLD_B)]),
        ]

    def updated(self, *, post_status=200, first=None, second=None):
        """A clean two-item update batch: both items change and both verify."""
        return self.update_pair() + [
            harness.HttpResponse(post_status, {}),
            collection(first if first is not None else [record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(post_status, {}),
            collection(second if second is not None else [record(RECORD_B, TEXT_B)]),
        ]

    def run_update(self, responses, **kwargs):
        return self.drive(responses, mode=importer.MODE_UPDATE, **kwargs)

    # ----------------------------------------------------------------- preflight

    def test_update_preflight_classifies_zero_one_matching_one_differing_and_many(self):
        cases = (
            ([], importer.BLOCK_MISSING, 0, "blocked"),
            ([self.existing(RECORD_B, OLD_B)], importer.READY_UPDATE, 1, "blocked"),
            ([record(RECORD_B, TEXT_B)], importer.ALREADY_MATCHING, 1, "satisfied"),
            ([self.existing(RECORD_B, OLD_B), self.existing(OTHER_RECORD, "n. 另一条")],
             importer.BLOCK_AMBIGUOUS, 2, "blocked"),
        )
        for records, state, count, status in cases:
            with self.subTest(state=state):
                # A wrong confirmation keeps every case at preflight, so the
                # classification is observed before any write can exist.
                result, transport, output = self.run_update(
                    self.update_pair(first=[record(RECORD_A, TEXT_A)], second=records),
                    confirm=lambda _plan: "",
                )
                verdict = result.preflight[1]
                self.assertEqual(verdict.state, state)
                self.assertEqual(verdict.existing_count, count)
                self.assertEqual(transport.methods(), ["GET"] * 4)
                self.assertEqual(result.post_count, 0)
                self.assertEqual(result.status, status)
                self.assertIn(importer._STATE_LABELS[state], output)

    def test_only_the_exactly_one_shape_ever_carries_an_update_baseline(self):
        result, _transport, _output = self.run_update(
            self.update_pair(first=[], second=None)
        )
        self.assertIsNone(result.preflight[0].baseline)
        self.assertIsNone(result.preflight[0].record_fingerprint)
        self.assertEqual(result.preflight[1].baseline.interpretation, OLD_B)
        self.assertEqual(list(result.preflight[1].baseline.tags), OLD_TAGS)
        self.assertEqual(result.preflight[1].baseline.status, "PUBLISHED")
        self.assertEqual(result.preflight[1].record_fingerprint,
                         importer._short_fingerprint(RECORD_B))

    def test_an_unreadable_existing_record_blocks_instead_of_being_guessed(self):
        for name, existing in (
            ("unsafe id", [record(UNSAFE_ID, OLD_B)]),
            ("undocumented tag", [record(RECORD_B, OLD_B, tags=[SERVER_VALUE])]),
            ("control character", [record(RECORD_B, "n. 旧\x07", tags=OLD_TAGS)]),
        ):
            with self.subTest(case=name):
                result, _transport, output = self.run_update(
                    self.update_pair(first=[record(RECORD_A, TEXT_A)], second=existing)
                )
                self.assertEqual(result.preflight[1].state, importer.BLOCK_ERROR)
                self.assertEqual(result.preflight[1].error_class, "schema")
                self.assertEqual(result.post_count, 0)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, output)

    def test_any_blocked_item_aborts_the_whole_update_batch_before_the_first_post(self):
        cases = (
            ("missing", self.update_pair(second=[])),
            ("ambiguous", self.update_pair(
                second=[self.existing(RECORD_B, OLD_B),
                        self.existing(OTHER_RECORD, "n. 另一条")])),
            ("error", [voc_response(VOC_A, SPELLING_A),
                       collection([self.existing(RECORD_A, OLD_A)]),
                       harness.TransportError(TRANSPORT_SENTINEL),
                       voc_response(VOC_B, SPELLING_B)]),
        )
        for name, responses in cases:
            with self.subTest(case=name):
                self.confirmations = []
                result, transport, output = self.run_update(responses)
                self.assertEqual(result.status, "blocked")
                self.assertEqual(result.post_count, 0)
                self.assertEqual(result.outcomes, ())
                self.assertNotIn("POST", transport.methods())
                self.assertEqual(self.confirmations, [])
                self.assertIn("ABORTED BEFORE THE FIRST POST", output)
                self.assertIn("not ready to update", output)

    def test_an_all_matching_batch_completes_with_zero_writes_and_no_confirmation(self):
        report = self.private_report()
        result, transport, output = self.run_update(
            self.update_pair(first=[record(RECORD_A, TEXT_A)],
                             second=[record(RECORD_B, TEXT_B)]),
            report=report,
        )
        self.assertEqual(result.status, "satisfied")
        self.assertEqual((result.post_count, result.no_op_count), (0, 2))
        self.assertEqual(result.update_count, 0)
        self.assertEqual(transport.methods(), ["GET"] * 4)
        self.assertEqual(self.confirmations, [])
        self.assertNotIn(importer.UPDATE_CONFIRMATION_PREFIX, output)
        self.assertIn("NOTHING TO UPDATE", output)
        self.assertIn("ALREADY MATCHING 2/2", output)
        self.assertIn("WRITES 0", output)
        document = json.loads(result.report_path.read_text(encoding="utf-8"))
        self.assertEqual(document["post_count"], 0)
        self.assertEqual([item["preflight"] for item in document["items"]],
                         [importer.ALREADY_MATCHING] * 2)

    def test_tag_order_and_status_are_compared_as_the_documented_final_state(self):
        cases = (
            ("reordered tags", ["GMAT", "MBA", "BEC"], "PUBLISHED",
             importer.ALREADY_MATCHING),
            ("missing tag", ["MBA", "BEC"], "PUBLISHED", importer.READY_UPDATE),
            ("extra tag", ["MBA", "BEC", "GMAT", "考研"], "PUBLISHED",
             importer.READY_UPDATE),
            ("unpublished", ["MBA", "BEC", "GMAT"], "UNPUBLISHED",
             importer.READY_UPDATE),
        )
        for name, tags, status, state in cases:
            with self.subTest(case=name):
                result, _transport, _output = self.run_update(
                    self.update_pair(
                        first=[record(RECORD_A, TEXT_A)],
                        second=[record(RECORD_B, TEXT_B, tags=tags, status=status)],
                    )
                )
                self.assertEqual(result.preflight[1].state, state)

    # ------------------------------------------------------------------- preview

    def test_the_update_preview_shows_the_old_and_new_values_without_raw_ids(self):
        _result, _transport, output = self.run_update(
            self.update_pair(first=[record(RECORD_A, TEXT_A)])
        )
        self.assertIn("READY_UPDATE", output)
        self.assertIn("ALREADY_MATCHING", output)
        self.assertIn("CURRENT (this exact text will be replaced):", output)
        self.assertIn(OLD_B, output)
        self.assertIn("current tags 考研   current status PUBLISHED", output)
        self.assertIn("PROPOSED:", output)
        for line in TEXT_B.split("\n"):
            self.assertIn(line, output)
        self.assertIn("proposed tags MBA BEC GMAT   proposed status PUBLISHED", output)
        self.assertIn("CURRENT = PROPOSED (no change, no request will be sent):", output)
        self.assertIn(f"path {importer.UPDATE_PATH_TEMPLATE}", output)
        self.assertIn(importer._short_fingerprint(VOC_B), output)
        self.assertIn(importer._short_fingerprint(RECORD_B), output)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, output)

    # --------------------------------------------------------------------- write

    def test_a_clean_update_posts_the_documented_body_to_the_selected_record(self):
        result, transport, output = self.run_update(self.updated())
        self.assertEqual(result.status, "verified")
        self.assertEqual(result.verified_count, 2)
        self.assertIn("UPDATED 2/2", output)
        self.assertEqual(transport.calls(), [
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_A}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
            ("POST", f"{INTERPRETATIONS_PATH}/{RECORD_A}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("POST", f"{INTERPRETATIONS_PATH}/{RECORD_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
        ])
        posts = [payload for payload in transport.payloads if payload is not None]
        self.assertEqual(posts[0], {"interpretation": {
            "interpretation": TEXT_A,
            "tags": ["MBA", "BEC", "GMAT"],
            "status": "PUBLISHED",
        }})
        self.assertEqual(posts[1]["interpretation"]["interpretation"], TEXT_B)
        for payload in posts:
            entity = payload["interpretation"]
            self.assertEqual(set(entity), set(importer.UPDATE_BODY_FIELDS))
            self.assertNotIn("voc_id", entity)
            self.assertNotIn("id", entity)
            self.assertNotIn("voc_id", payload)

    def test_a_mixed_batch_updates_only_the_changed_item(self):
        responses = self.update_pair(first=[record(RECORD_A, TEXT_A)]) + [
            harness.HttpResponse(200, {}), collection([record(RECORD_B, TEXT_B)]),
        ]
        result, transport, output = self.run_update(responses)
        self.assertEqual(result.status, "verified")
        self.assertEqual((result.update_count, result.no_op_count), (1, 1))
        self.assertEqual(result.post_count, 1)
        self.assertEqual(transport.calls()[4:], [
            ("POST", f"{INTERPRETATIONS_PATH}/{RECORD_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
        ])
        # The plan skipped the already-matching first item entirely.
        self.assertEqual([outcome.ordinal for outcome in result.outcomes], [2])
        self.assertIn("UPDATED 1/1", output)
        self.assertIn("ALREADY MATCHING 1 (no request sent)", output)

    def test_the_guard_pins_each_post_to_one_ordinal_and_one_exact_record_path(self):
        guard = importer.BatchWriteGuard(
            FakeTransport([harness.HttpResponse(200, {})] * 3),
            max_gets=6, max_posts=2, sleep=self.slept.append,
        )
        request = harness.HttpRequest(
            "POST", f"{INTERPRETATIONS_PATH}/{RECORD_A}", importer.update_body(TEXT_A)
        )
        other = harness.HttpRequest(
            "POST", f"{INTERPRETATIONS_PATH}/{OTHER_RECORD}", importer.update_body(TEXT_A)
        )
        create = harness.HttpRequest(
            "POST", importer.CREATE_PATH, importer.create_body(VOC_A, TEXT_A)
        )
        guard.arm(1, f"{INTERPRETATIONS_PATH}/{RECORD_A}")
        # Neither another record nor the create endpoint may consume this budget.
        for rejected in (other, create):
            with self.assertRaises(harness.SafetyError):
                guard.send(rejected, self.credential)
        guard.send(request, self.credential)
        with self.assertRaises(harness.SafetyError):
            guard.send(request, self.credential)
        with self.assertRaises(harness.SafetyError):
            guard.arm(1, f"{INTERPRETATIONS_PATH}/{RECORD_A}")
        with self.assertRaises(harness.SafetyError):
            guard.arm(2, f"{INTERPRETATIONS_PATH}/{UNSAFE_ID}")
        self.assertEqual((guard.post_count, guard.posted_ordinals), (1, {1}))

    # -------------------------------------------------------------- confirmation

    def update_plan(self, *, record_id=RECORD_A, old_text=OLD_A, old_tags=("考研",),
                    old_status="PUBLISHED", interpretation=None, no_op_count=1):
        baseline = importer.RecordBaseline(
            record_id=record_id, interpretation=old_text,
            tags=tuple(old_tags), status=old_status,
        )
        text = interpretation if interpretation is not None else TEXT_A
        item = importer.PlannedItem(
            ordinal=1, spelling=SPELLING_A, returned_spelling=SPELLING_A,
            vocabulary_id=VOC_A, interpretation=text,
            request_body=importer.update_body(text), baseline=baseline,
        )
        return importer.BatchPlan(
            account_label=ACCOUNT_LABEL,
            credential_fingerprint=self.credential.fingerprint,
            items=(item,),
            digest=importer.batch_digest(self.entries(), mode=importer.MODE_UPDATE),
            mode=importer.MODE_UPDATE,
            no_op_count=no_op_count,
        )

    def test_one_update_confirmation_is_copy_safe_and_distinct_from_create(self):
        plan = self.update_plan()
        lines = importer.confirmation_lines(plan)
        displayed = [line for line in lines
                     if importer.UPDATE_CONFIRMATION_PREFIX in line]
        self.assertEqual(len(displayed), 1)
        shown = displayed[0]
        # Byte-for-byte pasteable: no indentation, no quoting, no trimming.
        self.assertEqual(shown, plan.expected_confirmation)
        self.assertEqual(shown, shown.strip())
        plan.validate_confirmation(shown)
        self.assertNotIn(importer.CONFIRMATION_PREFIX, shown)
        # Issue #42: the pasted token is short; the long human-readable fields
        # stay visible in the surrounding block and remain bound by the digest.
        block = "\n".join(lines)
        self.assertIn("UPDATES: 1   NO-OP: 1   "
                      f"TOKEN-FP: {self.credential.fingerprint}", block)
        self.assertIn(harness.WRITE_PRICING_TERMS_CLAUSE, block)
        self.assertIn(importer.BATCH_ONE_POST_CLAUSE, block)
        self.assertIn(importer.PRICING_TERMS_GATE, block)
        self.assertIn(f"({len(shown)} characters", block)
        for raw in RAW_IDS:
            self.assertNotIn(raw, shown)
            self.assertNotIn(raw, block)

    def test_the_update_confirmation_is_one_short_bound_token(self):
        """Issue #42: `CONFIRM UPDATE <16 lowercase hex>` and nothing else."""
        plan = self.update_plan()
        shown = plan.expected_confirmation
        self.assertRegex(shown, r"^CONFIRM UPDATE [0-9a-f]{16}$")
        self.assertLessEqual(len(shown), importer.MAX_COPIED_CONFIRMATION_CHARS)
        # Short enough that an ordinary terminal cannot wrap it mid-copy, which
        # is the failure #41 hit with the previous 181-character sentence.
        self.assertEqual(len(shown), 31)
        self.assertEqual(shown, shown.strip())
        self.assertNotIn("\n", shown)

    def test_the_short_update_token_carries_the_unchanged_binding_digest(self):
        """The 16 hex chars are still the prefix of the full-binding SHA-256."""
        plan = self.update_plan()
        expected = importer._digest(plan.confirmation_binding())[:16]
        self.assertEqual(plan.binding_digest, expected)
        self.assertEqual(plan.expected_confirmation, f"CONFIRM UPDATE {expected}")
        # The pre-#42 long form was built from this same digest, so an unchanged
        # digest here is what proves `confirmation_binding()` did not move.
        legacy = (
            f"CONFIRM BATCH INTERPRETATION UPDATE: {expected} "
            f"UPDATES: {plan.item_count} NO-OP: {plan.no_op_count} "
            f"TOKEN-FP: {plan.credential_fingerprint} "
            f"{harness.WRITE_PRICING_TERMS_CLAUSE} {importer.BATCH_ONE_POST_CLAUSE}"
        )
        self.assertEqual(len(legacy), 181)
        self.assertIn(plan.binding_digest, legacy)
        # And the binding itself still carries every field it bound before.
        binding = plan.confirmation_binding()
        for key in ("operation", "mode", "host", "path", "tags", "status",
                    "item_count", "no_op_count", "batch_digest",
                    "credential_fingerprint", "items", "account_label",
                    "vocabulary_ids", "request_bodies", "record_ids",
                    "write_paths", "write_policy", "pricing_and_terms_checked"):
            self.assertIn(key, binding)
        self.assertEqual(binding["record_ids"], [RECORD_A])
        self.assertEqual(binding["items"][0]["pre_update"]["interpretation"], OLD_A)

    def test_the_short_update_token_still_demands_strict_exact_equality(self):
        plan = self.update_plan()
        exact = plan.expected_confirmation
        plan.validate_confirmation(exact)
        wrong_digest = f"CONFIRM UPDATE {'0' * 16}"
        self.assertNotEqual(wrong_digest, exact)
        for provided in (
            f" {exact}", f"{exact} ", f"\t{exact}", f"{exact}\n",
            exact.upper(), exact.lower(),
            exact.replace(" ", ""), exact[:-1], exact + "0",
            "CONFIRM UPDATE", wrong_digest, exact.replace("UPDATE", "CREATE"),
            None, 0, ["CONFIRM UPDATE"],
        ):
            with self.subTest(provided=repr(provided)[:28]):
                with self.assertRaises(harness.ConfirmationError):
                    plan.validate_confirmation(provided)

    def test_the_update_confirmation_binds_the_target_and_the_pre_update_snapshot(self):
        baseline = self.update_plan().expected_confirmation
        variants = (
            ("target record", {"record_id": RECORD_C}),
            ("old text", {"old_text": OLD_A + "。"}),
            ("old tags", {"old_tags": ("四级",)}),
            ("old status", {"old_status": "UNPUBLISHED"}),
            ("proposed text", {"interpretation": TEXT_A + "。"}),
            ("no-op count", {"no_op_count": 0}),
        )
        for name, changes in variants:
            with self.subTest(field=name):
                self.assertNotEqual(baseline, self.update_plan(**changes).expected_confirmation)
        # The create confirmation for the same document is a different string.
        self.assertNotEqual(
            importer.batch_digest(self.entries()),
            importer.batch_digest(self.entries(), mode=importer.MODE_UPDATE),
        )

    def test_mutating_the_baseline_or_the_proposal_after_the_preview_blocks_the_post(self):
        for name, mutate in (
            ("target record",
             lambda plan: object.__setattr__(plan.items[0].baseline, "record_id", RECORD_C)),
            ("old text",
             lambda plan: object.__setattr__(
                 plan.items[0].baseline, "interpretation", OLD_A + "（改动）")),
            ("proposed text",
             lambda plan: object.__setattr__(
                 plan.items[0], "interpretation", TEXT_A + "（改动）")),
        ):
            with self.subTest(case=name):
                plan = self.update_plan()
                accepted = plan.expected_confirmation
                plan.validate_confirmation(accepted)
                mutate(plan)
                guard = importer.BatchWriteGuard(
                    FakeTransport([]), max_gets=3, max_posts=1, sleep=self.slept.append
                )
                outcome = importer.write_item(
                    guard, plan.items[0], self.credential, accepted, plan
                )
                self.assertEqual(outcome.outcome, importer.NOT_ATTEMPTED)
                self.assertEqual(outcome.failure_class, "safety")
                self.assertEqual(guard.post_count, 0)

    def test_an_item_that_became_already_matching_can_never_be_a_write_target(self):
        plan = self.update_plan()
        object.__setattr__(plan.items[0].baseline, "interpretation", TEXT_A)
        object.__setattr__(plan.items[0].baseline, "tags", tuple(importer.TAGS))
        with self.assertRaises(harness.SafetyError):
            plan.revalidate()

    def test_a_stale_or_create_shaped_confirmation_aborts_the_update_with_zero_posts(self):
        for provided in ("", importer.CONFIRMATION_PREFIX,
                         "CONFIRM BATCH INTERPRETATION UPDATE: wrong"):
            with self.subTest(provided=provided[:24]):
                result, transport, output = self.run_update(
                    self.updated(), confirm=lambda _plan, value=provided: value
                )
                self.assertEqual(result.status, "blocked")
                self.assertEqual(result.post_count, 0)
                self.assertNotIn("POST", transport.methods())
                self.assertIn("ABORTED BEFORE THE FIRST POST", output)

    # ------------------------------------------------------------------ readback

    def test_a_verified_update_requires_the_same_record_and_the_exact_final_state(self):
        cases = (
            ("wrong text", [record(RECORD_A, "n. 不一样")],
             importer.NOT_VERIFIED, "mismatch"),
            ("missing tag", [record(RECORD_A, TEXT_A, tags=["MBA", "BEC"])],
             importer.NOT_VERIFIED, "mismatch"),
            ("unpublished", [record(RECORD_A, TEXT_A, status="UNPUBLISHED")],
             importer.NOT_VERIFIED, "mismatch"),
            ("different record id", [record(OTHER_RECORD, TEXT_A)],
             importer.NOT_VERIFIED, "mismatch"),
            ("no record", [], importer.NOT_VERIFIED, "unknown-write-outcome"),
            ("two records", [record(RECORD_A, TEXT_A), record(OTHER_RECORD, TEXT_A)],
             importer.AMBIGUOUS, "ambiguous"),
        )
        for name, records, outcome, failure in cases:
            with self.subTest(case=name):
                result, transport, output = self.run_update(self.updated(first=records))
                self.assertEqual(result.status, "stopped")
                self.assertEqual(result.verified_count, 0)
                self.assertEqual(result.outcomes[0].outcome, outcome)
                self.assertEqual(result.outcomes[0].failure_class, failure)
                self.assertEqual(transport.methods().count("POST"), 1)
                self.assertEqual(result.outcomes[1].outcome, importer.NOT_ATTEMPTED)
                self.assertIn(f"STOPPED ON 1: {SPELLING_A}", output)
                self.assertIn("REMAINING NOT ATTEMPTED 1", output)
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, output)

    def test_an_uncertain_update_post_is_resolved_by_one_get_only_recovery(self):
        for name, failure in (
            ("transport", harness.TransportError(TRANSPORT_SENTINEL)),
            ("response", harness.TransportResponseError(502)),
            ("non-2xx", harness.HttpResponse(500, {SERVER_KEY: SERVER_VALUE})),
        ):
            with self.subTest(case=name):
                responses = self.update_pair() + [
                    failure, collection([record(RECORD_A, TEXT_A)]),
                    harness.HttpResponse(200, {}), collection([record(RECORD_B, TEXT_B)]),
                ]
                result, transport, output = self.run_update(responses)
                self.assertEqual(result.status, "verified")
                self.assertEqual(result.outcomes[0].outcome, importer.RECOVERED)
                self.assertEqual(result.outcomes[1].outcome, importer.CONFIRMED)
                # One POST per item and exactly one GET recovery — never a resend.
                self.assertEqual(transport.methods().count("POST"), 2)
                self.assertEqual(transport.methods().count("GET"), 6)
                self.assertIn("UPDATED 2/2", output)

    def test_an_uncertain_update_without_the_same_target_fails_closed(self):
        cases = (
            ("zero", [], importer.NOT_VERIFIED, "unknown-write-outcome"),
            ("different id", [record(OTHER_RECORD, TEXT_A)],
             importer.NOT_VERIFIED, "mismatch"),
            ("multiple", [record(RECORD_A, TEXT_A), record(OTHER_RECORD, TEXT_A)],
             importer.AMBIGUOUS, "ambiguous"),
        )
        for name, records, outcome, failure in cases:
            with self.subTest(case=name):
                responses = self.update_pair() + [
                    harness.TransportError(TRANSPORT_SENTINEL), collection(records),
                ]
                result, transport, _output = self.run_update(responses)
                self.assertEqual(result.status, "stopped")
                self.assertEqual(result.outcomes[0].outcome, outcome)
                self.assertEqual(result.outcomes[0].failure_class, failure)
                self.assertEqual(transport.methods().count("POST"), 1)
                self.assertEqual(transport.methods().count("GET"), 5)

    # --------------------------------------------------- partial failure / rerun

    def test_a_later_update_failure_stops_the_batch_and_keeps_earlier_successes(self):
        report = self.private_report()
        responses = [
            voc_response(VOC_A, SPELLING_A), collection([self.existing(RECORD_A, OLD_A)]),
            voc_response(VOC_B, SPELLING_B), collection([self.existing(RECORD_B, OLD_B)]),
            voc_response(VOC_C, SPELLING_C), collection([self.existing(RECORD_C, "n. 旧")]),
            harness.HttpResponse(200, {}), collection([record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(200, {}), collection([record(RECORD_B, "n. 没有改成")]),
        ]
        result, transport, output = self.run_update(
            responses, document=THREE_ENTRY_DOCUMENT, report=report
        )
        self.assertEqual(result.status, "stopped")
        self.assertEqual(result.verified_count, 1)
        self.assertEqual([item.outcome for item in result.outcomes],
                         [importer.CONFIRMED, importer.NOT_VERIFIED,
                          importer.NOT_ATTEMPTED])
        self.assertEqual(transport.methods().count("POST"), 2)
        self.assertFalse(result.outcomes[2].post_attempted)
        self.assertIn(f"STOPPED ON 2: {SPELLING_B}", output)
        self.assertIn("REMAINING NOT ATTEMPTED 1", output)
        self.assertIn("Nothing was rolled back or deleted", output)
        self.assertIn("ALREADY_MATCHING", output)
        document = json.loads(result.report_path.read_text(encoding="utf-8"))
        self.assertEqual(document["stopped_on_ordinal"], 2)
        self.assertEqual(document["verified_count"], 1)

    def test_a_rerun_after_a_partial_update_is_a_no_op_for_the_finished_items(self):
        # Item 1 was already replaced on the previous run; item 2 still differs.
        result, transport, output = self.run_update(
            self.update_pair(first=[record(RECORD_A, TEXT_A)]) + [
                harness.HttpResponse(200, {}), collection([record(RECORD_B, TEXT_B)]),
            ]
        )
        self.assertEqual([item.state for item in result.preflight],
                         [importer.ALREADY_MATCHING, importer.READY_UPDATE])
        self.assertEqual(result.status, "verified")
        self.assertEqual(result.post_count, 1)
        self.assertIn("ALREADY MATCHING 1 (no request sent)", output)
        # A second rerun of the finished batch now writes nothing at all.
        self.confirmations = []
        again, transport, output = self.run_update(
            self.update_pair(first=[record(RECORD_A, TEXT_A)],
                             second=[record(RECORD_B, TEXT_B)])
        )
        self.assertEqual(again.status, "satisfied")
        self.assertEqual(again.post_count, 0)
        self.assertEqual(self.confirmations, [])
        self.assertEqual(transport.methods(), ["GET"] * 4)

    # -------------------------------------------------------------- private report

    def test_the_private_report_keeps_the_pre_update_snapshot_without_raw_ids(self):
        report = self.private_report()
        result, _transport, output = self.run_update(self.updated(), report=report)
        self.assertEqual(result.status, "verified")
        raw = result.report_path.read_text(encoding="utf-8")
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, raw)
            self.assertNotIn(sentinel, output)
        document = json.loads(raw)
        importer._assert_no_raw_identifiers(document)
        self.assertEqual(document["mode"], importer.MODE_UPDATE)
        self.assertEqual(document["operation"], importer.OPERATION_UPDATE)
        self.assertEqual(document["path"], importer.UPDATE_PATH_TEMPLATE)
        self.assertEqual(document["update_count"], 2)
        self.assertEqual(document["no_op_count"], 0)
        self.assertEqual(document["retries"], 0)
        self.assertIn("manual restoration only", document["rollback"])
        first = document["items"][0]
        # Enough local evidence to restore the replaced interpretation by hand.
        self.assertEqual(first["pre_update_interpretation"], OLD_A)
        self.assertEqual(first["pre_update_tags"], OLD_TAGS)
        self.assertEqual(first["pre_update_status"], "PUBLISHED")
        self.assertEqual(first["interpretation"], TEXT_A)
        self.assertEqual(first["tags"], ["MBA", "BEC", "GMAT"])
        self.assertEqual(first["status"], "PUBLISHED")
        self.assertEqual(first["voc_id_fingerprint"], importer._short_fingerprint(VOC_A))
        self.assertEqual(first["record_fingerprint"], importer._short_fingerprint(RECORD_A))
        self.assertTrue(first["post_attempted"])
        self.assertTrue(first["readback_attempted"])
        self.assertEqual(first["outcome"], importer.CONFIRMED)

    # ---------------------------------------------------------------- boundaries

    def test_update_mode_never_falls_back_to_create(self):
        result, transport, output = self.run_update(self.update_pair(second=[]))
        self.assertEqual(result.preflight[1].state, importer.BLOCK_MISSING)
        self.assertEqual(result.status, "blocked")
        self.assertNotIn(("POST", INTERPRETATIONS_PATH), transport.calls())
        self.assertEqual(result.post_count, 0)
        self.assertIn("no custom interpretation to replace", output)
        # And a create batch still refuses the one-existing-record shape rather
        # than quietly turning itself into an update.
        created, _transport, _output = self.drive(
            self.update_pair(), mode=importer.MODE_CREATE
        )
        self.assertEqual([item.state for item in created.preflight],
                         [importer.BLOCK_EXISTING, importer.BLOCK_EXISTING])
        self.assertEqual(created.post_count, 0)

    def test_the_update_body_validator_rejects_a_voc_id_or_a_create_shaped_payload(self):
        path = f"{INTERPRETATIONS_PATH}/{RECORD_A}"
        for body in (
            {"interpretation": {"voc_id": VOC_A, "interpretation": TEXT_A,
                                "tags": ["MBA", "BEC", "GMAT"], "status": "PUBLISHED"}},
            {"interpretation": {"id": RECORD_A, "interpretation": TEXT_A,
                                "tags": ["MBA", "BEC", "GMAT"], "status": "PUBLISHED"}},
            {"interpretation": {"interpretation": TEXT_A, "tags": ["MBA"],
                                "status": "PUBLISHED"}},
            {"interpretation": {"interpretation": TEXT_A,
                                "tags": ["MBA", "BEC", "GMAT"], "status": "UNPUBLISHED"}},
            {"interpretation": {"interpretation": TEXT_A,
                                "tags": ["MBA", "BEC", "GMAT"], "status": "PUBLISHED",
                                "origin": "自编"}},
        ):
            with self.subTest(body=sorted(body["interpretation"])[0]):
                with self.assertRaises(harness.SafetyError):
                    importer.validate_update_body(body, path, TEXT_A)
        # The intended body only validates against its own record path and text.
        importer.validate_update_body(importer.update_body(TEXT_A), path, TEXT_A)
        for bad_path in (importer.CREATE_PATH, f"{INTERPRETATIONS_PATH}/{UNSAFE_ID}"):
            with self.subTest(path=bad_path[-12:]):
                with self.assertRaises(harness.SafetyError):
                    importer.validate_update_body(
                        importer.update_body(TEXT_A), bad_path, TEXT_A
                    )
        with self.assertRaises(harness.SafetyError):
            importer.validate_update_body(importer.update_body(TEXT_A), path, TEXT_B)

    def test_the_update_target_path_is_rebuilt_from_the_project_prefix(self):
        self.assertEqual(importer.update_path(RECORD_A),
                         f"{INTERPRETATIONS_PATH}/{RECORD_A}")
        for unsafe in (UNSAFE_ID, "../vocabulary", "", None, 7, f"{RECORD_A}?x=1"):
            with self.subTest(value=str(unsafe)[:16]):
                with self.assertRaises(harness.SafetyError):
                    importer.update_path(unsafe)

    def test_the_fixed_update_contract_fails_closed_when_it_drifts(self):
        for name, value in (
            ("UPDATE_PATH_TEMPLATE", "/open/api/v1/interpretations"),
            ("UPDATE_BODY_FIELDS", ("voc_id", "interpretation", "tags", "status")),
            ("UPDATE_CONFIRMATION_PREFIX", importer.CONFIRMATION_PREFIX),
            ("MODES", (importer.MODE_DRY_RUN, importer.MODE_CREATE)),
        ):
            with self.subTest(name=name):
                with mock.patch.object(importer, name, value):
                    with self.assertRaises(harness.SafetyError):
                        importer.validate_contract()
        importer.validate_contract()


# --------------------------------------------------------------------------- #
# Security and containment
# --------------------------------------------------------------------------- #


class SecurityTests(ImporterFixtures, unittest.TestCase):
    def test_main_and_production_account_labels_are_rejected(self):
        for label in ("main", "primary account", "owner", "production", "prod-test",
                      "主账号", "主账号测试", "生产测试", "unlabelled"):
            with self.subTest(label=label):
                with self.assertRaises(harness.SafetyError):
                    harness._validate_account_label_shape(label)
                stream = io.StringIO()
                with mock.patch("sys.stdout", stream):
                    code = importer.main(
                        ["--mode", importer.MODE_DRY_RUN, "--input", str(self.batch_file()),
                         "--account-label", label, "--allow-network"],
                        token_prompt=lambda _message: FAKE_TOKEN,
                        transport_factory=lambda: FakeTransport([]),
                        stdin_isatty=lambda: True,
                        report_factory=self.private_report,
                    )
                self.assertEqual(code, 3)
                self.assertIn("BLOCKED", stream.getvalue())

    def batch_file(self, document=TWO_ENTRY_DOCUMENT):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "batch.md"
        path.write_text(document, encoding="utf-8")
        return path

    def test_the_cli_never_accepts_a_token_and_never_echoes_argv(self):
        stream = io.StringIO()
        rejected = (
            ["--input", "batch.md", "--account-label", ACCOUNT_LABEL, "--token", FAKE_TOKEN],
            ["--input", "batch.md", "--account-label", ACCOUNT_LABEL, "--tags", "MBA"],
            ["--input", "batch.md", "--account-label", ACCOUNT_LABEL, "--status", "PUBLISHED"],
            # There is no delete/replace mode, and --record-id does not exist:
            # the update target is never nameable from the command line.
            ["--mode", "delete", "--input", "batch.md", "--account-label", ACCOUNT_LABEL],
            ["--mode", "update", "--input", "batch.md", "--account-label", ACCOUNT_LABEL,
             "--record-id", RECORD_A],
            ["--mode", "dry-run", "--account-label", ACCOUNT_LABEL],
            ["--input", "batch.md"],
            [],
        )
        for argv in rejected:
            with self.subTest(argv=argv[:2]):
                with mock.patch("sys.stderr", stream):
                    with self.assertRaises(SystemExit) as context:
                        importer.parse_args(list(argv))
                self.assertEqual(context.exception.code, 2)
        printed = stream.getvalue()
        self.assertNotIn(FAKE_TOKEN, printed)
        self.assertIn("never accepts a Token on the command line", printed)

    def test_the_token_never_reaches_output_a_repr_or_a_traceback(self):
        report = self.private_report()
        transport = FakeTransport(self.preflight_pair())
        lines = []
        result = importer.run_batch(
            mode=importer.MODE_DRY_RUN, entries=self.entries(), transport=transport,
            credential=self.credential, account_label=ACCOUNT_LABEL,
            emit=lines.append, sleep=self.slept.append, report=report,
        )
        rendered = "\n".join(lines) + repr(result) + str(result)
        rendered += repr(self.credential) + str(self.credential)
        rendered += "".join(repr(item) for item in result.preflight)
        rendered += result.report_path.read_text(encoding="utf-8")
        self.assertNotIn(FAKE_TOKEN, rendered)
        for raw in RAW_IDS:
            self.assertNotIn(raw, rendered)

    def test_no_raw_vocabulary_or_record_id_reaches_output_or_the_report(self):
        report = self.private_report()
        result, _transport, output = self.drive(
            self.created_pair(), mode=importer.MODE_CREATE, report=report
        )
        self.assertEqual(result.status, "verified")
        document = result.report_path.read_text(encoding="utf-8")
        for raw in RAW_IDS:
            self.assertNotIn(raw, output)
            self.assertNotIn(raw, document)
        parsed = json.loads(document)
        self.assertEqual(parsed["items"][0]["voc_id_fingerprint"],
                         importer._short_fingerprint(VOC_A))
        self.assertEqual(parsed["items"][0]["record_fingerprint"],
                         importer._short_fingerprint(RECORD_A))
        importer._assert_no_raw_identifiers(parsed)

    def created_pair(self):
        return self.preflight_pair() + [
            harness.HttpResponse(201, {}), collection([record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(201, {}), collection([record(RECORD_B, TEXT_B)]),
        ]

    def test_the_report_refuses_credential_material_and_raw_identifier_fields(self):
        report = self.private_report()
        for document in (
            {"mode": importer.MODE_DRY_RUN, "created_at": "2026-08-08T00:00:00Z",
             "batch_digest": "0" * 64, "authorization": "Bearer x"},
            {"mode": importer.MODE_DRY_RUN, "created_at": "2026-08-08T00:00:00Z",
             "batch_digest": "0" * 64, "items": [{"voc_id": VOC_A}]},
            {"mode": importer.MODE_DRY_RUN, "created_at": "2026-08-08T00:00:00Z",
             "batch_digest": "0" * 64, "items": [{"record_fingerprint": RECORD_A}]},
            {"mode": "delete", "created_at": "2026-08-08T00:00:00Z",
             "batch_digest": "0" * 64},
            {"mode": importer.MODE_UPDATE, "created_at": "2026-08-08T00:00:00Z",
             "batch_digest": "0" * 64,
             "items": [{"record_id": RECORD_A}]},
        ):
            with self.subTest(document=sorted(document)[0]):
                with self.assertRaises(harness.SafetyError):
                    report.write(document)
        self.assertEqual(list(report.root.glob("*.json")) if report.root.exists() else [], [])

    def test_the_report_stays_private_and_below_artifacts_private(self):
        report = self.private_report()
        result, _transport, _output = self.drive(self.preflight_pair(), report=report)
        path = result.report_path
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertTrue(path.name.startswith(importer.REPORT_PREFIX))
        with self.assertRaises(harness.SafetyError):
            importer.BatchRunReport(Path(tempfile.gettempdir()) / "issue32-elsewhere")

    def test_the_report_name_carries_the_mode_timestamp_and_digest(self):
        report = self.private_report()
        stamped = mock.Mock(return_value=__import__("datetime").datetime(
            2026, 8, 8, 12, 34, 56, tzinfo=__import__("datetime").timezone.utc))
        result, _transport, _output = self.drive(
            self.preflight_pair(), report=report, now=stamped
        )
        digest = importer.batch_digest(self.entries())[:16]
        self.assertEqual(
            result.report_path.name,
            f"{importer.REPORT_PREFIX}-dry-run-20260808T123456Z-{digest}.json",
        )

    def test_this_module_has_no_phrase_update_or_delete_request_path(self):
        source = Path(importer.__file__).read_text(encoding="utf-8")
        self.assertNotIn("/phrases", source)
        for method in ("PUT", "PATCH", "DELETE"):
            with self.subTest(method=method):
                self.assertIsNone(re.search(rf'"{method}"', source))
                self.assertIsNone(re.search(rf"'{method}'", source))
        self.assertEqual(importer.READ_PATHS, (VOCABULARY_PATH, INTERPRETATIONS_PATH))
        guard = importer.BatchWriteGuard(
            FakeTransport([harness.HttpResponse(200, {"phrases": []})]),
            max_gets=4, max_posts=1, sleep=self.slept.append,
        )
        with self.assertRaises(harness.SafetyError):
            guard.send(
                harness.HttpRequest("GET", harness.build_query_path("phrases", {"voc_id": VOC_A})),
                self.credential,
            )
        guard.arm(1)
        with self.assertRaises(harness.SafetyError):
            guard.send(
                harness.HttpRequest("POST", "/open/api/v1/phrases", {
                    "phrase": {"voc_id": VOC_A, "phrase": "x", "interpretation": TEXT_A,
                               "tags": ["MBA", "BEC", "GMAT"], "origin": "自编"}}),
                self.credential,
            )
        # Arming an interpretation update never opens the phrase update path.
        second = importer.BatchWriteGuard(
            FakeTransport([]), max_gets=1, max_posts=1, sleep=self.slept.append
        )
        second.arm(1, f"{INTERPRETATIONS_PATH}/{RECORD_A}")
        with self.assertRaises(harness.SafetyError):
            second.send(
                harness.HttpRequest("POST", f"/open/api/v1/phrases/{RECORD_A}", {
                    "phrase": {"phrase": "x", "interpretation": TEXT_A,
                               "tags": ["MBA", "BEC", "GMAT"], "origin": "自编"}}),
                self.credential,
            )
        self.assertEqual(second.post_count, 0)
        for method in ("PUT", "PATCH", "DELETE"):
            with self.subTest(method=method):
                with self.assertRaises(harness.SafetyError):
                    harness.HttpRequest(method, importer.CREATE_PATH, {})
        self.assertEqual((guard.get_count, guard.post_count), (0, 0))

    def test_the_gate_requires_allow_network_a_terminal_and_a_readable_batch(self):
        path = self.batch_file()
        base = ["--mode", importer.MODE_DRY_RUN, "--input", str(path),
                "--account-label", ACCOUNT_LABEL]
        cases = (
            ("no allow-network", base, {"stdin_isatty": lambda: True}),
            ("not a terminal", base + ["--allow-network"], {"stdin_isatty": lambda: False}),
        )
        for name, argv, extra in cases:
            with self.subTest(case=name):
                stream = io.StringIO()
                with mock.patch("sys.stdout", stream):
                    code = importer.main(
                        argv,
                        token_prompt=lambda _message: FAKE_TOKEN,
                        transport_factory=lambda: FakeTransport([]),
                        report_factory=self.private_report,
                        **extra,
                    )
                self.assertEqual(code, 3)
                self.assertIn(importer.BLOCKED_GATE_MESSAGE, stream.getvalue())
        stream = io.StringIO()
        with mock.patch("sys.stdout", stream):
            code = importer.main(
                ["--mode", importer.MODE_DRY_RUN, "--input", str(path.parent / "gone.md"),
                 "--account-label", ACCOUNT_LABEL, "--allow-network"],
                token_prompt=lambda _message: FAKE_TOKEN,
                transport_factory=lambda: FakeTransport([]),
                stdin_isatty=lambda: True,
                report_factory=self.private_report,
            )
        self.assertEqual(code, 3)
        self.assertIn("input-unreadable", stream.getvalue())

    def test_the_cli_runs_a_dry_run_and_a_create_batch_end_to_end(self):
        path = self.batch_file()
        captured = {}

        def transport_factory(responses):
            def build():
                captured["transport"] = FakeTransport(responses)
                return captured["transport"]
            return build

        stream = io.StringIO()
        with mock.patch("sys.stdout", stream):
            code = importer.main(
                ["--mode", importer.MODE_DRY_RUN, "--input", str(path),
                 "--account-label", ACCOUNT_LABEL, "--allow-network"],
                token_prompt=lambda _message: FAKE_TOKEN,
                transport_factory=transport_factory(self.preflight_pair()),
                stdin_isatty=lambda: True,
                report_factory=self.private_report,
                sleep=self.slept.append,
            )
        self.assertEqual(code, 0)
        self.assertIn("READY 2", stream.getvalue())
        self.assertIn("WRITES 0", stream.getvalue())
        self.assertEqual(captured["transport"].methods(), ["GET"] * 4)

        stream = io.StringIO()
        with mock.patch("sys.stdout", stream):
            code = importer.main(
                ["--mode", importer.MODE_CREATE, "--input", str(path),
                 "--account-label", ACCOUNT_LABEL, "--allow-network"],
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: self.expected_confirmation,
                transport_factory=transport_factory(self.created_pair()),
                stdin_isatty=lambda: True,
                report_factory=self.private_report,
                sleep=self.slept.append,
            )
        printed = stream.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("VERIFIED 2/2", printed)
        self.assertEqual(captured["transport"].methods().count("POST"), 2)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, printed)

    def test_the_cli_runs_an_update_batch_end_to_end(self):
        path = self.batch_file()
        captured = {}

        def transport_factory():
            captured["transport"] = FakeTransport(self.updated_pair())
            return captured["transport"]

        stream = io.StringIO()
        with mock.patch("sys.stdout", stream):
            code = importer.main(
                ["--mode", importer.MODE_UPDATE, "--input", str(path),
                 "--account-label", ACCOUNT_LABEL, "--allow-network"],
                token_prompt=lambda _message: FAKE_TOKEN,
                confirmation_prompt=lambda _message: self.expected_update_confirmation,
                transport_factory=transport_factory,
                stdin_isatty=lambda: True,
                report_factory=self.private_report,
                sleep=self.slept.append,
            )
        printed = stream.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("UPDATED 2/2", printed)
        self.assertEqual(captured["transport"].calls()[4:], [
            ("POST", f"{INTERPRETATIONS_PATH}/{RECORD_A}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("POST", f"{INTERPRETATIONS_PATH}/{RECORD_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
        ])
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, printed)

    def updated_pair(self):
        return [
            voc_response(VOC_A, SPELLING_A),
            collection([record(RECORD_A, OLD_A, tags=OLD_TAGS)]),
            voc_response(VOC_B, SPELLING_B),
            collection([record(RECORD_B, OLD_B, tags=OLD_TAGS)]),
            harness.HttpResponse(200, {}), collection([record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(200, {}), collection([record(RECORD_B, TEXT_B)]),
        ]

    @property
    def expected_update_confirmation(self):
        """The update confirmation the CLI run above is expected to print."""
        def planned(ordinal, spelling, vocabulary_id, record_id, old_text, text):
            return importer.PlannedItem(
                ordinal=ordinal, spelling=spelling, returned_spelling=spelling,
                vocabulary_id=vocabulary_id, interpretation=text,
                request_body=importer.update_body(text),
                baseline=importer.RecordBaseline(
                    record_id=record_id, interpretation=old_text,
                    tags=tuple(OLD_TAGS), status="PUBLISHED",
                ),
            )

        return importer.BatchPlan(
            account_label=ACCOUNT_LABEL,
            credential_fingerprint=self.credential.fingerprint,
            items=(planned(1, SPELLING_A, VOC_A, RECORD_A, OLD_A, TEXT_A),
                   planned(2, SPELLING_B, VOC_B, RECORD_B, OLD_B, TEXT_B)),
            digest=importer.batch_digest(self.entries(), mode=importer.MODE_UPDATE),
            mode=importer.MODE_UPDATE,
        ).expected_confirmation

    @property
    def expected_confirmation(self):
        """The confirmation the CLI run above is expected to print."""
        entries = self.entries()
        first = importer.PlannedItem(
            ordinal=1, spelling=SPELLING_A, returned_spelling=SPELLING_A,
            vocabulary_id=VOC_A, interpretation=TEXT_A,
            request_body=importer.create_body(VOC_A, TEXT_A),
        )
        second = importer.PlannedItem(
            ordinal=2, spelling=SPELLING_B, returned_spelling=SPELLING_B,
            vocabulary_id=VOC_B, interpretation=TEXT_B,
            request_body=importer.create_body(VOC_B, TEXT_B),
        )
        return importer.BatchPlan(
            account_label=ACCOUNT_LABEL,
            credential_fingerprint=self.credential.fingerprint,
            items=(first, second), digest=importer.batch_digest(entries),
        ).expected_confirmation

    def test_an_internal_failure_prints_only_the_fixed_project_sentence(self):
        path = self.batch_file()
        with mock.patch.object(importer, "run_batch",
                               side_effect=RuntimeError(TRANSPORT_SENTINEL)):
            stream = io.StringIO()
            with mock.patch("sys.stdout", stream):
                code = importer.main(
                    ["--mode", importer.MODE_CREATE, "--input", str(path),
                     "--account-label", ACCOUNT_LABEL, "--allow-network"],
                    token_prompt=lambda _message: FAKE_TOKEN,
                    transport_factory=lambda: FakeTransport([]),
                    stdin_isatty=lambda: True,
                    report_factory=self.private_report,
                )
        self.assertEqual(code, 4)
        self.assertIn(importer.BLOCKED_INTERNAL_MESSAGE, stream.getvalue())
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, stream.getvalue())

    def test_every_emitted_enum_is_project_owned(self):
        for allowed, value in ((importer.MODES, "replace"),
                               (importer.PREFLIGHT_STATES, "ready"),
                               (importer.ERROR_CLASSES, "unknown"),
                               (importer.OUTCOMES, "succeeded"),
                               (importer.PARSE_REASONS, "bad")):
            with self.subTest(value=value):
                with self.assertRaises(harness.SafetyError):
                    importer._pinned(allowed, value)
        # A hostile string that merely compares equal never becomes the emitted
        # value: the module-owned constant object is returned instead.
        smuggled = "".join(("ready", "-create"))
        self.assertIs(importer._pinned(importer.PREFLIGHT_STATES, smuggled),
                      importer.READY_CREATE)

    def test_the_frozen_harness_and_phrase_probe_are_only_imported(self):
        source = Path(importer.__file__).read_text(encoding="utf-8")
        self.assertNotIn("phrase_create_probe", source)
        self.assertNotIn("phrase_readback_diagnostic", source)
        self.assertIsNone(re.search(r"harness\.[A-Za-z_]+\s*=", source))
        self.assertIsNone(re.search(r"setattr\(\s*harness", source))

    def test_the_fixed_contract_fails_closed_when_it_drifts(self):
        for name, value in (("TAGS", ("MBA", "BEC")), ("STATUS", "UNPUBLISHED"),
                            ("CREATE_PATH", "/open/api/v1/phrases"),
                            ("MAX_BATCH_ITEMS", 100),
                            ("BODY_FIELDS", ("voc_id", "interpretation"))):
            with self.subTest(name=name):
                with mock.patch.object(importer, name, value):
                    with self.assertRaises(harness.SafetyError):
                        importer.validate_contract()
        importer.validate_contract()


# --------------------------------------------------------------------------- #
# Issue #51 — the explicit main-account opt-in
# --------------------------------------------------------------------------- #


class MainAccountFixtures(ImporterFixtures):
    """Offline plumbing for the main-account path, beside the secondary one."""

    def setUp(self):
        super().setUp()
        self.main_credential = importer.MainAccountCredential(MAIN_TOKEN, MAIN_LABEL)

    def batch_file(self, document=TWO_ENTRY_DOCUMENT):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "batch.md"
        path.write_text(document, encoding="utf-8")
        return path

    def created_pair(self):
        return self.preflight_pair() + [
            harness.HttpResponse(201, {}), collection([record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(201, {}), collection([record(RECORD_B, TEXT_B)]),
        ]

    def updated_pair(self):
        return [
            voc_response(VOC_A, SPELLING_A),
            collection([record(RECORD_A, OLD_A, tags=OLD_TAGS)]),
            voc_response(VOC_B, SPELLING_B),
            collection([record(RECORD_B, OLD_B, tags=OLD_TAGS)]),
            harness.HttpResponse(200, {}), collection([record(RECORD_A, TEXT_A)]),
            harness.HttpResponse(200, {}), collection([record(RECORD_B, TEXT_B)]),
        ]

    def main_plan(self, *, mode=importer.MODE_CREATE, account_mode=None,
                  account_label=None):
        """The plan a two-item run over `created_pair`/`updated_pair` builds.

        The same helper builds the secondary-mode plan for the same document, so
        the two account modes can be compared field for field.
        """
        entries = self.entries()
        if mode == importer.MODE_UPDATE:
            items = tuple(
                importer.PlannedItem(
                    ordinal=ordinal, spelling=spelling, returned_spelling=spelling,
                    vocabulary_id=vocabulary_id, interpretation=text,
                    request_body=importer.update_body(text),
                    baseline=importer.RecordBaseline(
                        record_id=record_id, interpretation=old_text,
                        tags=tuple(OLD_TAGS), status="PUBLISHED",
                    ),
                )
                for ordinal, spelling, vocabulary_id, record_id, old_text, text in (
                    (1, SPELLING_A, VOC_A, RECORD_A, OLD_A, TEXT_A),
                    (2, SPELLING_B, VOC_B, RECORD_B, OLD_B, TEXT_B),
                )
            )
        else:
            items = tuple(
                importer.PlannedItem(
                    ordinal=ordinal, spelling=spelling, returned_spelling=spelling,
                    vocabulary_id=vocabulary_id, interpretation=text,
                    request_body=importer.create_body(vocabulary_id, text),
                )
                for ordinal, spelling, vocabulary_id, text in (
                    (1, SPELLING_A, VOC_A, TEXT_A),
                    (2, SPELLING_B, VOC_B, TEXT_B),
                )
            )
        account = account_mode if account_mode is not None else importer.ACCOUNT_MAIN
        default_label = MAIN_LABEL if account == importer.ACCOUNT_MAIN else ACCOUNT_LABEL
        return importer.BatchPlan(
            account_label=account_label or default_label,
            credential_fingerprint=(
                self.main_credential.fingerprint
                if account == importer.ACCOUNT_MAIN
                else self.credential.fingerprint
            ),
            items=items,
            digest=importer.batch_digest(entries, mode=mode),
            mode=mode,
            account_mode=account,
        )

    @property
    def main_create_confirmation(self):
        return self.main_plan().expected_confirmation

    def drive_main(self, responses, *, mode=importer.MODE_DRY_RUN,
                   document=TWO_ENTRY_DOCUMENT, confirm=None, report=None):
        transport = FakeTransport(responses)
        lines = []
        result = importer.run_batch(
            mode=mode,
            entries=self.entries(document),
            transport=transport,
            credential=self.main_credential,
            account_label=MAIN_LABEL,
            confirm=confirm if confirm is not None else self.confirm,
            emit=lines.append,
            sleep=self.slept.append,
            report=report,
            account_mode=importer.ACCOUNT_MAIN,
        )
        return result, transport, "\n".join(lines)

    def cli_main(self, argv, *, responses=(), confirmation=None,
                 transport_factory=None):
        """Run the CLI, recording every hidden prompt and every transport built."""
        prompts, transports = [], []

        def build():
            transport = FakeTransport(list(responses))
            transports.append(transport)
            return transport

        def token_prompt(message):
            prompts.append(message)
            return MAIN_TOKEN

        stream = io.StringIO()
        with mock.patch("sys.stdout", stream):
            code = importer.main(
                argv,
                token_prompt=token_prompt,
                confirmation_prompt=(
                    None if confirmation is None else (lambda message: confirmation)
                ),
                transport_factory=(
                    build if transport_factory is None else transport_factory
                ),
                stdin_isatty=lambda: True,
                report_factory=self.private_report,
                sleep=self.slept.append,
            )
        return code, stream.getvalue(), prompts, transports


class MainAccountGateTests(MainAccountFixtures, unittest.TestCase):
    def test_a_main_label_without_the_opt_in_blocks_before_the_token_prompt(self):
        """No opt-in means the frozen secondary policy, and it rejects these."""
        for label in MAIN_LABELS:
            with self.subTest(label=label):
                code, printed, prompts, transports = self.cli_main(
                    ["--mode", importer.MODE_DRY_RUN, "--input", str(self.batch_file()),
                     "--account-label", label, "--allow-network"],
                )
                self.assertEqual(code, 3)
                self.assertEqual(prompts, [])
                self.assertEqual(transports, [])
                self.assertIn(importer.BLOCKED_MAIN_ACCOUNT_MESSAGE, printed)
                self.assertNotIn(MAIN_TOKEN, printed)
                # And the frozen harness still rejects the label outright.
                with self.assertRaises(harness.SafetyError):
                    harness._validate_account_label_shape(label)

    def test_a_main_label_without_the_opt_in_blocks_before_a_transport_exists(self):
        for label in MAIN_LABELS:
            with self.subTest(label=label):
                def refuse():
                    raise AssertionError("no transport may be built for a blocked run")

                code, printed, prompts, _transports = self.cli_main(
                    ["--mode", importer.MODE_CREATE, "--input", str(self.batch_file()),
                     "--account-label", label, "--allow-network"],
                    transport_factory=refuse,
                )
                self.assertEqual(code, 3)
                self.assertEqual(prompts, [])
                self.assertIn(importer.BLOCKED_MAIN_ACCOUNT_MESSAGE, printed)

    def test_the_opt_in_with_a_secondary_or_unreviewed_label_blocks(self):
        """Opt-in alone authorizes nothing: the label must be reviewed too."""
        for label in (ACCOUNT_LABEL, "secondary", "副号", "测试账号", "issue51-test",
                      "main", "primary account", "owner", "prod", "production",
                      "主账户", "主号", "生产", "主账号-test", "unlabelled"):
            with self.subTest(label=label):
                code, printed, prompts, transports = self.cli_main(
                    ["--mode", importer.MODE_DRY_RUN, "--input", str(self.batch_file()),
                     "--account-label", label, "--allow-network",
                     "--allow-main-account"],
                )
                self.assertEqual(code, 3)
                self.assertEqual(prompts, [])
                self.assertEqual(transports, [])
                self.assertIn("BLOCKED", printed)
                self.assertNotIn(MAIN_TOKEN, printed)

    def test_only_the_narrow_reviewed_label_family_is_a_main_account_label(self):
        for label in MAIN_LABELS:
            with self.subTest(label=label):
                self.assertIn(
                    importer.validate_main_account_label(label),
                    importer.MAIN_ACCOUNT_LABELS,
                )
        self.assertEqual(importer.MAIN_ACCOUNT_LABELS, ("主账号", "main-account"))
        for label in ("prod", "production", "生产", "main", "primary", "owner",
                      "主账户", "主号", ACCOUNT_LABEL, "主账号 ", "", None, 7):
            with self.subTest(label=label):
                with self.assertRaises(harness.SafetyError):
                    importer.validate_main_account_label(label)
        # And every reviewed main label is still rejected by the frozen gate.
        for label in importer.MAIN_ACCOUNT_LABELS:
            with self.assertRaises(harness.SafetyError):
                harness._validate_account_label_shape(label)

    def test_neither_account_mode_accepts_the_other_modes_credential(self):
        cases = (
            ("secondary credential, main run", self.credential, MAIN_LABEL,
             importer.ACCOUNT_MAIN),
            ("main credential, secondary run", self.main_credential, ACCOUNT_LABEL,
             importer.ACCOUNT_SECONDARY),
            ("main credential, main label, secondary run", self.main_credential,
             MAIN_LABEL, importer.ACCOUNT_SECONDARY),
        )
        for name, credential, label, account_mode in cases:
            with self.subTest(case=name):
                transport = FakeTransport([])
                with self.assertRaises(harness.SafetyError):
                    importer.run_batch(
                        mode=importer.MODE_DRY_RUN,
                        entries=self.entries(),
                        transport=transport,
                        credential=credential,
                        account_label=label,
                        emit=lambda line: None,
                        sleep=self.slept.append,
                        account_mode=account_mode,
                    )
                self.assertEqual(transport.requests, [])

    def test_a_main_credential_requires_a_reviewed_main_label_and_stays_redacted(self):
        for label in (ACCOUNT_LABEL, "main", "prod", "主账户", ""):
            with self.subTest(label=label):
                with self.assertRaises(harness.SafetyError):
                    importer.MainAccountCredential(MAIN_TOKEN, label)
        credential = importer.MainAccountCredential(MAIN_TOKEN, "MAIN-ACCOUNT")
        # The bound label is this project's own constant, never the typed text.
        self.assertEqual(credential.account_label, "main-account")
        self.assertEqual(
            credential.source_name, importer.MAIN_ACCOUNT_CREDENTIAL_SOURCE
        )
        self.assertNotEqual(
            importer.MAIN_ACCOUNT_CREDENTIAL_SOURCE,
            harness.TEST_ACCOUNT_CREDENTIAL_SOURCE,
        )
        rendered = repr(credential) + str(credential) + credential.fingerprint
        self.assertNotIn(MAIN_TOKEN, rendered)

    def test_the_contract_fails_closed_if_the_main_account_gate_drifts(self):
        for name, value in (
            ("MAIN_ACCOUNT_LABELS", ("主账号", "main-account", "production")),
            ("MAIN_ACCOUNT_LABELS", ("主账号", "secondary-main")),
            ("MAIN_ACCOUNT_LABELS", ("主账号",)),
            ("MAIN_CREATE_CONFIRMATION_PREFIX", importer.CONFIRMATION_PREFIX),
            ("MAIN_UPDATE_CONFIRMATION_PREFIX", importer.MAIN_CREATE_CONFIRMATION_PREFIX),
            ("MAIN_ACCOUNT_CREDENTIAL_SOURCE", harness.TEST_ACCOUNT_CREDENTIAL_SOURCE),
            ("MAIN_TOKEN_PROMPT", importer.TOKEN_PROMPT),
            ("ACCOUNT_MODES", ("secondary",)),
        ):
            with self.subTest(name=name, value=value):
                with mock.patch.object(importer, name, value):
                    with self.assertRaises(harness.SafetyError):
                        importer.validate_contract()
        importer.validate_contract()


class MainAccountRunTests(MainAccountFixtures, unittest.TestCase):
    def test_the_opt_in_and_a_reviewed_label_reach_a_dry_run_with_zero_posts(self):
        code, printed, prompts, transports = self.cli_main(
            ["--mode", importer.MODE_DRY_RUN, "--input", str(self.batch_file()),
             "--account-label", "主账号", "--allow-network", "--allow-main-account"],
            responses=self.preflight_pair(),
        )
        self.assertEqual(code, 0)
        self.assertEqual(prompts, [importer.MAIN_TOKEN_PROMPT])
        self.assertNotEqual(importer.MAIN_TOKEN_PROMPT, importer.TOKEN_PROMPT)
        self.assertEqual(transports[0].methods(), ["GET"] * 4)
        self.assertEqual(transports[0].methods().count("POST"), 0)
        self.assertIn("READY 2", printed)
        self.assertIn("WRITES 0", printed)

    def test_the_main_account_warning_is_visible_before_the_preflight(self):
        _result, _transport, output = self.drive_main(self.preflight_pair())
        banner = output.index("MAIN ACCOUNT MODE IS ACTIVE")
        self.assertLess(banner, output.index("BATCH INTERPRETATION IMPORTER"))
        for statement in (
            "MAIN ACCOUNT MODE IS ACTIVE",
            "NO reliable account-identity check",
            "operator's responsibility",
            "Obtain the Token while logged into the intended main account",
            "change real account data",
        ):
            with self.subTest(statement=statement):
                self.assertIn(statement, output)
        self.assertIn("account [REDACTED] (MAIN ACCOUNT", output)
        self.assertNotIn("secondary/test label accepted", output)

    def test_main_create_uses_the_existing_one_post_and_readback_machinery(self):
        code, printed, _prompts, transports = self.cli_main(
            ["--mode", importer.MODE_CREATE, "--input", str(self.batch_file()),
             "--account-label", "主账号", "--allow-network", "--allow-main-account"],
            responses=self.created_pair(),
            confirmation=self.main_create_confirmation,
        )
        self.assertEqual(code, 0)
        self.assertIn("VERIFIED 2/2", printed)
        self.assertEqual(transports[0].calls(), [
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_A}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("GET", f"{VOCABULARY_PATH}?spelling={SPELLING_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
            ("POST", INTERPRETATIONS_PATH),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("POST", INTERPRETATIONS_PATH),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
        ])
        self.assertEqual(transports[0].methods().count("POST"), 2)
        self.assertIn("retries 0", printed)

    def test_main_update_uses_the_existing_one_post_and_readback_machinery(self):
        code, printed, _prompts, transports = self.cli_main(
            ["--mode", importer.MODE_UPDATE, "--input", str(self.batch_file()),
             "--account-label", "main-account", "--allow-network",
             "--allow-main-account"],
            responses=self.updated_pair(),
            confirmation=self.main_plan(
                mode=importer.MODE_UPDATE, account_label="main-account"
            ).expected_confirmation,
        )
        self.assertEqual(code, 0)
        self.assertIn("UPDATED 2/2", printed)
        self.assertEqual(transports[0].calls()[4:], [
            ("POST", f"{INTERPRETATIONS_PATH}/{RECORD_A}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_A}"),
            ("POST", f"{INTERPRETATIONS_PATH}/{RECORD_B}"),
            ("GET", f"{INTERPRETATIONS_PATH}?voc_id={VOC_B}"),
        ])
        self.assertEqual(transports[0].methods().count("POST"), 2)

    def test_a_failed_main_post_is_never_retried_and_stops_the_rest(self):
        responses = self.preflight_pair() + [
            harness.TransportError(TRANSPORT_SENTINEL),
            collection([]),
        ]
        result, transport, output = self.drive_main(
            responses, mode=importer.MODE_CREATE,
            confirm=lambda plan: plan.expected_confirmation,
        )
        self.assertEqual(result.status, "stopped")
        self.assertEqual(result.post_count, 1)
        self.assertEqual(transport.methods().count("POST"), 1)
        self.assertEqual(result.outcomes[1].outcome, importer.NOT_ATTEMPTED)
        self.assertIn("Nothing was rolled back or deleted", output)
        self.assertNotIn(TRANSPORT_SENTINEL, output)

    def test_an_already_matching_main_item_stays_a_zero_write_no_op(self):
        matching = [
            voc_response(VOC_A, SPELLING_A),
            collection([record(RECORD_A, TEXT_A)]),
            voc_response(VOC_B, SPELLING_B),
            collection([record(RECORD_B, TEXT_B)]),
        ]
        result, transport, output = self.drive_main(
            matching, mode=importer.MODE_UPDATE,
            confirm=lambda plan: self.fail("no confirmation may be requested"),
        )
        self.assertEqual(result.status, "satisfied")
        self.assertEqual(result.post_count, 0)
        self.assertEqual(result.no_op_count, 2)
        self.assertNotIn("POST", transport.methods())
        self.assertIn("NOTHING TO UPDATE", output)
        self.assertIn("WRITES 0", output)
        # One matching item and one changed item: still exactly one POST.
        mixed = [
            voc_response(VOC_A, SPELLING_A),
            collection([record(RECORD_A, OLD_A, tags=OLD_TAGS)]),
            voc_response(VOC_B, SPELLING_B),
            collection([record(RECORD_B, TEXT_B)]),
            harness.HttpResponse(200, {}),
            collection([record(RECORD_A, TEXT_A)]),
        ]
        result, transport, _output = self.drive_main(
            mixed, mode=importer.MODE_UPDATE,
            confirm=lambda plan: plan.expected_confirmation,
        )
        self.assertEqual(result.status, "verified")
        self.assertEqual(result.post_count, 1)
        self.assertEqual(result.no_op_count, 1)

    def test_a_main_account_run_records_its_account_mode_in_the_private_report(self):
        report = self.private_report()
        result, _transport, _output = self.drive_main(
            self.preflight_pair(), report=report
        )
        document = json.loads(result.report_path.read_text(encoding="utf-8"))
        self.assertEqual(document["account_mode"], importer.ACCOUNT_MAIN)
        self.assertEqual(document["post_count"], 0)
        importer._assert_no_raw_identifiers(document)
        # The label itself is still never persisted.
        self.assertNotIn(MAIN_LABEL, json.dumps(document, ensure_ascii=False))

    def test_a_secondary_run_still_reports_the_secondary_account_mode(self):
        report = self.private_report()
        result, _transport, _output = self.drive(self.preflight_pair(), report=report)
        document = json.loads(result.report_path.read_text(encoding="utf-8"))
        self.assertEqual(document["account_mode"], importer.ACCOUNT_SECONDARY)

class MainAccountConfirmationIsolationTests(MainAccountFixtures, unittest.TestCase):
    def test_a_main_confirmation_is_a_short_distinct_bound_token(self):
        for mode, pattern in (
            (importer.MODE_CREATE, r"^CONFIRM MAIN CREATE [0-9a-f]{16}$"),
            (importer.MODE_UPDATE, r"^CONFIRM MAIN UPDATE [0-9a-f]{16}$"),
        ):
            with self.subTest(mode=mode):
                plan = self.main_plan(mode=mode)
                shown = plan.expected_confirmation
                self.assertRegex(shown, pattern)
                self.assertEqual(shown, shown.strip())
                self.assertLessEqual(
                    len(shown), importer.MAX_COPIED_CONFIRMATION_CHARS
                )
                # The 16 hex chars are still the prefix of the FULL binding digest.
                self.assertEqual(
                    plan.binding_digest,
                    importer._digest(plan.confirmation_binding())[:16],
                )
                # The block shows it verbatim and pasteably, and the block alone
                # says this is a main-account write.
                lines = importer.confirmation_lines(plan)
                displayed = [line for line in lines if line == shown]
                self.assertEqual(len(displayed), 1)
                block = "\n".join(lines)
                self.assertIn("REAL MAIN MAIMEMO ACCOUNT", block)
                self.assertIn(f"TOKEN-FP: {plan.credential_fingerprint}", block)
                self.assertIn(harness.WRITE_PRICING_TERMS_CLAUSE, block)
                self.assertIn(importer.BATCH_ONE_POST_CLAUSE, block)
                self.assertIn(importer.MAIN_PRICING_TERMS_GATE, block)
                self.assertIn(f"({len(shown)} characters", block)
                plan.validate_confirmation(shown)
                for raw in RAW_IDS + (MAIN_TOKEN, MAIN_LABEL):
                    self.assertNotIn(raw, block)

    def test_the_main_binding_still_covers_every_outcome_relevant_field(self):
        for mode in (importer.MODE_CREATE, importer.MODE_UPDATE):
            with self.subTest(mode=mode):
                plan = self.main_plan(mode=mode)
                binding = plan.confirmation_binding()
                expected = [
                    "operation", "mode", "host", "path", "tags", "status",
                    "item_count", "batch_digest", "credential_fingerprint",
                    "items", "account_label", "vocabulary_ids", "request_bodies",
                    "write_policy", "pricing_and_terms_checked", "account_mode",
                ]
                if mode == importer.MODE_UPDATE:
                    expected += ["no_op_count", "record_ids", "write_paths"]
                for key in expected:
                    self.assertIn(key, binding)
                self.assertEqual(binding["account_mode"], importer.ACCOUNT_MAIN)
                self.assertEqual(binding["write_policy"], importer.WRITE_POLICY)

    def test_a_secondary_confirmation_can_never_authorize_a_main_account_run(self):
        for mode in (importer.MODE_CREATE, importer.MODE_UPDATE):
            with self.subTest(mode=mode):
                main = self.main_plan(mode=mode)
                secondary = self.main_plan(
                    mode=mode, account_mode=importer.ACCOUNT_SECONDARY
                )
                self.assertNotEqual(
                    main.expected_confirmation, secondary.expected_confirmation
                )
                self.assertNotEqual(main.binding_digest, secondary.binding_digest)
                with self.assertRaises(harness.ConfirmationError):
                    main.validate_confirmation(secondary.expected_confirmation)
                with self.assertRaises(harness.ConfirmationError):
                    secondary.validate_confirmation(main.expected_confirmation)
                # The account mode is bound structurally, not only through the label.
                self.assertNotIn("account_mode", secondary.confirmation_binding())
                self.assertIn("account_mode", main.confirmation_binding())

    def test_a_pasted_secondary_confirmation_aborts_a_main_run_before_any_post(self):
        secondary = self.main_plan(account_mode=importer.ACCOUNT_SECONDARY).expected_confirmation
        result, transport, output = self.drive_main(
            self.created_pair(),
            mode=importer.MODE_CREATE,
            confirm=lambda _plan: secondary,
        )
        self.assertEqual(result.status, "blocked")
        self.assertEqual(result.post_count, 0)
        self.assertNotIn("POST", transport.methods())
        self.assertIn("ABORTED BEFORE THE FIRST POST", output)

    def test_a_pasted_main_confirmation_aborts_a_secondary_run_before_any_post(self):
        main = self.main_plan().expected_confirmation
        result, transport, output = self.drive(
            self.created_pair(),
            mode=importer.MODE_CREATE,
            confirm=lambda _plan: main,
        )
        self.assertEqual(result.status, "blocked")
        self.assertEqual(result.post_count, 0)
        self.assertNotIn("POST", transport.methods())
        self.assertIn("ABORTED BEFORE THE FIRST POST", output)

    def test_the_frozen_secondary_confirmations_are_unchanged_by_this_issue(self):
        """Issue #51 adds a path beside the reviewed one; it does not move it."""
        create = self.main_plan(account_mode=importer.ACCOUNT_SECONDARY)
        self.assertEqual(
            create.expected_confirmation,
            "CONFIRM BATCH INTERPRETATION CREATE: cdbef87c197476cf ITEMS: 2 "
            "TOKEN-FP: 632caaac01f6049e PRICING-TERMS-CHECKED: YES "
            "EXACTLY-ONE-POST-PER-ITEM-NO-RETRY-IMMEDIATE-READBACK",
        )
        self.assertEqual(len(create.expected_confirmation), 170)
        self.assertEqual(importer.confirmation_lines(create), [
            "CREATE CONFIRMATION — 2 items, one POST each, no retry",
            f"batch digest {create.digest}",
            f"MANUAL GATE: {importer.PRICING_TERMS_GATE}",
            "Copy the next line exactly into the hidden prompt:",
            create.expected_confirmation,
            "",
        ])
        update = self.main_plan(
            mode=importer.MODE_UPDATE, account_mode=importer.ACCOUNT_SECONDARY
        )
        self.assertRegex(update.expected_confirmation, r"^CONFIRM UPDATE [0-9a-f]{16}$")
        self.assertEqual(len(update.expected_confirmation), 31)
        self.assertEqual(
            importer.confirmation_lines(update)[0],
            "UPDATE CONFIRMATION — 2 existing custom interpretations replaced, "
            "one POST each, no retry (0 already matching, no request)",
        )
        # The secondary preview line is byte-identical to the reviewed one.
        _result, _transport, output = self.drive(self.preflight_pair())
        self.assertIn("account [REDACTED] (secondary/test label accepted)   ", output)
        self.assertNotIn("MAIN ACCOUNT", output)


class MainAccountContainmentTests(MainAccountFixtures, unittest.TestCase):
    def test_the_main_token_never_reaches_output_a_report_a_repr_or_a_traceback(self):
        report = self.private_report()
        transport = FakeTransport(self.created_pair())
        lines = []
        result = importer.run_batch(
            mode=importer.MODE_CREATE, entries=self.entries(), transport=transport,
            credential=self.main_credential, account_label=MAIN_LABEL,
            confirm=lambda plan: plan.expected_confirmation,
            emit=lines.append, sleep=self.slept.append, report=report,
            account_mode=importer.ACCOUNT_MAIN,
        )
        rendered = "\n".join(lines) + repr(result) + str(result)
        rendered += repr(self.main_credential) + str(self.main_credential)
        rendered += "".join(repr(item) for item in result.preflight)
        rendered += repr(self.main_plan())
        rendered += result.report_path.read_text(encoding="utf-8")
        try:
            importer.MainAccountCredential(MAIN_TOKEN, ACCOUNT_LABEL)
        except harness.SafetyError as rejected:
            rendered += "".join(
                traceback.format_exception_only(type(rejected), rejected)
            )
        else:  # pragma: no cover - the label above is never accepted
            self.fail("a secondary label must never build a main credential")
        self.assertNotIn(MAIN_TOKEN, rendered)
        self.assertNotIn(MAIN_LABEL, rendered)
        for raw in RAW_IDS:
            self.assertNotIn(raw, rendered)

    def test_the_main_cli_prints_no_token_on_stdout_or_stderr(self):
        errors = io.StringIO()
        with mock.patch("sys.stderr", errors):
            code, printed, _prompts, _transports = self.cli_main(
                ["--mode", importer.MODE_CREATE, "--input", str(self.batch_file()),
                 "--account-label", "主账号", "--allow-network",
                 "--allow-main-account"],
                responses=self.created_pair(),
                confirmation=self.main_plan().expected_confirmation,
            )
        self.assertEqual(code, 0)
        for stream in (printed, errors.getvalue()):
            self.assertNotIn(MAIN_TOKEN, stream)
            for sentinel in SENTINELS:
                self.assertNotIn(sentinel, stream)

    def test_an_internal_main_failure_still_prints_only_the_fixed_sentence(self):
        with mock.patch.object(importer, "run_batch",
                               side_effect=RuntimeError(MAIN_TOKEN)):
            code, printed, _prompts, _transports = self.cli_main(
                ["--mode", importer.MODE_CREATE, "--input", str(self.batch_file()),
                 "--account-label", "主账号", "--allow-network",
                 "--allow-main-account"],
            )
        self.assertEqual(code, 4)
        self.assertIn(importer.BLOCKED_INTERNAL_MESSAGE, printed)
        self.assertNotIn(MAIN_TOKEN, printed)

    def test_the_main_cli_never_accepts_a_token_or_a_record_id_on_argv(self):
        stream = io.StringIO()
        for argv in (
            ["--mode", "create", "--input", "batch.md", "--account-label", MAIN_LABEL,
             "--allow-main-account", "--token", MAIN_TOKEN],
            ["--mode", "update", "--input", "batch.md", "--account-label", MAIN_LABEL,
             "--allow-main-account", "--record-id", RECORD_A],
            ["--mode", "delete", "--input", "batch.md", "--account-label", MAIN_LABEL,
             "--allow-main-account"],
            ["--mode", "create", "--input", "batch.md", "--account-label", MAIN_LABEL,
             "--allow-main-account=yes"],
        ):
            with self.subTest(argv=argv[-1]):
                with mock.patch("sys.stderr", stream):
                    with self.assertRaises(SystemExit) as context:
                        importer.parse_args(list(argv))
                self.assertEqual(context.exception.code, 2)
        self.assertNotIn(MAIN_TOKEN, stream.getvalue())
        # The opt-in defaults to off and is a plain flag.
        self.assertIs(
            importer.parse_args(
                ["--input", "batch.md", "--account-label", ACCOUNT_LABEL]
            ).allow_main_account,
            False,
        )
        self.assertIs(
            importer.parse_args(
                ["--input", "batch.md", "--account-label", MAIN_LABEL,
                 "--allow-main-account"]
            ).allow_main_account,
            True,
        )

    def test_a_main_run_cannot_reach_the_network_under_the_process_guard(self):
        """With the real transport the guard, not this module, is the last line."""
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        code, printed, prompts, _transports = self.cli_main(
            ["--mode", importer.MODE_DRY_RUN, "--input", str(self.batch_file()),
             "--account-label", "主账号", "--allow-network", "--allow-main-account"],
            transport_factory=harness.ProductionHttpTransport,
        )
        self.assertEqual(prompts, [importer.MAIN_TOKEN_PROMPT])
        self.assertEqual(code, 3)
        self.assertIn("BLOCK_ERROR (transport)", printed)
        self.assertIn("requests: GET 2  POST 0  retries 0", printed)
        self.assertNotIn(MAIN_TOKEN, printed)
        for call in (lambda: socket.socket(),
                     lambda: socket.create_connection(("open.maimemo.com", 443)),
                     lambda: urllib.request.urlopen("https://open.maimemo.com/")):
            with self.subTest(call=call):
                with self.assertRaises(RuntimeError):
                    call()


class NoNetworkGuardTests(unittest.TestCase):
    def test_the_process_level_network_guard_is_active(self):
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        for call in (lambda: socket.socket(),
                     lambda: socket.create_connection(("open.maimemo.com", 443)),
                     lambda: urllib.request.urlopen("https://open.maimemo.com/")):
            with self.subTest(call=call):
                with self.assertRaises(RuntimeError) as context:
                    call()
                self.assertNotIn("open.maimemo.com", "".join(
                    traceback.format_exception_only(type(context.exception),
                                                    context.exception)))


if __name__ == "__main__":
    unittest.main()
