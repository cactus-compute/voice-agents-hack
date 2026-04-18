import unittest

from intent.parser import _rule_based_parse
from intent.schema import KnownGoal
from orchestrator.orchestrator import _resolve_params
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
            action_type="click_text",
            reason="submit",
            expected_outcome="submitted",
            safety_level="irreversible",
            confirm_required=False,
            params={},
        )
        with self.assertRaises(ValueError):
            action.validate()

    def test_visual_fallback_apply_first_step_navigates(self):
        intent = _rule_based_parse("apply to YC with my resume")
        action = _fallback_action(
            intent=intent,
            observation={"scope": "browser", "url": "https://example.com"},
            collected_data={"slots": intent.slots},
            step_index=0,
        )
        self.assertEqual(action.action_type, "navigate")
        self.assertEqual(action.params.get("url"), "https://apply.ycombinator.com")


if __name__ == "__main__":
    unittest.main()
