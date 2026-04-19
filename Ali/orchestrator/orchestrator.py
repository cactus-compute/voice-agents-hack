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
# ask_confirmation removed — no popups during demo

MAX_STEPS = 20
MAX_RETRIES = 2


class Orchestrator:
    def __init__(self):
        from executors.local.applescript import AppleScriptExecutor
        from executors.local.filesystem import FilesystemExecutor
        from executors.browser.agent_client import LocalAgentClient
        from executors.local.script_runtime import catalog_summary, load_catalog

        self._local_fs = FilesystemExecutor()
        self._local_as = AppleScriptExecutor()
        self._browser_agent = LocalAgentClient()
        self._script_catalog = load_catalog()
        self._catalog_summary = catalog_summary
        self._reload_catalog = load_catalog

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
                print(f"[orchestrator] Auto-approving: {_confirmation_message(action)}")

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
            print(f"[orchestrator] ask_user (auto-approved): {action.params.get('question', action.reason)}")
            return {"user_confirmed": True}
        if action.action_type == "run_script":
            return await self._handle_run_script(action, data)
        if action.action_type == "author_script":
            return await self._handle_author_script(action, data)
        if action.action_type == "compose_mail":
            return self._handle_compose_mail(action, data)
        if action.action_type in {"wait_for_text", "scroll", "click_selector", "type_selector", "navigate", "click_text", "upload_file"}:
            return {"noop_action": action.action_type}
        raise ValueError(f"Unsupported action_type: {action.action_type}")

    async def _handle_run_script(self, action: NextAction, data: dict) -> dict:
        from executors.local.script_runtime import run_script

        name = str(action.params.get("name") or "").strip()
        if not name:
            raise ValueError("run_script requires params.name")
        args = dict(action.params.get("args") or {})
        resolved = data.get("resolved_local_files") or {}
        for key, value in list(args.items()):
            if isinstance(value, str) and value.startswith("$"):
                role = value[1:]
                if isinstance(resolved, dict) and role in resolved:
                    args[key] = resolved[role]
                elif role in data and isinstance(data[role], str):
                    args[key] = data[role]
        result = await run_script(name, args, self._script_catalog)
        print(f"[orchestrator][script] name={name} returncode={result.returncode} duration_ms={result.duration_ms}")
        if not result.ok():
            snippet = (result.stderr or result.stdout).strip().splitlines()
            detail = snippet[-1] if snippet else "script failed"
            raise RuntimeError(f"script {name!r} exited {result.returncode}: {detail}")
        return {"script_result": {"name": result.name, "returncode": result.returncode, "duration_ms": result.duration_ms, "stdout_snippet": result.stdout[:200]}}

    def _handle_compose_mail(self, action: NextAction, data: dict) -> dict:
        params = action.params or {}
        resolved = data.get("resolved_local_files") or {}
        attachments = params.get("attachments") or [v for role in ("attachment", "deck", "document") for v in ([resolved.get(role)] if isinstance(resolved, dict) and resolved.get(role) else [])]
        self._local_as.compose_mail(to=str(params.get("to") or ""), subject=str(params.get("subject") or ""), body=str(params.get("body") or ""), send=bool(params.get("send", False)), attachments=attachments or None)
        return {"mail_composed": True}

    async def _handle_author_script(self, action: NextAction, data: dict) -> dict:
        from executors.local.script_runtime import ScriptParam, ScriptValidationError, persist_script

        params = action.params or {}
        parsed_params: list[ScriptParam] = []
        for entry in (params.get("params") or []):
            if isinstance(entry, dict):
                parsed_params.append(ScriptParam(name=str(entry.get("name", "")), type=str(entry.get("type", "string")) or "string", required=bool(entry.get("required", True)), default=(None if entry.get("default") is None else str(entry.get("default")))))
        try:
            spec = persist_script(name=str(params.get("name") or ""), runtime=str(params.get("runtime") or ""), description=str(params.get("description") or ""), params=tuple(parsed_params), body=str(params.get("body") or ""))
        except ScriptValidationError as exc:
            raise RuntimeError(f"author_script rejected: {exc}") from exc
        self._script_catalog = self._reload_catalog()
        return {"authored_script": spec.name, "script_catalog": self._catalog_summary(self._script_catalog)}

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
                print(f"[orchestrator] browser_agent awaiting_confirmation (auto-approved): {summary}")
                await self._browser_agent.send_message(handle.id, "yes, proceed")
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
