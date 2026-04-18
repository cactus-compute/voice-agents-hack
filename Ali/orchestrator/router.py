"""Simple intent-to-plan router."""

from intent.schema import IntentObject
from orchestrator.plans import get_plan, get_vision_hints


def route_intent(intent: IntentObject) -> list[dict] | None:
    """Return the hardcoded plan steps for a known intent."""
    return get_plan(intent.goal)


def route_intent_vision(intent: IntentObject) -> dict:
    """Return high-level hints for vision-first orchestration."""
    return {
        "goal": intent.goal.value,
        "requires_browser": intent.requires_browser,
        "hints": get_vision_hints(intent.goal),
    }
