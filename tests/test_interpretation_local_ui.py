"""Issue #54 — offline tests for the daily localhost UI adapter.

Every transport is in memory.  Under the process-level no-network guard these
tests also cannot create a socket, call ``create_connection`` or use ``urlopen``.
"""

from __future__ import annotations

from email.message import Message
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import traceback
import unittest
from unittest import mock
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import install_macos_launcher as launcher  # noqa: E402
import interpretation_batch_importer as importer  # noqa: E402
import interpretation_local_ui as ui  # noqa: E402
import issue9_live_harness as harness  # noqa: E402


FAKE_TOKEN = "FAKE_ISSUE54_MAIN_TOKEN_NOT_VALID"
VOC_A = "INVALID_ISSUE54_VOC_A"
VOC_B = "INVALID_ISSUE54_VOC_B"
VOC_C = "INVALID_ISSUE54_VOC_C"
VOC_D = "INVALID_ISSUE54_VOC_D"
RECORD_A = "INVALID_ISSUE54_RECORD_A"
RECORD_B = "INVALID_ISSUE54_RECORD_B"
RECORD_C = "INVALID_ISSUE54_RECORD_C"
OTHER_RECORD = "INVALID_ISSUE54_OTHER_RECORD"
RAW_IDS = (VOC_A, VOC_B, VOC_C, VOC_D, RECORD_A, RECORD_B, RECORD_C, OTHER_RECORD)


def voc(voc_id, spelling):
    return harness.HttpResponse(200, {"voc": {"id": voc_id, "spelling": spelling}})


def record(record_id, text, *, tags=None, status="PUBLISHED"):
    return {
        "id": record_id,
        "interpretation": text,
        "tags": list(tags) if tags is not None else ["GMAT", "MBA", "BEC"],
        "status": status,
    }


def collection(records):
    return harness.HttpResponse(200, {"interpretations": list(records)})


