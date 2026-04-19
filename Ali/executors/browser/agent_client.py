"""Layer 4B — Local browser agent client.

Spawns the vendored Node MCP server (executors/browser/agent/) and talks to it
over stdio. Surface mirrors the old HanziClient so the orchestrator is
unchanged. Status payload shape mirrors the Hanzi REST contract so existing
status parsing stays valid.
"""

from __future__ import annotations

import asyncio
import json
import os
from contextlib import AsyncExitStack
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


TaskState = Literal[
    "running",
    "awaiting_confirmation",
    "complete",
    "error",
    "cancelled",
    "timeout",
]


@dataclass
class ConfirmationPayload:
    summary: str
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass
class TaskStatus:
    id: str
    state: TaskState
    task: str = ""
    answer: str | None = None
    error: str | None = None
    confirmation: ConfirmationPayload | None = None


_AGENT_DIR = Path(__file__).resolve().parent / "agent"
_SERVER_ENTRY = _AGENT_DIR / "server" / "dist" / "index.js"


class LocalAgentClient:
    """MCP-stdio client for the vendored llm-in-chrome agent server."""

    def __init__(self, node_bin: str = "node", env: dict[str, str] | None = None):
        self._node_bin = node_bin
        self._env = {**os.environ, "LLM_PROVIDER": "cactus", **(env or {})}
        self._stack: AsyncExitStack | None = None
        self._session: ClientSession | None = None

    async def __aenter__(self):
        await self._connect()
        return self

    async def __aexit__(self, *exc):
        await self.close()

    async def _connect(self) -> None:
        if self._session:
            return
        if not _SERVER_ENTRY.exists():
            raise RuntimeError(
                f"Agent server bundle not found at {_SERVER_ENTRY}. "
                "Run: (cd executors/browser/agent/server && npm install && npm run build)"
            )
        params = StdioServerParameters(
            command=self._node_bin,
            args=[str(_SERVER_ENTRY)],
            env=self._env,
        )
        self._stack = AsyncExitStack()
        read, write = await self._stack.enter_async_context(stdio_client(params))
        self._session = await self._stack.enter_async_context(ClientSession(read, write))
        await self._session.initialize()

    async def close(self) -> None:
        if self._stack:
            await self._stack.aclose()
            self._stack = None
            self._session = None

    async def _call_tool(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        if not self._session:
            await self._connect()
        assert self._session is not None
        result = await self._session.call_tool(name, args)
        if not result.content:
            raise RuntimeError(f"empty MCP response from {name}")
        text = result.content[0].text  # type: ignore[union-attr]
        # Try JSON first — formatResult returns the full session as JSON
        # even when isError=true. Fall back to wrapping plain-text errors
        # ("Session not found: …", "Error: task cannot be empty") in our
        # TaskStatus shape.
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            if result.isError:
                return {
                    "session_id": args.get("session_id", ""),
                    "status": "error",
                    "task": "",
                    "error": text,
                }
            raise RuntimeError(
                f"MCP {name} returned non-JSON, non-error content: {text[:200]!r}"
            )

    async def run_task(
        self,
        task: str,
        session_id: str,
        url: str | None = None,
        context: str | None = None,
    ) -> TaskStatus:
        args: dict[str, Any] = {"task": task, "session_id": session_id}
        if url:
            args["url"] = url
        if context:
            args["context"] = context
        return _parse_status(await self._call_tool("browser_start", args))

    async def get_task(self, session_id: str) -> TaskStatus:
        return _parse_status(await self._call_tool("browser_status", {"session_id": session_id}))

    async def send_message(self, session_id: str, message: str) -> TaskStatus:
        return _parse_status(
            await self._call_tool("browser_message", {"session_id": session_id, "message": message})
        )

    async def cancel(self, session_id: str) -> TaskStatus:
        return _parse_status(await self._call_tool("browser_stop", {"session_id": session_id}))

    async def poll_until_paused_or_terminal(
        self,
        session_id: str,
        interval: float = 0.5,
        max_wait: float = 600.0,
    ) -> TaskStatus:
        terminal = {"complete", "error", "cancelled", "timeout", "awaiting_confirmation"}
        elapsed = 0.0
        while elapsed < max_wait:
            status = await self.get_task(session_id)
            if status.state in terminal:
                return status
            await asyncio.sleep(interval)
            elapsed += interval
        try:
            await self.cancel(session_id)
        except Exception:
            pass
        return TaskStatus(id=session_id, state="timeout", error="client-side poll timeout")


def _parse_status(data: dict[str, Any]) -> TaskStatus:
    conf = None
    if data.get("confirmation"):
        conf = ConfirmationPayload(
            summary=data["confirmation"]["summary"],
            payload=data["confirmation"].get("payload", {}),
        )
    return TaskStatus(
        id=data["session_id"],
        state=data["status"],
        task=data.get("task", ""),
        answer=data.get("answer"),
        error=data.get("error"),
        confirmation=conf,
    )
