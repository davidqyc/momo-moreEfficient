"""Issue #32 — the small-batch interpretation importer.

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
            ["--mode", "update", "--input", "batch.md", "--account-label", ACCOUNT_LABEL],
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
            {"mode": "update", "created_at": "2026-08-08T00:00:00Z",
             "batch_digest": "0" * 64},
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
        for allowed, value in ((importer.MODES, "update"),
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
