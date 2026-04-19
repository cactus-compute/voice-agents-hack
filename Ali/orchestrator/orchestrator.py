"""
Layer 3 — Orchestrator
Vision-first state machine: observe, decide, act, verify.
"""

import asyncio
import time

from config.settings import DRY_RUN, VISION_FIRST_ENABLED, VISION_MAX_ACTION_STEPS
from intent.schema import IntentObject, KnownGoal
from orchestrator.state import TaskState, TaskStatus
from orchestrator.visual_planner import NextAction, choose_next_action
from ui.confirmation import ask_confirmation

MAX_STEPS = 20
MAX_RETRIES = 2


class Orchestrator:
    def __init__(self):
        from executors.local.applescript import AppleScriptExecutor
        from executors.local.filesystem import FilesystemExecutor
        from executors.browser.agent_client import LocalAgentClient

        self._local_fs = FilesystemExecutor()
        self._local_as = AppleScriptExecutor()
        # Browser sub-agent. Spawns the vendored MCP server lazily on first use;
        # we don't await connect here so startup stays snappy if no browser
        # goal is requested.
        self._browser_agent = LocalAgentClient()

    async def run(self, intent: IntentObject):
        if intent.goal == KnownGoal.UNKNOWN:
            print(f"[orchestrator] Unknown intent: '{intent.raw_transcript}' — cannot act.")
            return

        state = TaskState(
            goal=intent.goal,
            plan_name="vision-first-observe-loop",
            steps=[],
            collected_data={
                **intent.slots,
                "slots": intent.slots,
                **{k: k for k in intent.uses_local_data},
            },
        )
        state.status = TaskStatus.RUNNING

        if not VISION_FIRST_ENABLED:
            raise RuntimeError("VISION_FIRST_ENABLED is false; this build requires vision-first mode.")

        print(f"[orchestrator] Starting plan: {state.plan_name}")
        observation = await self._observe(intent, "initial")
        state.collected_data["last_observation"] = observation
        print(f"[orchestrator][observe] initial scope={observation.get('scope')} path={observation.get('screenshot_path')}")

        while state.status == TaskStatus.RUNNING:
            if state.step_index >= min(MAX_STEPS, VISION_MAX_ACTION_STEPS):
                state.fail("Exceeded max steps — aborting for safety.")
                break

            step_started = time.perf_counter()
            action = await choose_next_action(
                intent=intent,
                observation=observation,
                collected_data=state.collected_data,
                step_index=state.step_index,
                max_steps=VISION_MAX_ACTION_STEPS,
            )
            print(
                f"[orchestrator][decision] step_index={state.step_index} "
                f"action_type={action.action_type} safety={action.safety_level}"
            )

            if action.action_type == "complete":
                state.status = TaskStatus.COMPLETED
                print("[orchestrator] Done: planner reported complete.")
                break
            if action.action_type == "abort":
                state.fail(action.reason or "Planner aborted.")
                break

            if action.confirm_required:
                state.status = TaskStatus.AWAITING_CONFIRMATION
                msg = _confirmation_message(action)
                approved = await ask_confirmation(msg)
                if not approved:
                    state.status = TaskStatus.ABORTED
                    print("[orchestrator] User aborted.")
                    return
                state.status = TaskStatus.RUNNING

            if self._is_dry_run_skip_action(action):
                elapsed = time.perf_counter() - step_started
                print(
                    f"[orchestrator][dry-run] Skipping irreversible action: "
                    f"{action.action_type} elapsed={elapsed:.2f}s"
                )
                state.step_index += 1
                observation = await self._observe(intent, f"post_skip_{state.step_index}")
                state.collected_data["last_observation"] = observation
                continue

            retries = 0
            while retries <= MAX_RETRIES:
                try:
                    result = await self._execute_action(intent, action, state.collected_data)
                    if isinstance(result, dict):
                        state.collected_data.update(result)
                    elapsed = time.perf_counter() - step_started
                    print(
                        f"[orchestrator][step] status=ok retries={retries} elapsed={elapsed:.2f}s "
                        f"action_type={action.action_type}"
                    )
                    state.step_index += 1
                    observation = await self._observe(intent, f"post_action_{state.step_index}")
                    state.collected_data["last_observation"] = observation
                    print(
                        f"[orchestrator][observe] scope={observation.get('scope')} "
                        f"path={observation.get('screenshot_path')}"
                    )
                    break
                except Exception as e:
                    retries += 1
                    elapsed = time.perf_counter() - step_started
                    print(
                        f"[orchestrator][step] status=failed retries={retries} "
                        f"elapsed={elapsed:.2f}s action_type={action.action_type} error={e}"
                    )

                    if retries <= MAX_RETRIES:
                        await asyncio.sleep(1)
                        continue
                    approved = await ask_confirmation(
                        f"Action '{action.action_type}' failed: {e}\n\nRetry?"
                    )
                    if approved:
                        retries = 0
                        continue
                    state.fail(str(e))
                    return

        if state.status == TaskStatus.FAILED:
            print(f"[orchestrator] Failed: {state.error}")
        elif state.status == TaskStatus.COMPLETED:
            print(f"[orchestrator] Done: {state.goal}")

    async def _execute_action(self, intent: IntentObject, action: NextAction, data: dict):
        if action.action_type == "browser_task":
            task_text = self._resolve_task_slots(action.params.get("task", ""), data)
            return await self._run_browser_agent(task_text)
        if action.action_type == "ask_user":
            approved = await ask_confirmation(action.params.get("question", action.reason))
            return {"user_confirmed": approved}
        raise ValueError(f"Unsupported action_type: {action.action_type}")

    def _resolve_task_slots(self, task: str, data: dict) -> str:
        """Substitute ${resume}, ${contact_X}, etc. with local values. The
        planner emits placeholders so sensitive data never hits the LLM that
        generates the task string."""
        # Resume: resolve lazily
        if "${resume}" in task:
            resume_path = data.get("resume_path") or self._local_fs.find_by_alias("resume")
            task = task.replace("${resume}", resume_path or "")
            data["resume_path"] = resume_path
        # Any ${contact_NAME}
        import re as _re
        for match in _re.findall(r"\$\{contact_([A-Za-z0-9_]+)\}", task):
            address = self._local_as.resolve_contact(match.replace("_", " "))
            task = task.replace(f"${{contact_{match}}}", address or "")
        return task

    async def _run_browser_agent(self, task: str) -> dict:
        """Hand a natural-language task to the browser sub-agent. The sub-agent
        owns the agent loop (navigation, DOM reading, tool calls) and returns
        a terminal TaskStatus. We surface awaiting_confirmation back to the
        user, relay their choice, and continue until terminal."""
        print(f"[orchestrator] browser_task → sub-agent: {task[:120]}...")
        handle = await self._browser_agent.run_task(task=task, session_id="local")
        if handle.state in ("error", "cancelled", "timeout"):
            raise RuntimeError(handle.error or f"sub-agent {handle.state}")

        while True:
            status = await self._browser_agent.poll_until_paused_or_terminal(handle.id)
            if status.state == "awaiting_confirmation":
                summary = status.confirmation.summary if status.confirmation else "Proceed?"
                payload = status.confirmation.payload if status.confirmation else {}
                detail = "\n".join(f"  {k}: {v}" for k, v in (payload or {}).items())
                approved = await ask_confirmation(f"{summary}\n{detail}\n\nProceed?")
                await self._browser_agent.send_message(handle.id, "yes, proceed" if approved else "no, cancel")
                if not approved:
                    return {"aborted_by_user": True}
                continue
            if status.state == "complete":
                print(f"[orchestrator] browser_task complete: {status.answer}")
                return {"browser_answer": status.answer or "done"}
            if status.state in ("error", "cancelled", "timeout"):
                raise RuntimeError(status.error or f"sub-agent {status.state}")

    async def _run_local(self, action: str, params: dict):
        if action == "find_file":
            path = self._local_fs.find_by_alias(params["alias"])
            return {"resume_path": path}
        if action == "resolve_contact":
            address = self._local_as.resolve_contact(params["name"])
            return {"contact": address, "contact_resolved": True}
        if action == "send_imessage":
            self._local_as.send_imessage(params["contact"], params["body"])
            return {}
        if action == "compose_mail":
            self._local_as.compose_mail(params["to"], params["subject"], params["body"])
            return {}
        if action == "create_calendar_event":
            self._local_as.create_calendar_event(
                params["title"], params.get("date", ""), params.get("time", ""), params.get("attendees", [])
            )
            return {}
        raise ValueError(f"Unknown local action: {action}")

    async def _observe(self, intent: IntentObject, label: str) -> dict:
        """Observation for the outer planner. For browser goals we return a
        minimal scope marker — the sub-agent is responsible for seeing the
        page itself. For desktop goals we capture a screenshot via AppleScript."""
        if intent.requires_browser:
            return {"scope": "browser", "label": label}
        return self._local_as.capture_observation(label=label)

    def _is_dry_run_skip_action(self, action: NextAction) -> bool:
        return DRY_RUN and action.safety_level == "irreversible"


def _resolve_params(params: dict, data: dict) -> dict:
    resolved = {}
    for k, v in params.items():
        if isinstance(v, str) and v.startswith("$"):
            key = v[1:]
            resolved[k] = data.get(key, v)
        else:
            resolved[k] = v
    return resolved


def _confirmation_message(action: NextAction) -> str:
    safe_params = {k: v for k, v in action.params.items() if k != "slots"}
    detail = "\n".join(f"  {k}: {v}" for k, v in safe_params.items())
    return (
        f"About to execute: {action.action_type}\n"
        f"Reason: {action.reason}\n"
        f"{detail}\n\nProceed?"
    )
