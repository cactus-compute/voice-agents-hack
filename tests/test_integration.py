"""Smoke + integration tests for the masker package.

Run: `python -m unittest discover -s tests -v`
"""

from __future__ import annotations

import unittest

from masker import (
    analyze_transcript,
    StubBackend,
    Tracer,
    VoiceLoop,
    filter_input,
    filter_output,
)
from masker.detection import detect
from masker.gemma_wrapper import _extract_assistant_reply
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
        self.assertFalse(det.health_context)

    def test_email_and_phone_are_detected(self):
        det = detect("Email me at jane@example.com or 415-555-0123.")
        types = {e.type.value for e in det.entities}
        self.assertIn("email", types)
        self.assertIn("phone", types)

    def test_healthcare_context_sets_flag_and_identifier(self):
        det = detect("My doctor said I have chest pain and my insurance ID is BCBS-778812.")
        self.assertTrue(det.health_context)
        types = {e.type.value for e in det.entities}
        self.assertIn("health_context", types)
        self.assertIn("insurance_id", types)


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

    def test_healthcare_identifier_is_local_only_for_clinical_context(self):
        det = detect("My doctor said I have chest pain and my insurance ID is BCBS-887421.")
        decision = decide(det, policy_name="hipaa_clinical_context")
        self.assertEqual(decision.route, "local-only")
        self.assertIn("clinical_context_requires_local_review", decision.reasons)


class MaskingTests(unittest.TestCase):
    def test_mask_replaces_spans_with_placeholders(self):
        text = "Email me at jane@example.com."
        det = detect(text)
        m = mask(text, det)
        self.assertNotIn("jane@example.com", m.text)
        self.assertIn("[MASKED]", m.text)
        self.assertEqual(m.token_map, {})
        self.assertEqual(m.replacements[0]["type"], "email")

    def test_scrub_output_re_masks_leaked_values(self):
        text = "Call 415-555-0123."
        det = detect(text)
        leaked = "Sure, calling 415-555-0123 now."
        scrubbed = scrub_output(leaked, det)
        self.assertNotIn("415-555-0123", scrubbed)
        self.assertIn("[MASKED]", scrubbed)


class PublicApiTests(unittest.TestCase):
    def test_filter_input_returns_safe_text_and_metadata(self):
        safe, meta = filter_input("My SSN is 123-45-6789.")
        self.assertNotIn("123-45-6789", safe)
        self.assertEqual(meta["route"], "local-only")
        self.assertEqual(meta["risk_level"], "high")
        self.assertIn("high_risk_identifier", meta["reasons"])
        self.assertIn("timings", meta)

    def test_filter_output_scrubs_leaked_email(self):
        out = filter_output("Reach me at jane@example.com")
        self.assertNotIn("jane@example.com", out)

    def test_analyze_transcript_returns_detection_decision_masked_and_timings(self):
        result = analyze_transcript(
            "My doctor said I have chest pain and my insurance ID is BCBS-887421.",
            policy_name="hipaa_clinical_context",
        )
        self.assertEqual(result.policy.route, "local-only")
        self.assertTrue(result.detection.health_context)
        self.assertIn("[MASKED]", result.masked.text)
        self.assertGreaterEqual(result.timings.to_dict()["total_ms"], 0.0)


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


if __name__ == "__main__":
    unittest.main()
