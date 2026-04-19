import asyncio
import json
import unittest
from unittest.mock import patch

from intent import parser as intent_parser
from intent.parser import _parse_json_response, _rule_based_parse, parse_intent
from intent.schema import IntentObject, KnownGoal
from orchestrator.orchestrator import _path_for_file_action, _resolve_params
from orchestrator.plans import get_plan
from orchestrator.visual_planner import NextAction, _fallback_action


class ParserRuleTests(unittest.TestCase):
    def test_apply_intent_detected(self):
        intent = _rule_based_parse("apply to YC with my resume")
        self.assertEqual(intent.goal, KnownGoal.APPLY_TO_JOB)

    def test_message_intent_extracts_slots(self):
        intent = _rule_based_parse("text Hanzi I'll be ten minutes late")
        self.assertEqual(intent.goal, KnownGoal.SEND_MESSAGE)
        self.assertIn("contact", intent.slots)
        self.assertIn("body", intent.slots)

    def test_calendar_intent_detected(self):
        intent = _rule_based_parse("add calendar event for tomorrow at 3")
        self.assertEqual(intent.goal, KnownGoal.ADD_CALENDAR_EVENT)


class ParseIntentPriorityTests(unittest.TestCase):
    """
    parse_intent() is LLM-first: Gemini runs when available, Cactus is the
    offline fallback, and the keyword rules are only a last-ditch fallback.
    """

    def _run(self, coro):
        return asyncio.get_event_loop().run_until_complete(coro)

    def _gemini_payload(self, **overrides):
        base = {
            "goal": "find_file",
            "target": {"type": "file", "value": "resume"},
            "uses_local_data": [],
            "requires_browser": False,
            "requires_submission": False,
            "slots": {"file_query": "resume"},
        }
        base.update(overrides)
        return json.dumps(base)

    def test_gemini_result_wins_over_rules(self):
        """Gemini should be consulted first and its answer used, even for
        transcripts the old rule cascade would have grabbed (e.g. 'apply')."""

        async def fake_gemini(transcript):
            return _parse_json_response(
                self._gemini_payload(
                    goal="unknown",
                    target={},
                    uses_local_data=[],
                    slots={},
                ),
                transcript,
            )

        with patch.object(intent_parser, "GEMINI_AVAILABLE", True), \
             patch.object(intent_parser, "_parse_with_gemini", side_effect=fake_gemini):
            intent = self._run(parse_intent("apply the filter to these photos"))

        # Rule-based would have (incorrectly) fired APPLY_TO_JOB; Gemini says unknown.
        self.assertEqual(intent.goal, KnownGoal.UNKNOWN)

    def test_gemini_error_falls_through_to_rules_when_cactus_missing(self):
        async def bad_gemini(_):
            raise RuntimeError("network down")

        with patch.object(intent_parser, "GEMINI_AVAILABLE", True), \
             patch.object(intent_parser, "CACTUS_AVAILABLE", False), \
             patch.object(intent_parser, "_parse_with_gemini", side_effect=bad_gemini):
            intent = self._run(parse_intent("text Hanzi I'll be late"))

        # Rule fallback should still classify this correctly.
        self.assertEqual(intent.goal, KnownGoal.SEND_MESSAGE)

    def test_rule_fallback_used_when_no_backends_available(self):
        with patch.object(intent_parser, "GEMINI_AVAILABLE", False), \
             patch.object(intent_parser, "CACTUS_AVAILABLE", False):
            intent = self._run(parse_intent("find my 2024 taxes"))
        self.assertEqual(intent.goal, KnownGoal.FIND_FILE)


class ParseJsonResponseTests(unittest.TestCase):
    def test_unknown_goal_string_coerces_to_unknown_enum(self):
        raw = json.dumps({"goal": "launch_nukes", "target": {}, "slots": {}})
        intent = _parse_json_response(raw, "do the thing")
        self.assertEqual(intent.goal, KnownGoal.UNKNOWN)

    def test_code_fences_are_stripped(self):
        raw = "```json\n" + json.dumps({"goal": "open_url"}) + "\n```"
        intent = _parse_json_response(raw, "open gmail")
        self.assertEqual(intent.goal, KnownGoal.OPEN_URL)

    def test_malformed_json_raises(self):
        with self.assertRaises(RuntimeError):
            _parse_json_response("not json at all", "whatever")

    def test_non_object_payload_raises(self):
        with self.assertRaises(RuntimeError):
            _parse_json_response(json.dumps(["find_file"]), "whatever")

    def test_field_defaults_applied(self):
        intent = _parse_json_response(json.dumps({"goal": "find_file"}), "find my resume")
        self.assertEqual(intent.target, {})
        self.assertEqual(intent.uses_local_data, [])
        self.assertEqual(intent.slots, {})
        self.assertFalse(intent.requires_browser)
        self.assertFalse(intent.requires_submission)


