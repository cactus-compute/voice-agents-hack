"""
Vision-first planner.
Given intent + latest visual observation, decide the next atomic action.
"""

from __future__ import annotations

import asyncio
import json
import re
import shutil
from dataclasses import dataclass
from typing import Any

from config.settings import CACTUS_GEMMA4_MODEL
from intent.schema import IntentObject, KnownGoal

ALLOWED_ACTION_TYPES = {
    # Delegates a complete browser task (e.g. "go to example.com and tell me the
    # title") to the browser sub-agent. The planner should emit ONE of these
    # for any browser goal — the sub-agent handles navigation, DOM reading,
    # form filling, and multi-step flows autonomously on the user's real
    # Chrome. See executors/browser/agent_client.py.
    "browser_task",
    # Local / UI actions. Kept for non-browser goals (iMessage, Mail, Calendar).
    "ask_user",
    "complete",
    "abort",
}
CACTUS_CLI = shutil.which("cactus")


@dataclass
class NextAction:
    action_type: str
    reason: str
    expected_outcome: str
    safety_level: str
    confirm_required: bool
    params: dict[str, Any]

    def validate(self) -> None:
        if self.action_type not in ALLOWED_ACTION_TYPES:
            raise ValueError(f"Unsupported action_type: {self.action_type}")
        if self.safety_level not in {"safe", "irreversible"}:
            raise ValueError(f"Invalid safety_level: {self.safety_level}")
        if self.safety_level == "irreversible" and not self.confirm_required:
            raise ValueError("Irreversible actions must require confirmation")


async def choose_next_action(
    intent: IntentObject,
    observation: dict[str, Any],
    collected_data: dict[str, Any],
    step_index: int,
    max_steps: int,
) -> NextAction:
    """Return the next action in the observe-decide-act loop."""
    if step_index >= max_steps:
        return NextAction(
            action_type="abort",
            reason="Exceeded configured visual action step limit.",
            expected_outcome="Execution stops safely.",
            safety_level="safe",
            confirm_required=False,
            params={},
        )

    if CACTUS_CLI:
        try:
            action = await _choose_with_cactus(intent, observation, collected_data)
            action.validate()
            return action
        except Exception as exc:
            print(f"[visual-planner] Cactus decision failed ({exc}); using deterministic fallback.")

    action = _fallback_action(intent, observation, collected_data, step_index)
    action.validate()
    return action


async def _choose_with_cactus(
    intent: IntentObject,
    observation: dict[str, Any],
    collected_data: dict[str, Any],
) -> NextAction:
    prompt = _build_prompt(intent, observation, collected_data)
    proc = await asyncio.create_subprocess_exec(
        CACTUS_CLI,
        "run",
        CACTUS_GEMMA4_MODEL,
        "--prompt",
        prompt,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(stderr.decode().strip())
    return _parse_next_action(stdout.decode())


def _build_prompt(intent: IntentObject, observation: dict[str, Any], collected_data: dict[str, Any]) -> str:
    return (
        "You are the planner for a local desktop voice agent. You delegate work\n"
        "to tools. Return exactly one JSON object.\n"
        "\n"
        "Allowed action_type:\n"
        "  - browser_task: delegate a browser task to the browser sub-agent.\n"
        "      Use for any goal that needs a web browser (apply to a job,\n"
        "      send LinkedIn DM, read Gmail, check a site, etc.).\n"
        "      params.task must be a complete natural-language task description\n"
        "      with concrete targets (URLs, form fields, message body). Use\n"
        "      ${slot} placeholders for resume path, contact name, etc.\n"
        "      Example params: {\\\"task\\\": \\\"Go to apply.ycombinator.com,\n"
        "      fill the Fall 2026 application using ${resume}, and pause for\n"
        "      confirmation before clicking Submit.\\\"}\n"
        "  - ask_user: need more info from the user. params.question required.\n"
        "  - complete: task finished successfully.\n"
        "  - abort: cannot proceed. params.reason should explain why.\n"
        "\n"
        "Required fields: action_type, reason, expected_outcome, safety_level,\n"
        "confirm_required, params.\n"
        "safety_level must be safe or irreversible.\n"
        "If action is irreversible, confirm_required must be true.\n"
        "For browser_task, set safety_level=irreversible when the task sends,\n"
        "submits, posts, or books; confirm_required=true in that case.\n"
        "Output only JSON.\n\n"
        f"intent_goal={intent.goal.value}\n"
        f"intent_target={json.dumps(intent.target, ensure_ascii=True)}\n"
        f"intent_slots={json.dumps(intent.slots, ensure_ascii=True)}\n"
        f"observation={json.dumps(observation, ensure_ascii=True)}\n"
        f"collected_data={json.dumps(collected_data, ensure_ascii=True)}\n"
    )


def _parse_next_action(raw: str) -> NextAction:
    cleaned = raw.strip()
    cleaned = re.sub(r"^```(?:json)?|```$", "", cleaned, flags=re.MULTILINE).strip()
    data = json.loads(cleaned)
    return NextAction(
        action_type=data.get("action_type", ""),
        reason=data.get("reason", ""),
        expected_outcome=data.get("expected_outcome", ""),
        safety_level=data.get("safety_level", "safe"),
        confirm_required=bool(data.get("confirm_required", False)),
        params=data.get("params", {}) or {},
    )


def _fallback_action(
    intent: IntentObject,
    observation: dict[str, Any],
    collected_data: dict[str, Any],
    step_index: int,
) -> NextAction:
    url = (observation.get("url") or "").lower()
    scope = observation.get("scope", "")

    if intent.requires_browser:
        slot_hint = ""
        if "resume" in intent.uses_local_data:
            slot_hint = " Use ${resume} to reference the user's resume file."
        base_task = intent.raw_transcript or "Complete the user request."
        target_json = json.dumps(intent.target, ensure_ascii=True)
        slots_json = json.dumps(intent.slots, ensure_ascii=True)
        task_text = (
            f"{base_task} Target: {target_json}. Slots: {slots_json}.{slot_hint}"
        )
        return NextAction(
            action_type="browser_task",
            reason="Delegate to browser sub-agent — fallback path.",
            expected_outcome="Browser sub-agent completes the task and returns a final answer.",
            safety_level="irreversible" if intent.requires_submission else "safe",
            confirm_required=bool(intent.requires_submission),
            params={"task": task_text},
        )

    if scope == "desktop" and step_index == 0:
        return NextAction(
            action_type="ask_user",
            reason="Need user context to progress local desktop action.",
            expected_outcome="User clarifies next desktop action.",
            safety_level="safe",
            confirm_required=False,
            params={"question": "I captured your current screen. Proceed with the next action?"},
        )

    return NextAction(
        action_type="complete",
        reason="No further action inferred for this goal/state.",
        expected_outcome="Orchestration exits cleanly.",
        safety_level="safe",
        confirm_required=False,
        params={},
    )