class FakeTransport:
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
            raise AssertionError("unexpected fake transport request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response

    def methods(self):
        return [request.method for request in self.requests]

    def calls(self):
        return [(request.method, request.path) for request in self.requests]


class TransportFactory:
    def __init__(self, *runs):
        self.runs = [list(run) for run in runs]
        self.transports = []

    def __call__(self):
        if not self.runs:
            raise AssertionError("unexpected transport construction")
        transport = FakeTransport(self.runs.pop(0))
        self.transports.append(transport)
        return transport


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


def credential():
    return importer.MainAccountCredential(FAKE_TOKEN, ui.MAIN_ACCOUNT_LABEL)


def controller(factory, *, prompt=credential, **kwargs):
    return ui.LocalUiController(
        transport_factory=factory,
        token_prompt=prompt,
        report_factory=lambda: None,
        sleep=lambda _seconds: None,
        **kwargs,
    )


class InputAdapterTests(unittest.TestCase):
    def test_ordinary_paste_becomes_the_exact_canonical_batch(self):
        pasted = "reclaim\nv. 收回；重新获得\nv. 开垦\n\nmass\nadj. 大规模的\nn. 大量\n"
        adapted = ui.adapt_batch_text(pasted)
        self.assertEqual(adapted.input_format, "ordinary-paste")
        self.assertEqual(
            adapted.canonical_text,
            "## reclaim\nv. 收回；重新获得\nv. 开垦\n\n"
            "## mass\nadj. 大规模的\nn. 大量",
        )
        self.assertEqual(
            [entry.interpretation for entry in adapted.entries],
            ["v. 收回；重新获得\nv. 开垦", "adj. 大规模的\nn. 大量"],
        )

    def test_canonical_markdown_is_accepted_without_rewriting_the_body(self):
        body = "v. 原文  \n\n   缩进和空行保留"
        document = f"## reclaim\n{body}\n"
        adapted = ui.adapt_batch_text(document)
        self.assertEqual(adapted.input_format, "canonical-markdown")
        self.assertEqual(adapted.canonical_text, document)
        self.assertEqual(adapted.entries[0].interpretation, body)

    def test_exact_compact_regression_parses_two_entries_without_blank_lines(self):
        document = "reclaim\nv. 收回\nmass\nadj. 大规模的"
        adapted = ui.adapt_batch_text(document)
        self.assertEqual(
            [(entry.spelling, entry.interpretation) for entry in adapted.entries],
            [("reclaim", "v. 收回"), ("mass", "adj. 大规模的")],
        )
        self.assertEqual(
            adapted.canonical_text,
            "## reclaim\nv. 收回\n\n## mass\nadj. 大规模的",
        )

    def test_realistic_compact_batch_supports_multiple_reviewed_pos_lines(self):
        document = (
            "reclaim\nv. 收回；重新获得\nv. 开垦\n"
            "mass\nadj. 大规模的\nn. 大量\n"
            "in bulk\nphr. 大批；大量\n"
            "therefore\nadv. 因此"
        )
        adapted = ui.adapt_batch_text(document)
        self.assertEqual(
            [entry.spelling for entry in adapted.entries],
            ["reclaim", "mass", "in bulk", "therefore"],
        )
        self.assertEqual(
            adapted.entries[1].interpretation,
            "adj. 大规模的\nn. 大量",
        )

    def test_compact_ambiguities_fail_closed_instead_of_attaching_text(self):
        cases = (
            "reclaim\nv. 收回\nmass",
            "reclaim\nv. 收回\nmass\nnot a POS definition",
            "reclaim\npossible continuation\nmass\nn. 大量",
            "reclaim\nv. 收回\nmass\nadj.",
        )
        for document in cases:
            with self.subTest(document=document.replace("\n", " / ")):
                with self.assertRaises(ui.LocalUiError) as context:
                    ui.adapt_batch_text(document)
                self.assertEqual(context.exception.code, "input-rejected")

    def test_blank_delimited_legacy_body_remains_accepted(self):
        document = "first\nowner text without POS\n\nsecond\nanother exact body"
        adapted = ui.adapt_batch_text(document)
        self.assertEqual(
            [entry.interpretation for entry in adapted.entries],
            ["owner text without POS", "another exact body"],
        )

    def test_malformed_ordinary_input_fails_closed_without_echoing_content(self):
        sentinel = "PRIVATE_ISSUE54_INPUT_SENTINEL"
        for document in ("reclaim", f"{sentinel}\n\nmass\nn. 释义", "", 7):
            with self.subTest(value=repr(document)[:20]):
                with self.assertRaises(ui.LocalUiError) as context:
                    ui.adapt_batch_text(document)
                rendered = str(context.exception) + repr(context.exception)
                self.assertNotIn(sentinel, rendered)
                self.assertEqual(context.exception.code, "input-rejected")


class MixedPreviewTests(unittest.TestCase):
    document = (
        "createword\nn. 新建\n\n"
        "updateword\nn. 新释义\n\n"
        "matchingword\nn. 已一致\n\n"
        "blockedword\nn. 阻断\n"
    )

    def preview_responses(self):
        return [
            voc(VOC_A, "createword"), collection([]),
            voc(VOC_B, "updateword"), collection([
                record(RECORD_A, "n. 旧释义", tags=["考研"])
            ]),
            voc(VOC_C, "matchingword"), collection([
                record(RECORD_B, "n. 已一致")
            ]),
            voc(VOC_D, "blockedword"), collection([
                record(RECORD_C, "n. 第一条", tags=["考研"]),
                record(OTHER_RECORD, "n. 第二条", tags=["考研"]),
            ]),
        ]

    def test_preview_is_zero_post_and_classifies_the_mixed_batch(self):
        factory = TransportFactory(self.preview_responses())
        service = controller(factory)
        service.connect()
        response = service.preview(self.document)
        self.assertEqual(factory.transports[0].methods(), ["GET"] * 8)
        self.assertNotIn("POST", factory.transports[0].methods())
        self.assertEqual(
            [item["state"] for item in response["items"]],
            [ui.UI_CREATE, ui.UI_UPDATE, ui.UI_MATCHING, ui.UI_BLOCKED],
        )
        self.assertEqual(
            response["counts"],
            {"create": 1, "update": 1, "matching": 1, "blocked": 1},
        )

    def test_update_preview_has_current_and_proposed_but_no_raw_ids(self):
        service = controller(TransportFactory(self.preview_responses()))
        service.connect()
        response = service.preview(self.document)
        update = response["items"][1]
        self.assertEqual(update["current"], "n. 旧释义")
        self.assertEqual(update["proposed"], "n. 新释义")
        rendered = json.dumps(response, ensure_ascii=False, sort_keys=True)
        for raw in RAW_IDS:
            self.assertNotIn(raw, rendered)
        self.assertNotIn("fingerprint", rendered.casefold())
        self.assertNotIn("voc_id", rendered)
        self.assertNotIn("record_id", rendered)

    def test_token_is_absent_from_preview_repr_exception_and_response(self):
        service = controller(TransportFactory(self.preview_responses()))
        service.connect()
        response = service.preview(self.document)
        rendered = json.dumps(response, ensure_ascii=False) + repr(service)
        rendered += repr(service._preview)
        try:
            ui.adapt_batch_text("bad")
        except ui.LocalUiError as rejected:
            rendered += "".join(traceback.format_exception_only(type(rejected), rejected))
        self.assertNotIn(FAKE_TOKEN, rendered)

    def test_preview_refuses_to_echo_credential_material_in_owner_or_server_text(self):
        documents_and_responses = (
            (
                f"word\nn. {FAKE_TOKEN}",
                [voc(VOC_A, "word"), collection([])],
            ),
            (
                "word\nn. 新释义",
                [
                    voc(VOC_A, "word"),
                    collection([record(RECORD_A, FAKE_TOKEN, tags=["考研"])]),
                ],
            ),
        )
        for document, responses in documents_and_responses:
            with self.subTest(document=document[:8]):
                service = controller(TransportFactory(responses))
                service.connect()
                with self.assertRaises(ui.LocalUiError) as context:
                    service.preview(document)
                rendered = str(context.exception) + repr(context.exception)
                self.assertNotIn(FAKE_TOKEN, rendered)


class ExecutionTests(unittest.TestCase):
    create_document = "newword\nn. 新建释义"
    update_document = "oldword\nn. 新版释义"

    def test_create_fresh_preflights_then_reuses_one_post_and_readback(self):
        preview = [voc(VOC_A, "newword"), collection([])]
        execute = [
            voc(VOC_A, "newword"), collection([]),
            harness.HttpResponse(201, {}), collection([record(RECORD_A, "n. 新建释义")]),
        ]
        factory = TransportFactory(preview, execute)
        service = controller(factory)
        service.connect()
        shown = service.preview(self.create_document)
        response = service.execute(
            importer.MODE_CREATE, self.create_document, shown["preview_nonce"]
        )
        self.assertEqual(len(factory.transports), 2)
        self.assertEqual(factory.transports[1].calls(), [
            ("GET", "/open/api/v1/vocabulary?spelling=newword"),
            ("GET", f"/open/api/v1/interpretations?voc_id={VOC_A}"),
            ("POST", "/open/api/v1/interpretations"),
            ("GET", f"/open/api/v1/interpretations?voc_id={VOC_A}"),
        ])
        self.assertEqual(factory.transports[1].methods().count("POST"), 1)
        self.assertEqual(response["summary"]["created"], 1)

    def test_update_fresh_preflights_and_posts_only_to_the_selected_record(self):
        existing = record(RECORD_A, "n. 旧版", tags=["考研"])
        preview = [voc(VOC_A, "oldword"), collection([existing])]
        execute = [
            voc(VOC_A, "oldword"), collection([existing]),
            harness.HttpResponse(200, {}), collection([record(RECORD_A, "n. 新版释义")]),
        ]
        factory = TransportFactory(preview, execute)
        service = controller(factory)
        service.connect()
        shown = service.preview(self.update_document)
        response = service.execute(
            importer.MODE_UPDATE, self.update_document, shown["preview_nonce"]
        )
        self.assertEqual(factory.transports[1].calls()[2:], [
            ("POST", f"/open/api/v1/interpretations/{RECORD_A}"),
            ("GET", f"/open/api/v1/interpretations?voc_id={VOC_A}"),
        ])
        payload = next(value for value in factory.transports[1].payloads if value)
        self.assertEqual(set(payload["interpretation"]), set(importer.UPDATE_BODY_FIELDS))
        self.assertNotIn("voc_id", payload["interpretation"])
        self.assertEqual(response["summary"]["updated"], 1)

    def test_changed_preflight_invalidates_preview_and_sends_zero_post(self):
        preview = [voc(VOC_A, "newword"), collection([])]
        changed = [
            voc(VOC_A, "newword"),
            collection([record(RECORD_A, "n. 现在已存在", tags=["考研"])]),
        ]
        factory = TransportFactory(preview, changed)
        service = controller(factory)
        service.connect()
        shown = service.preview(self.create_document)
        with self.assertRaises(ui.LocalUiError) as context:
            service.execute(
                importer.MODE_CREATE, self.create_document, shown["preview_nonce"]
            )
        self.assertEqual(context.exception.code, "preview-stale")
        self.assertNotIn("POST", factory.transports[1].methods())
        self.assertIsNone(service._preview)

    def test_changed_input_or_nonce_fails_before_a_fresh_transport_exists(self):
        for bad_document, bad_nonce in (
            ("newword\nn. 改过的释义", None),
            (self.create_document, "wrong-preview-nonce"),
        ):
            with self.subTest(document=bad_document[-8:]):
                factory = TransportFactory([voc(VOC_A, "newword"), collection([])])
                service = controller(factory)
                service.connect()
                shown = service.preview(self.create_document)
                with self.assertRaises(ui.LocalUiError):
                    service.execute(
                        importer.MODE_CREATE,
                        bad_document,
                        bad_nonce or shown["preview_nonce"],
                    )
                self.assertEqual(len(factory.transports), 1)

    def test_exact_existing_confirmation_binding_is_still_validated(self):
        preview = [voc(VOC_A, "newword"), collection([])]
        execute = [
            voc(VOC_A, "newword"), collection([]),
            harness.HttpResponse(201, {}), collection([record(RECORD_A, "n. 新建释义")]),
        ]
        factory = TransportFactory(preview, execute)
        service = controller(factory)
        service.connect()
        shown = service.preview(self.create_document)
        original = importer.BatchPlan.validate_confirmation
        with mock.patch.object(
            importer.BatchPlan,
            "validate_confirmation",
            autospec=True,
            side_effect=lambda plan, provided: original(plan, provided),
        ) as validation:
            service.execute(
                importer.MODE_CREATE, self.create_document, shown["preview_nonce"]
            )
        validation.assert_called_once()
        plan, provided = validation.call_args.args
        self.assertEqual(provided, plan.expected_confirmation)

    def test_tampered_preview_binding_is_rejected_before_post(self):
        preview = [voc(VOC_A, "newword"), collection([])]
        fresh = [voc(VOC_A, "newword"), collection([])]
        factory = TransportFactory(preview, fresh)
        service = controller(factory)
        service.connect()
        shown = service.preview(self.create_document)
        service._preview.create_signature = "0" * 64
        with self.assertRaises(ui.LocalUiError) as context:
            service.execute(
                importer.MODE_CREATE, self.create_document, shown["preview_nonce"]
            )
        self.assertEqual(context.exception.code, "preview-stale")
        self.assertNotIn("POST", factory.transports[1].methods())

    def test_runtime_failure_returns_a_clean_summary_and_stops(self):
        preview = [voc(VOC_A, "newword"), collection([])]
        execute = [
            voc(VOC_A, "newword"), collection([]),
            harness.HttpResponse(201, {}), collection([]),
        ]
        factory = TransportFactory(preview, execute)
        service = controller(factory)
        service.connect()
        shown = service.preview(self.create_document)
        response = service.execute(
            importer.MODE_CREATE, self.create_document, shown["preview_nonce"]
        )
        self.assertTrue(response["result"]["stopped"])
        self.assertEqual(response["summary"], {
            "created": 0, "updated": 0, "matching": 0, "failed": 1,
        })
        self.assertEqual(response["actions"], {"create": False, "update": False})
        self.assertEqual(factory.transports[1].methods().count("POST"), 1)
        self.assertIsNone(service._preview)

    def test_delete_phrase_and_unknown_operations_cannot_be_dispatched(self):
        source = Path(ui.__file__).read_text(encoding="utf-8")
        self.assertNotIn("/open/api/v1/phrases", source)
        factory = TransportFactory()
        service = controller(factory)
        service.connect()
        for mode in ("delete", "phrase", "mixed"):
            with self.subTest(mode=mode):
                with self.assertRaises(ui.LocalUiError):
                    service.execute(mode, self.create_document, "nonce")
        self.assertEqual(factory.transports, [])


class NativePromptAndFrontendTests(unittest.TestCase):
    def test_native_hidden_prompt_argv_contains_no_token(self):
        captured = {}

        def runner(argv, **kwargs):
            captured["argv"] = list(argv)
            captured["kwargs"] = kwargs
            return subprocess.CompletedProcess(argv, 0, FAKE_TOKEN + "\n", "")

        result = ui.prompt_main_account_credential(runner)
        self.assertIsInstance(result, importer.MainAccountCredential)
        rendered = json.dumps(captured["argv"], ensure_ascii=False)
        self.assertNotIn(FAKE_TOKEN, rendered)
        self.assertEqual(tuple(captured["argv"]), ui.NATIVE_TOKEN_ARGV)
        self.assertTrue(captured["kwargs"]["capture_output"])

    def test_cancelled_prompt_has_a_fixed_token_free_exception(self):
        def runner(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 1, FAKE_TOKEN, FAKE_TOKEN)

        with self.assertRaises(ui.LocalUiError) as context:
            ui.prompt_main_account_credential(runner)
        rendered = str(context.exception) + repr(context.exception)
        self.assertNotIn(FAKE_TOKEN, rendered)

    def test_frontend_has_no_external_resource_or_persistence_api(self):
        html = (ui.STATIC_ROOT / "index.html").read_text(encoding="utf-8")
        js = (ui.STATIC_ROOT / "app.js").read_text(encoding="utf-8")
        combined = html + js
        for forbidden in (
            "http://", "https://", "//cdn", "localStorage", "sessionStorage",
            "indexedDB", "document.cookie", "navigator.clipboard",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, combined)
        self.assertIn('src="/app.js"', html)
        self.assertIn('href="/styles.css"', html)
        self.assertNotIn(FAKE_TOKEN, combined)

    def test_refresh_keeps_the_same_fragment_capability_and_recovers_status(self):
        js = (ui.STATIC_ROOT / "app.js").read_text(encoding="utf-8")
        self.assertIn("window.location.hash.slice(1)", js)
        self.assertNotIn("replaceState", js)
        self.assertIn('api("/api/heartbeat", {})', js)
        self.assertIn("window.setInterval(heartbeat, HEARTBEAT_MS)", js)
        self.assertIn('document.visibilityState !== "visible"', js)
        self.assertIn('document.addEventListener("visibilitychange"', js)

        opened = []
        fake_server = type("FakeServer", (), {
            "expected_origin": "http://127.0.0.1:43123",
            "session_secret": "s" * 32,
            "serve_forever": lambda self, poll_interval: None,
            "server_close": lambda self: None,
        })()
        with mock.patch.object(ui, "build_server", return_value=fake_server):
            ui.run_local_ui(open_browser=opened.append)
        self.assertEqual(opened, [f"http://127.0.0.1:43123/#{'s' * 32}"])

    def test_reconnect_cancel_sets_the_browser_disconnected_before_prompt(self):
        js = (ui.STATIC_ROOT / "app.js").read_text(encoding="utf-8")
        start = js.index('connectButton.addEventListener("click"')
        end = js.index('previewButton.addEventListener("click"')
        reconnect = js[start:end]
        self.assertLess(reconnect.index("setConnected(false)"), reconnect.index('/api/connect'))
        self.assertIn("catch (error) {\n    setConnected(false);", reconnect)

    def test_launcher_is_transparent_background_only_and_has_a_clear_failure_dialog(self):
        source = "\n".join(
            launcher.launcher_source(Path(sys.executable), ui.Path(ui.__file__))
        )
        self.assertIn("nohup", source)
        self.assertIn(">/dev/null 2>&1 &", source)
        self.assertIn("display dialog", source)
        self.assertIn("Python 3", source)
        self.assertNotIn("Terminal", source)
        self.assertNotIn(FAKE_TOKEN, source)


class ServerSecurityTests(unittest.TestCase):
    def test_build_server_requests_loopback_and_an_ephemeral_port(self):
        captured = {}

        class CaptureServer:
            def __init__(self, address, handler, **kwargs):
                captured.update(address=address, handler=handler, kwargs=kwargs)

        service = controller(TransportFactory())
        server = ui.build_server(
            service, session_secret="s" * 32, server_class=CaptureServer
        )
        self.assertIsInstance(server, CaptureServer)
        self.assertEqual(captured["address"], ("127.0.0.1", 0))
        self.assertEqual(captured["kwargs"]["session_secret"], "s" * 32)
        with self.assertRaises(ui.LocalUiError):
            ui.build_server(service, session_secret="too-short", server_class=CaptureServer)

    def make_handler(self, *, origin, supplied_secret, path="/api/connect", body=b"{}"):
        service = controller(TransportFactory(), prompt=credential)
        server = type("FakeServer", (), {
            "expected_origin": "http://127.0.0.1:43123",
            "session_secret": "x" * 32,
            "controller": service,
            "shutdown": lambda self: None,
        })()
        handler = ui.LocalUiRequestHandler.__new__(ui.LocalUiRequestHandler)
        handler.server = server
        handler.path = path
        handler.rfile = io.BytesIO(body)
        handler.wfile = io.BytesIO()
        headers = Message()
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body))
        if origin is not None:
            headers["Origin"] = origin
        if supplied_secret is not None:
            headers[ui.SESSION_HEADER] = supplied_secret
        handler.headers = headers
        recorded = {"status": None, "headers": []}
        handler.send_response = lambda status: recorded.update(status=status)
        handler.send_header = lambda name, value: recorded["headers"].append((name, value))
        handler.end_headers = lambda: None
        return handler, recorded

    def test_wrong_or_missing_origin_and_session_secret_are_rejected(self):
        cases = (
            (None, "x" * 32),
            ("http://evil.invalid", "x" * 32),
            ("http://127.0.0.1:43123", None),
            ("http://127.0.0.1:43123", "wrong"),
        )
        for origin, secret in cases:
            with self.subTest(origin=origin, secret=secret):
                handler, recorded = self.make_handler(
                    origin=origin, supplied_secret=secret
                )
                handler.do_POST()
                self.assertEqual(recorded["status"], 403)
                self.assertNotIn(FAKE_TOKEN, handler.wfile.getvalue().decode("utf-8"))

    def test_exact_origin_and_secret_work_and_no_wildcard_cors_is_sent(self):
        handler, recorded = self.make_handler(
            origin="http://127.0.0.1:43123", supplied_secret="x" * 32
        )
        handler.do_POST()
        self.assertEqual(recorded["status"], 200)
        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response, {"connected": True})
        header_map = dict(recorded["headers"])
        self.assertEqual(header_map["Cache-Control"], "no-store, max-age=0")
        self.assertEqual(header_map["Content-Security-Policy"], ui.CSP)
        self.assertNotIn("Access-Control-Allow-Origin", header_map)
        self.assertNotIn("*", header_map.values())
        self.assertNotIn(FAKE_TOKEN, handler.wfile.getvalue().decode("utf-8"))

    def test_public_page_does_not_reveal_the_session_secret(self):
        handler, recorded = self.make_handler(
            origin=None, supplied_secret=None, path="/"
        )
        handler.do_GET()
        self.assertEqual(recorded["status"], 200)
        rendered = handler.wfile.getvalue().decode("utf-8")
        self.assertNotIn("x" * 32, rendered)
        self.assertNotIn("__SESSION_SECRET__", rendered)

    def test_default_http_logging_is_fully_suppressed(self):
        handler = ui.LocalUiRequestHandler.__new__(ui.LocalUiRequestHandler)
        stream = io.StringIO()
        with mock.patch("sys.stderr", stream):
            handler.log_message("%s %s", FAKE_TOKEN, "private body")
        self.assertEqual(stream.getvalue(), "")

    def test_explicit_quit_immediately_clears_the_credential(self):
        handler, recorded = self.make_handler(
            origin="http://127.0.0.1:43123",
            supplied_secret="x" * 32,
            path="/api/quit",
        )
        handler.server.controller.connect()
        self.assertTrue(handler.server.controller.heartbeat()["connected"])
        handler.do_POST()
        self.assertEqual(recorded["status"], 200)
        self.assertFalse(handler.server.controller.heartbeat()["connected"])


