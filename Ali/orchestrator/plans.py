"""
Layer 3 — Hardcoded Plans
Each plan is a named sequence of steps for a known intent goal.
The LLM fills in slot values; these recipes decide the structure.

Step fields:
  name        — human-readable label shown in UI
  executor    — "local" | "browser"
  action      — function name in the executor
  params      — static or slot-referenced params (use "$slot_name" for dynamic values)
  confirm     — True if this step requires user confirmation before executing
  on_failure  — "retry" | "ask_user" | "abort"
"""

from intent.schema import KnownGoal

PLANS: dict[str, list[dict]] = {
    KnownGoal.APPLY_TO_JOB: [
        {
            "name": "Find resume on disk",
            "executor": "local",
            "action": "find_file",
            "params": {"alias": "resume"},
            "confirm": False,
            "on_failure": "ask_user",
        },
        {
            "name": "Open YC Apply in browser",
            "executor": "browser",
            "action": "navigate",
            "params": {"url": "https://apply.ycombinator.com"},
            "confirm": False,
            "on_failure": "retry",
        },
        {
            "name": "Fill application form",
            "executor": "browser",
            "action": "yc_apply_fill",
            "params": {"resume_path": "$resume_path", "slots": "$slots"},
            "confirm": False,
            "on_failure": "ask_user",
        },
        {
            "name": "Submit application",
            "executor": "browser",
            "action": "yc_apply_submit",
            "params": {},
            "confirm": True,  # always gate submission
            "on_failure": "ask_user",
        },
    ],

    KnownGoal.SEND_MESSAGE: [
        {
            "name": "Resolve contact",
            "executor": "local",
            "action": "resolve_contact",
            "params": {"name": "$contact"},
            "confirm": False,
            "on_failure": "ask_user",
        },
        {
            "name": "Send iMessage",
            "executor": "local",
            "action": "send_imessage",
            "params": {"contact": "$contact", "body": "$body"},
            "confirm": True,
            "on_failure": "ask_user",
        },
    ],

    KnownGoal.SEND_EMAIL: [
        {
            "name": "Compose email",
            "executor": "local",
            "action": "compose_mail",
            "params": {"to": "$to", "subject": "$subject", "body": "$body"},
            "confirm": True,
            "on_failure": "ask_user",
        },
    ],

    KnownGoal.ADD_CALENDAR_EVENT: [
        {
            "name": "Create calendar event",
            "executor": "local",
            "action": "create_calendar_event",
            "params": {"title": "$title", "date": "$date", "time": "$time", "attendees": "$attendees"},
            "confirm": True,
            "on_failure": "ask_user",
        },
    ],
}


def get_plan(goal: KnownGoal) -> list[dict] | None:
    return PLANS.get(goal)


VISION_GOAL_HINTS: dict[str, dict] = {
    KnownGoal.APPLY_TO_JOB: {
        "target_url": "https://apply.ycombinator.com",
        "irreversible_action": "yc_apply_submit",
    },
    KnownGoal.SEND_MESSAGE: {
        "target_app": "Messages",
        "irreversible_action": "send_imessage",
    },
    KnownGoal.SEND_EMAIL: {
        "target_app": "Mail",
        "irreversible_action": "compose_mail_send",
    },
    KnownGoal.ADD_CALENDAR_EVENT: {
        "target_app": "Calendar",
        "irreversible_action": "create_calendar_event",
    },
}


def get_vision_hints(goal: KnownGoal) -> dict:
    return VISION_GOAL_HINTS.get(goal, {})
