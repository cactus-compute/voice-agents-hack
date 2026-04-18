"""
Layer 3 — Task State
Plain data object tracking where we are in executing a plan.
No LLM context — just state.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class TaskStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    AWAITING_CONFIRMATION = "awaiting_confirmation"
    COMPLETED = "completed"
    FAILED = "failed"
    ABORTED = "aborted"


@dataclass
class TaskState:
    goal: str
    plan_name: str
    steps: list[dict]               # list of step defs from plans.py
    step_index: int = 0
    status: TaskStatus = TaskStatus.PENDING
    collected_data: dict[str, Any] = field(default_factory=dict)
    error: str | None = None
    confirmation_message: str | None = None

    @property
    def current_step(self) -> dict | None:
        if self.step_index < len(self.steps):
            return self.steps[self.step_index]
        return None

    def advance(self):
        self.step_index += 1

    def fail(self, reason: str):
        self.status = TaskStatus.FAILED
        self.error = reason

    def __str__(self):
        total = len(self.steps)
        step = self.current_step
        step_name = step["name"] if step else "done"
        return f"[{self.status}] {self.goal} — step {self.step_index + 1}/{total}: {step_name}"