class OrchestratorContractTests(unittest.TestCase):
    def test_plans_exist_for_core_goals(self):
        goals = [
            KnownGoal.APPLY_TO_JOB,
            KnownGoal.SEND_MESSAGE,
            KnownGoal.SEND_EMAIL,
            KnownGoal.ADD_CALENDAR_EVENT,
        ]
        for goal in goals:
            steps = get_plan(goal)
            self.assertIsNotNone(steps)
            self.assertGreater(len(steps), 0)

    def test_resolve_params_substitutes_slots(self):
        params = {"contact": "$contact", "body": "$body", "constant": "ok"}
        data = {"contact": "hanzi@example.com", "body": "hello"}
        resolved = _resolve_params(params, data)
        self.assertEqual(resolved["contact"], "hanzi@example.com")
        self.assertEqual(resolved["body"], "hello")
        self.assertEqual(resolved["constant"], "ok")

    def test_visual_action_schema_requires_confirmation_for_irreversible(self):
        action = NextAction(
            action_type="browser_task",
            reason="submit",
            expected_outcome="submitted",
            safety_level="irreversible",
            confirm_required=False,
            params={"task": "submit the form"},
        )
        with self.assertRaises(ValueError):
            action.validate()

    def test_visual_fallback_apply_delegates_to_browser_task(self):
        intent = _rule_based_parse("apply to YC with my resume")
        action = _fallback_action(
            intent=intent,
            observation={"scope": "browser", "url": "https://example.com"},
            collected_data={"slots": intent.slots},
            step_index=0,
        )
        # Browser goals are handed off to the browser sub-agent in one shot
        # via action_type=browser_task. The sub-agent owns per-step navigation.
        self.assertEqual(action.action_type, "browser_task")
        self.assertIn("task", action.params)
        self.assertTrue(action.params["task"])  # non-empty task description

    def test_fallback_find_file_emits_run_script_reveal(self):
        intent = IntentObject(
            goal=KnownGoal.FIND_FILE,
            target={"type": "file", "value": "taxes"},
            uses_local_data=[],
            requires_browser=False,
            requires_submission=False,
            slots={"file_query": "taxes"},
            raw_transcript="find my taxes",
        )
        action = _fallback_action(
            intent=intent,
            observation={"scope": "desktop"},
            collected_data={"resolved_local_files": {"found": "/tmp/taxes-2024.pdf"}},
            step_index=0,
        )
        self.assertEqual(action.action_type, "run_script")
        self.assertEqual(action.params.get("name"), "reveal_in_finder")
        self.assertEqual(action.params.get("args", {}).get("path"), "/tmp/taxes-2024.pdf")
        action.validate()  # must accept run_script as safe

    def test_fallback_find_file_without_resolution_asks_user(self):
        intent = IntentObject(
            goal=KnownGoal.FIND_FILE,
            target={"type": "file", "value": "taxes"},
            uses_local_data=[],
            requires_browser=False,
            requires_submission=False,
            slots={},
            raw_transcript="find my taxes",
        )
        action = _fallback_action(
            intent=intent,
            observation={"scope": "desktop"},
            collected_data={"resolved_local_files": {}},
            step_index=0,
        )
        self.assertEqual(action.action_type, "ask_user")

    def test_fallback_find_file_completes_after_reveal(self):
        intent = IntentObject(
            goal=KnownGoal.FIND_FILE,
            target={"type": "file", "value": "taxes"},
            uses_local_data=[],
            requires_browser=False,
            requires_submission=False,
            slots={"file_query": "taxes"},
            raw_transcript="find my taxes",
        )
        action = _fallback_action(
            intent=intent,
            observation={"scope": "desktop"},
            collected_data={
                "resolved_local_files": {"found": "/tmp/taxes.pdf"},
                "script_result": {"name": "reveal_in_finder", "returncode": 0},
            },
            step_index=1,
        )
        self.assertEqual(action.action_type, "complete")

    def test_fallback_find_file_aborts_after_first_fruitless_step(self):
        intent = IntentObject(
            goal=KnownGoal.FIND_FILE,
            target={"type": "file", "value": "taxes"},
            uses_local_data=[],
            requires_browser=False,
            requires_submission=False,
            slots={"file_query": "taxes"},
            raw_transcript="find my taxes",
        )
        action = _fallback_action(
            intent=intent,
            observation={"scope": "desktop"},
            collected_data={"resolved_local_files": {}, "slots": intent.slots},
            step_index=1,
        )
        self.assertEqual(action.action_type, "abort")

    def test_action_schema_accepts_run_and_author_script(self):
        for atype in ("run_script", "author_script"):
            action = NextAction(
                action_type=atype,
                reason="r",
                expected_outcome="o",
                safety_level="safe",
                confirm_required=False,
                params={},
            )
            action.validate()


class FileRoleRoutingTests(unittest.TestCase):
    def _stub_fs(self):
        class _StubFs:
            def find_by_alias(self, alias):
                raise FileNotFoundError(f"no alias {alias}")

        return _StubFs()

    def test_path_helper_picks_file_role_from_resolved_map(self):
        data = {
            "resolved_local_files": {"attachment": "/docs/deck.pdf", "resume": "/r.pdf"},
        }
        self.assertEqual(
            _path_for_file_action(data, {"file_role": "attachment"}, self._stub_fs()),
            "/docs/deck.pdf",
        )

    def test_path_helper_falls_back_to_resume_path_for_resume_role(self):
        data = {"resume_path": "/legacy/resume.pdf", "resolved_local_files": {}}
        self.assertEqual(
            _path_for_file_action(data, {}, self._stub_fs()),
            "/legacy/resume.pdf",
        )

    def test_path_helper_falls_through_to_alias(self):
        class _Fs:
            def find_by_alias(self, alias):
                return f"/aliases/{alias}.pdf"

        data = {"resolved_local_files": {}}
        self.assertEqual(
            _path_for_file_action(data, {"file_role": "cover_letter"}, _Fs()),
            "/aliases/cover_letter.pdf",
        )


class ParserRuleHintsTests(unittest.TestCase):
    def test_find_file_intent_detected(self):
        intent = _rule_based_parse("find my 2024 taxes pdf")
        self.assertEqual(intent.goal, KnownGoal.FIND_FILE)
        self.assertIn("file_query", intent.slots)
        self.assertIn("taxes", intent.slots["file_query"].lower())

    def test_email_with_attachment_hint_detected(self):
        intent = _rule_based_parse("email me the Q1 deck attachment")
        self.assertEqual(intent.goal, KnownGoal.SEND_EMAIL)
        self.assertIn("attachment", intent.uses_local_data)


if __name__ == "__main__":
    unittest.main()
