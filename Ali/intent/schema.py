"""
Layer 2 — Intent Schema
Defines the structured output the on-device model produces.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class KnownGoal(str, Enum):
    APPLY_TO_JOB = "apply_to_job"
    SEND_MESSAGE = "send_message"
    SEND_EMAIL = "send_email"
    ADD_CALENDAR_EVENT = "add_calendar_event"
    OPEN_URL = "open_url"
    FIND_FILE = "find_file"
    CAPTURE_MEETING = "capture_meeting"
    UNKNOWN = "unknown"


@dataclass
class IntentObject:
    goal: KnownGoal
    target: dict[str, Any]           # e.g. {"type": "url", "value": "apply.ycombinator.com"}
    uses_local_data: list[str]        # e.g. ["resume", "linkedin_url"]
    requires_browser: bool
    requires_submission: bool
    slots: dict[str, Any] = field(default_factory=dict)  # goal-specific extracted values
    raw_transcript: str = ""

    @classmethod
    def unknown(cls, transcript: str) -> "IntentObject":
        return cls(
            goal=KnownGoal.UNKNOWN,
            target={},
            uses_local_data=[],
            requires_browser=False,
            requires_submission=False,
            raw_transcript=transcript,
        )
