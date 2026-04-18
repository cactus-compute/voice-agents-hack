"""Smoke + integration tests for the masker package.

Run: `cd platform/masker-library && python -m unittest discover -s tests -v`
"""

from __future__ import annotations

import io
import json
import unittest
from unittest import mock

from masker import (
    CactusCloudBackend,
    DetectionResult,
    Entity,
    EntityType,
    MaskedText,
    PolicyDecision,
    StubBackend,
    TraceEvent,
    Tracer,
    VoiceLoop,
    filter_input,
    filter_output,
)
from masker.detection import detect
from masker.gemma_wrapper import _extract_assistant_reply, default_backend
from masker.masking import mask, scrub_output
from masker.policy import decide
from masker.router import Router


class DetectionTests(unittest.TestCase):
    def test_ssn_is_detected_as_high_risk(self):
        det = detect("My SSN is 123-45-6789.")
        self.assertEqual(det.risk_level, "high")
        types = {e.type.value for e in det.entities}
        self.assertIn("ssn", types)

    def test_safe_query_has_no_entities(self):
        det = detect("What's the weather tomorrow?")
        self.assertEqual(det.risk_level, "none")
        self.assertEqual(det.entities, [])

    def test_email_and_phone_are_detected(self):
        det = detect("Email me at jane@example.com or 415-555-0123.")
        types = {e.type.value for e in det.entities}
        self.assertIn("email", types)
        self.assertIn("phone", types)


class PolicyTests(unittest.TestCase):
    def test_safe_query_is_safe_to_send(self):
        det = detect("What time is it in Tokyo?")
        self.assertEqual(decide(det).route, "safe-to-send")

    def test_ssn_is_local_only(self):
        det = detect("SSN 111-22-3333.")
        self.assertEqual(decide(det).route, "local-only")

    def test_email_is_masked_send(self):
        det = detect("Ping priya@redwood.com.")
        self.assertEqual(decide(det).route, "masked-send")


class MaskingTests(unittest.TestCase):
    def test_mask_replaces_spans_with_placeholders(self):
        text = "Email me at jane@example.com."
        det = detect(text)
        m = mask(text, det)
        self.assertNotIn("jane@example.com", m.text)
        self.assertIn("[MASKED:email]", m.text)

    def test_scrub_output_re_masks_leaked_values(self):
        text = "Call 415-555-0123."
        det = detect(text)
        leaked = "Sure, calling 415-555-0123 now."
        scrubbed = scrub_output(leaked, det)
        self.assertNotIn("415-555-0123", scrubbed)


class PublicApiTests(unittest.TestCase):
    def test_filter_input_returns_safe_text_and_metadata(self):
        safe, meta = filter_input("My SSN is 123-45-6789.")
        self.assertNotIn("123-45-6789", safe)
        self.assertEqual(meta["route"], "local-only")
        self.assertEqual(meta["risk_level"], "high")

    def test_filter_output_scrubs_leaked_email(self):
        out = filter_output("Reach me at jane@example.com")
        self.assertNotIn("jane@example.com", out)

    def test_filter_input_prefers_native_bridge_when_available(self):
        native = mock.Mock(
            masked_input=MaskedText(
                text="My SSN is [MASKED:ssn].",
                token_map={"[MASKED:ssn]": "123-45-6789"},
            ),
            policy=PolicyDecision(
                route="local-only",
                policy="hipaa_base",
                rationale="High-risk identifiers detected: ['ssn']",
            ),
            detection=DetectionResult(
                entities=[
                    Entity(
                        type=EntityType.SSN,
                        value="123-45-6789",
                        start=10,
                        end=21,
                    )
                ],
                risk_level="high",
            ),
        )

        with mock.patch("masker._native.try_filter_input", return_value=native):
            safe, meta = filter_input("My SSN is 123-45-6789.")

        self.assertEqual(safe, "My SSN is [MASKED:ssn].")
        self.assertEqual(meta["route"], "local-only")
        self.assertEqual(meta["entities"][0]["type"], "ssn")

    def test_filter_output_prefers_native_bridge_when_available(self):
        native = mock.Mock(safe_text="Reach me at [MASKED:email]")

        with mock.patch("masker._native.try_filter_output", return_value=native):
            out = filter_output("Reach me at jane@example.com")

        self.assertEqual(out, "Reach me at [MASKED:email]")


class CactusOutputParserTests(unittest.TestCase):
    """The cactus chat binary mixes banner, prompt echo, reply, and metrics
    into a single stdout. These tests pin the parser against real samples.
    """

    SAMPLE = """\
Loading model from /weights/functiongemma-270m-it...
Model loaded successfully!
============================================================
           🌵 CACTUS CHAT INTERFACE 🌵
============================================================
You: Reply with the single word: hello
Assistant: I am sorry, I am unable to assist with this request.
My capabilities are limited.
[40 tokens | latency: 0.029s | total: 0.437s | 91 tok/s | RAM: 125.1 MB]
------------------------------------------------------------
You:
👋 Goodbye!
"""

    def test_extracts_multiline_reply_and_drops_metrics(self):
        reply = _extract_assistant_reply(self.SAMPLE)
        self.assertIn("I am sorry", reply)
        self.assertIn("My capabilities are limited.", reply)
        self.assertNotIn("tokens", reply)
        self.assertNotIn("Goodbye", reply)
        self.assertNotIn("CACTUS", reply)

    def test_falls_back_when_marker_missing(self):
        reply = _extract_assistant_reply("hello world\n[done]")
        self.assertIn("hello world", reply)