class LifecycleTests(unittest.TestCase):
    def test_abandoned_session_expires_credential_and_preview_without_sleeping(self):
        clock = FakeClock()
        factory = TransportFactory([voc(VOC_A, "word"), collection([])])
        service = controller(factory, clock=clock, idle_timeout=60)
        service.connect()
        shown = service.preview("word\nn. 释义")
        self.assertTrue(shown["actions"]["create"])

        clock.advance(59)
        self.assertFalse(service.expire_if_idle())
        self.assertTrue(service.heartbeat()["connected"])
        # The heartbeat reset activity, so another 59 seconds remains active.
        clock.advance(59)
        self.assertFalse(service.expire_if_idle())
        self.assertIsNotNone(service._credential)

        clock.advance(1)
        self.assertTrue(service.expire_if_idle())
        self.assertIsNone(service._credential)
        self.assertIsNone(service._preview)
        with self.assertRaises(ui.LocalUiError) as context:
            service.execute(importer.MODE_CREATE, "word\nn. 释义", shown["preview_nonce"])
        self.assertEqual(context.exception.code, "not-connected")
        self.assertEqual(len(factory.transports), 1)

    def test_server_polling_enforces_the_bounded_idle_expiry(self):
        clock = FakeClock()
        service = controller(TransportFactory(), clock=clock, idle_timeout=10)
        service.connect()
        server = ui.LocalUiHttpServer.__new__(ui.LocalUiHttpServer)
        server.controller = service
        clock.advance(10)
        server.service_actions()
        self.assertIsNone(service._credential)

    def test_reconnect_cancellation_clears_the_previous_backend_credential(self):
        calls = 0

        def prompt():
            nonlocal calls
            calls += 1
            if calls == 1:
                return credential()
            raise ui.LocalUiError("token-cancelled")

        service = controller(TransportFactory(), prompt=prompt)
        service.connect()
        self.assertTrue(service.heartbeat()["connected"])
        with self.assertRaises(ui.LocalUiError):
            service.connect()
        self.assertFalse(service.heartbeat()["connected"])
        self.assertIsNone(service._preview)


class NoNetworkGuardTests(unittest.TestCase):
    def test_process_level_no_network_guard_still_blocks_all_three_primitives(self):
        self.assertEqual(os.environ.get("MOMO_TEST_NETWORK_DISABLED"), "1")
        for call in (
            lambda: socket.socket(),
            lambda: socket.create_connection(("open.maimemo.com", 443)),
            lambda: urllib.request.urlopen("https://open.maimemo.com/"),
        ):
            with self.subTest(call=call):
                with self.assertRaises(RuntimeError):
                    call()


if __name__ == "__main__":
    unittest.main()
