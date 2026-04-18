"""Trace event collector. Used by every stage to record what happened so
Ona's UI / explanation layer can render it. Writes structured JSON Lines
to a sink (default stderr) for live tailing.
"""

from __future__ import annotations

import json
import sys
import time
from contextlib import contextmanager
from typing import Any, Callable, Iterator, TextIO

from .contracts import TraceEvent, TraceStage


class Tracer:
    """Lightweight per-turn trace collector.

    Usage:
        tracer = Tracer()
        with tracer.span("detection", "Detecting PII"):
            ...
        events = tracer.events
    """

    def __init__(
        self,
        sink: TextIO | None = None,
        emit_jsonl: bool = False,
        on_event: Callable[[TraceEvent], None] | None = None,
    ):
        self.events: list[TraceEvent] = []
        self._sink = sink if sink is not None else sys.stderr
        self._emit_jsonl = emit_jsonl
        self._on_event = on_event

    def event(self, stage: TraceStage, message: str, **payload: Any) -> TraceEvent:
        ev = TraceEvent(stage=stage, message=message, elapsed_ms=0.0, payload=payload)
        self._record(ev)
        return ev

    @contextmanager
    def span(self, stage: TraceStage, message: str, **payload: Any) -> Iterator[None]:
        t0 = time.perf_counter()
        try:
            yield
        finally:
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            ev = TraceEvent(
                stage=stage, message=message, elapsed_ms=elapsed_ms, payload=payload
            )
            self._record(ev)

    def _record(self, ev: TraceEvent) -> None:
        self.events.append(ev)
        if self._emit_jsonl:
            self._sink.write(json.dumps(ev.to_dict()) + "\n")
            self._sink.flush()
        if self._on_event:
            self._on_event(ev)

    def total_ms(self) -> float:
        return sum(e.elapsed_ms for e in self.events)
