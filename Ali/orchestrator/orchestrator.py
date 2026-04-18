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

        self._local_fs = FilesystemExecutor()
        self._local_as = AppleScriptExecutor()
        self._browser = None

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
        if action.action_type == "navigate":
            return await self._run_browser("navigate", {"url": action.params["url"]})
        if action.action_type == "upload_file":
            if action.params.get("mode") != "yc_apply_fill":
                raise ValueError("Unsupported upload_file mode")
            resume_path = data.get("resume_path")
            if not resume_path:
                resume_path = self._local_fs.find_by_alias("resume")
            await self._run_browser(
                "yc_apply_fill",
                {"resume_path": resume_path, "slots": data.get("slots", {})},
            )
            return {"resume_path": resume_path, "yc_form_filled": True}
        if action.action_type == "click_text":
            if action.params.get("mode") != "yc_apply_submit":
                raise ValueError("Unsupported click_text mode")
            return await self._run_browser("yc_apply_submit", {})
        if action.action_type == "ask_user":
            approved = await ask_confirmation(action.params.get("question", action.reason))
            return {"user_confirmed": approved}
        if action.action_type in {"wait_for_text", "scroll", "click_selector", "type_selector"}:
            return {"noop_action": action.action_type}
        raise ValueError(f"Unsupported action_type: {action.action_type}")

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

    async def _run_browser(self, action: str, params: dict):
        if self._browser is None:
            try:
                from executors.browser.browser import BrowserExecutor
            except ModuleNotFoundError as e:
                raise RuntimeError(
                    "Browser executor is unavailable. Install Playwright to run browser actions."
                ) from e
            self._browser = BrowserExecutor()

        if action == "navigate":
            await self._browser.navigate(params["url"])
            return {}
        if action == "yc_apply_fill":
            await self._browser.yc_apply_fill(params["resume_path"], params.get("slots", {}))
            return {}
        if action == "yc_apply_submit":
            await self._browser.yc_apply_submit()
            return {}
        if action == "capture_observation":
            return await self._browser.capture_observation(label=params.get("label", "browser"))
        raise ValueError(f"Unknown browser action: {action}")

    async def _observe(self, intent: IntentObject, label: str) -> dict:
        if intent.requires_browser:
            return await self._run_browser("capture_observation", {"label": label})
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
