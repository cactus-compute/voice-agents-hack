"""
WebSocket bridge overlay for the Tauri/React UI.
"""

from __future__ import annotations

import asyncio
import json
import queue
import threading
import time
from typing import Any

import websockets  # pyright: ignore[reportMissingImports]

POLL_MS = 40


class TranscriptionOverlay:
    """
    UI bridge that keeps the same push(state, text) contract expected by the agent.
    """

    def __init__(self, host: str = "127.0.0.1", port: int = 8765) -> None:
        self._host = host
        self._port = port
        self._q: queue.Queue[tuple[str, str]] = queue.Queue()
        self._clients: set[Any] = set()
        self._recent: list[dict[str, str]] = []
        self._lock = threading.Lock()

        self._loop = asyncio.new_event_loop()
        self._ready = threading.Event()
        self._stopped = threading.Event()
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()
        self._ready.wait(timeout=5)

    def push(self, state: str, text: str = "") -> None:
        self._q.put((state, text))

    def run_forever(self) -> None:
        """
        Keep process alive while the UI runs out-of-process.
        """
        print(f"[overlay] Web UI bridge on ws://{self._host}:{self._port}")
        try:
            while not self._stopped.is_set():
                time.sleep(0.2)
        except KeyboardInterrupt:
            pass
        finally:
            self.close()

    def close(self) -> None:
        if self._stopped.is_set():
            return
        self._stopped.set()
        self._q.put(("hidden", ""))
        if self._loop.is_running():
            self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=2)

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._server = self._loop.run_until_complete(self._start_server())
        try:
            self._loop.run_forever()
        finally:
            self._server.close()
            self._loop.run_until_complete(self._server.wait_closed())
            self._loop.close()

    async def _start_server(self):
        server = await websockets.serve(self._handle_client, self._host, self._port)
        self._loop.create_task(self._broadcast_loop())
        self._ready.set()
        return server

    async def _handle_client(self, websocket) -> None:
        with self._lock:
            self._clients.add(websocket)
            recent = list(self._recent)

        for evt in recent:
            await websocket.send(json.dumps(evt))

        await websocket.send(json.dumps({"state": "system", "text": "Connected to Ali backend"}))

        try:
            await websocket.wait_closed()
        finally:
            with self._lock:
                self._clients.discard(websocket)

    async def _broadcast_loop(self) -> None:
        while not self._stopped.is_set():
            try:
                state, text = self._q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(POLL_MS / 1000)
                continue
            event = {"state": state, "text": text}

            with self._lock:
                self._recent.append(event)
                self._recent = self._recent[-20:]
                clients = list(self._clients)

            if not clients:
                continue

            dead: list[Any] = []
            payload = json.dumps(event)
            for client in clients:
                try:
                    await client.send(payload)
                except Exception:
                    dead.append(client)

            if dead:
                with self._lock:
                    for client in dead:
                        self._clients.discard(client)