class CactusCloudBackendTests(unittest.TestCase):
    """Mock the HTTP layer so the suite still runs offline / on CI."""

    def _fake_response(self, body: dict) -> mock.MagicMock:
        ctx = mock.MagicMock()
        resp = mock.MagicMock()
        resp.read.return_value = json.dumps(body).encode("utf-8")
        ctx.__enter__.return_value = resp
        ctx.__exit__.return_value = False
        return ctx

    def test_missing_key_raises(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            backend = CactusCloudBackend()
            with self.assertRaisesRegex(RuntimeError, "CACTUS_CLOUD_KEY"):
                backend.generate("hi")

    def test_posts_text_payload_and_returns_text_field(self):
        captured: dict = {}

        def fake_urlopen(req, timeout, context):  # noqa: ARG001
            captured["url"] = req.full_url
            captured["headers"] = {k.lower(): v for k, v in req.header_items()}
            captured["body"] = json.loads(req.data.decode("utf-8"))
            return self._fake_response({"text": "PONG", "model": "gemini-2.5-flash"})

        with mock.patch.dict("os.environ", {"CACTUS_CLOUD_KEY": "k_test"}, clear=True):
            with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
                reply = CactusCloudBackend().generate("ping")

        self.assertEqual(reply, "PONG")
        self.assertEqual(captured["body"], {"text": "ping", "model": "gemini-2.5-flash"})
        self.assertEqual(captured["headers"]["x-api-key"], "k_test")
        self.assertIn("/api/v1/text", captured["url"])

    def test_http_error_is_returned_as_masker_message(self):
        import urllib.error

        def fake_urlopen(req, timeout, context):  # noqa: ARG001
            raise urllib.error.HTTPError(
                req.full_url, 401, "Unauthorized", hdrs=None,
                fp=io.BytesIO(b'{"error":"bad key"}'),
            )

        with mock.patch.dict("os.environ", {"CACTUS_CLOUD_KEY": "k_test"}, clear=True):
            with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
                reply = CactusCloudBackend().generate("ping")

        self.assertIn("cactus-cloud HTTP 401", reply)
        self.assertIn("bad key", reply)

    def test_default_backend_picks_cactus_cloud_when_key_set(self):
        with mock.patch("masker.gemma_wrapper.shutil.which", return_value=None):
            with mock.patch.dict(
                "os.environ", {"CACTUS_CLOUD_KEY": "k_test"}, clear=True
            ):
                self.assertEqual(default_backend().name, "cactus-cloud")


class VoiceLoopTests(unittest.TestCase):
    def test_end_to_end_with_stub_backend(self):
        loop = VoiceLoop(router=Router(local_backend=StubBackend()))
        result = loop.run_text_turn("What's the weather tomorrow?", tracer=Tracer())
        self.assertEqual(result.policy.route, "safe-to-send")
        self.assertGreater(len(result.trace), 0)
        stages = {ev.stage for ev in result.trace}
        self.assertIn("detection", stages)
        self.assertIn("policy", stages)
        self.assertIn("llm", stages)

    def test_high_risk_turn_stays_local(self):
        loop = VoiceLoop(router=Router(local_backend=StubBackend()))
        result = loop.run_text_turn(
            "I have chest pain and my MRN is 99812 and SSN 123-45-6789.",
            tracer=Tracer(),
        )
        self.assertEqual(result.policy.route, "local-only")

    def test_voice_loop_uses_native_core_when_available(self):
        native_input = mock.Mock(
            detection=DetectionResult(
                entities=[
                    Entity(
                        type=EntityType.SSN,
                        value="123-45-6789",
                        start=13,
                        end=24,
                    )
                ],
                risk_level="high",
            ),
            policy=PolicyDecision(
                route="local-only",
                policy="hipaa_base",
                rationale="High-risk identifiers detected: ['ssn']",
            ),
            masked_input=MaskedText(
                text="My SSN is [MASKED:ssn].",
                token_map={"[MASKED:ssn]": "123-45-6789"},
            ),
            trace=[
                TraceEvent(
                    stage="detection",
                    message="Scanning input for PII/PHI",
                    elapsed_ms=0.2,
                    payload={"risk": "high"},
                ),
                TraceEvent(
                    stage="policy",
                    message="route=local-only",
                    elapsed_ms=0.0,
                    payload={"route": "local-only"},
                ),
                TraceEvent(
                    stage="masking",
                    message="Masking sensitive spans",
                    elapsed_ms=0.1,
                    payload={},
                ),
            ],
        )
        native_output = mock.Mock(
            safe_text="[MASKED:ssn]",
            trace=[
                TraceEvent(
                    stage="output_filter",
                    message="Re-scanning model output for leakage",
                    elapsed_ms=0.1,
                    payload={},
                )
            ],
        )

        with mock.patch("masker._native.try_filter_input", return_value=native_input):
            with mock.patch("masker._native.try_filter_output", return_value=native_output):
                loop = VoiceLoop(router=Router(local_backend=StubBackend()))
                result = loop.run_text_turn("My SSN is 123-45-6789.", tracer=Tracer())

        self.assertEqual(result.policy.route, "local-only")
        self.assertEqual(result.masked_input.text, "My SSN is [MASKED:ssn].")
        self.assertEqual(result.safe_output, "[MASKED:ssn]")
        stages = {event.stage for event in result.trace}
        self.assertIn("detection", stages)
        self.assertIn("policy", stages)
        self.assertIn("masking", stages)
        self.assertIn("output_filter", stages)


if __name__ == "__main__":
    unittest.main()
