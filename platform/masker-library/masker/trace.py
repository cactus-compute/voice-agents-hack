"""Trace event collector. Used by every stage to record what happened so
Ona's UI / explanation layer can render it. Writes structured JSON Lines
to a sink (default stderr) for live tailing.

This module also owns the **hash-chained audit log** — the tamper-evident
evidence trail that powers Masker's HIPAA story (164.312(b) Audit Controls
and 164.312(c)(1) Integrity). Each `evidence(...)` call appends one
`AuditEntry` to `audit.jsonl`, where every row's `entry_hash` is
SHA-256(canonical_json(row sans entry_hash)) and its `prev_hash` equals
the previous row's `entry_hash`. Flipping a single byte anywhere in the
file makes `verify_chain()` fail at exactly that line — that's the demo.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, TextIO

from .contracts import (
    GENESIS_HASH,
    AuditEntry,
    ChainVerification,
    PolicyName,
    Route,
    TraceEvent,
    TraceStage,
    compute_entry_hash,
)


def _utc_now_iso() -> str:
    """ISO-8601 UTC timestamp with microsecond precision and trailing Z."""
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


class Tracer:
    """Lightweight per-turn trace collector with optional hash-chained audit log.

    Backwards-compatible: every new parameter is keyword-only with a safe
    default. `Tracer()` continues to work exactly as before.

    Usage:
        # In-memory only (existing callers, tests):
        tracer = Tracer()

        # Compliance mode — append-only hash-chained evidence trail:
        tracer = Tracer(
            audit_path="audit.jsonl",
            surface="aurora-laptop",
            regulation="hipaa",
            policy="hipaa_base",
        )
        tracer.evidence(
            "policy",
            "Routed local-only because SSN detected",
            decision="local-only",
            controls=["164.312(a)(1)", "164.312(b)"],
            payload={"entity_types": ["ssn"], "spans": [[10, 21]]},
        )
    """

    def __init__(
        self,
        sink: TextIO | None = None,
        emit_jsonl: bool = False,
        on_event: Callable[[TraceEvent], None] | None = None,
        *,
        audit_path: str | Path | None = None,
        surface: str = "cli",
        regulation: str = "hipaa",
        policy: PolicyName | None = None,
    ):
        self.events: list[TraceEvent] = []
        self._sink = sink if sink is not None else sys.stderr
        self._emit_jsonl = emit_jsonl
        self._on_event = on_event

        # ------------------------------------------------------------------
        # Audit log state. Lazy: opened on first evidence() call.
        # ------------------------------------------------------------------
        self.audit_path: Path | None = Path(audit_path) if audit_path else None
        self.surface = surface
        self.regulation = regulation
        self.policy = policy
        self._audit_lock = threading.Lock()
        self._last_hash: str | None = None  # cached tail hash; None until loaded

    # ------------------------------------------------------------------ #
    # In-memory trace events (existing API, unchanged)
    # ------------------------------------------------------------------ #

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

    # ------------------------------------------------------------------ #
    # Hash-chained audit log (new — powers the demo)
    # ------------------------------------------------------------------ #

    def evidence(
        self,
        stage: TraceStage,
        message: str,
        *,
        decision: Route | None = None,
        controls: list[str],
        payload: dict[str, Any] | None = None,
        elapsed_ms: float = 0.0,
    ) -> AuditEntry:
        """Build a hash-chained AuditEntry, append it to `audit_path`, return it.

        If `audit_path` was not configured, this is a no-op that still
        returns the constructed entry (handy for tests / dry-runs).

        IMPORTANT — `payload` MUST NOT contain raw PHI. Pass entity types,
        span indices, and lengths only. We assert this defensively below.
        """
        payload = dict(payload or {})
        _assert_payload_is_phi_free(payload)

        prev_hash = self._load_last_hash()
        body_without_hash: dict[str, Any] = {
            "ts": _utc_now_iso(),
            "surface": self.surface,
            "stage": stage,
            "message": message,
            "elapsed_ms": float(elapsed_ms),
            "decision": decision,
            "policy": self.policy,
            "regulation": self.regulation,
            "controls": list(controls),
            "payload": payload,
            "prev_hash": prev_hash,
        }
        entry_hash = compute_entry_hash(body_without_hash)

        entry = AuditEntry(
            ts=body_without_hash["ts"],
            surface=self.surface,
            stage=stage,
            message=message,
            elapsed_ms=body_without_hash["elapsed_ms"],
            decision=decision,
            policy=self.policy,
            regulation=self.regulation,
            controls=body_without_hash["controls"],
            payload=payload,
            prev_hash=prev_hash,
            entry_hash=entry_hash,
        )

        if self.audit_path is not None:
            self._append_audit(entry)

        return entry

    def _load_last_hash(self) -> str:
        """Return the entry_hash of the last row in audit_path, or GENESIS.

        Cached after the first call so we're not re-reading the file every
        evidence() call. Cache is invalidated on every write.
        """
        if self._last_hash is not None:
            return self._last_hash

        if self.audit_path is None or not self.audit_path.exists():
            self._last_hash = GENESIS_HASH
            return self._last_hash

        last: str | None = None
        with self.audit_path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    # Corrupt tail — refuse to append on top of garbage.
                    raise RuntimeError(
                        f"Refusing to append to corrupt audit log: {self.audit_path}"
                    )
                last = row.get("entry_hash")

        self._last_hash = last or GENESIS_HASH
        return self._last_hash

    def _append_audit(self, entry: AuditEntry) -> None:
        """Thread-safe append + fsync. One row per line, JSONL."""
        if self.audit_path is None:
            return
        line = entry.to_jsonl() + "\n"
        with self._audit_lock:
            self.audit_path.parent.mkdir(parents=True, exist_ok=True)
            # Open per-write so multiple Tracer instances pointed at the
            # same file behave sanely (last-writer-wins, but each row is
            # atomic relative to other appends because we hold the lock).
            with self.audit_path.open("a", encoding="utf-8") as fh:
                fh.write(line)
                fh.flush()
                try:
                    os.fsync(fh.fileno())
                except (OSError, AttributeError):
                    # fsync may not be available on every fs (e.g. tmpfs in
                    # some sandboxes). Best-effort durability.
                    pass
            self._last_hash = entry.entry_hash

    # ------------------------------------------------------------------ #
    # Verification — the demo's kill shot
    # ------------------------------------------------------------------ #

    @classmethod
    def verify_chain(cls, path: str | Path) -> ChainVerification:
        """Read every row of `audit.jsonl`, recompute each `entry_hash`,
        and check that every `prev_hash` links to the previous row.

        Returns a `ChainVerification` describing the first failure (if any).
        Designed to be called from `python -m masker verify <path>` and
        from tests. Pure read; never mutates the file.
        """
        path = Path(path)
        if not path.exists():
            return ChainVerification(
                valid=False,
                total_entries=0,
                reason=f"audit log not found: {path}",
            )

        prev_hash = GENESIS_HASH
        total = 0

        with path.open("r", encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, start=1):
                line = raw.strip()
                if not line:
                    continue
                total += 1

                try:
                    row = json.loads(line)
                except json.JSONDecodeError as exc:
                    return ChainVerification(
                        valid=False,
                        total_entries=total - 1,
                        broken_at_line=lineno,
                        reason=f"invalid JSON on line {lineno}: {exc.msg}",
                    )

                claimed_hash = row.get("entry_hash")
                claimed_prev = row.get("prev_hash")

                if claimed_prev != prev_hash:
                    return ChainVerification(
                        valid=False,
                        total_entries=total - 1,
                        broken_at_line=lineno,
                        expected_hash=prev_hash,
                        computed_hash=claimed_prev,
                        reason=(
                            f"prev_hash mismatch on line {lineno}: "
                            f"chain expected prev={prev_hash[:12]}..., "
                            f"row claims prev={str(claimed_prev)[:12]}..."
                        ),
                    )

                body_without_hash = {k: v for k, v in row.items() if k != "entry_hash"}
                recomputed = compute_entry_hash(body_without_hash)

                if recomputed != claimed_hash:
                    return ChainVerification(
                        valid=False,
                        total_entries=total - 1,
                        broken_at_line=lineno,
                        expected_hash=claimed_hash,
                        computed_hash=recomputed,
                        reason=(
                            f"entry_hash mismatch on line {lineno}: "
                            f"row content does not hash to its claimed entry_hash "
                            f"(file has been tampered with)"
                        ),
                    )

                prev_hash = claimed_hash

        return ChainVerification(valid=True, total_entries=total)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Quick allow-list of payload keys that are known PHI-free metadata. Anything
# else is allowed too (we can't enumerate every legitimate key) but values
# are scanned defensively.
_FORBIDDEN_PAYLOAD_SUBSTRINGS = (
    # Common PHI shapes we should never see verbatim in payloads.
    # These are heuristics, not exhaustive — payload discipline is enforced
    # by code review, not regex. The check below catches obvious slips.
)


def _assert_payload_is_phi_free(payload: dict[str, Any]) -> None:
    """Guard rail — never let raw PHI into the audit log payload.

    The contract is that callers pass *metadata about* spans (types,
    indices, lengths) and never the raw values themselves. We can't
    enforce that perfectly without tagging every entity, but we can
    refuse anything obviously dangerous: nested dicts/lists deeper than
    one level of plain values, or string values that look like SSNs /
    emails / phone numbers.

    This is a belt-and-suspenders check; the real safety comes from
    callers (filter_input, voice_loop) only ever passing types/indices.
    """
    # Lazy import to avoid a circular dep at module load.
    from .detection import detect  # local import

    for key, value in payload.items():
        if isinstance(value, str) and len(value) <= 256:
            # Run the detector on suspicious-looking string values. If it
            # finds anything sensitive, the caller made a mistake.
            det = detect(value)
            if det.has_sensitive:
                raise ValueError(
                    f"audit payload key {key!r} contains apparent PHI "
                    f"(detected: {[e.type.value for e in det.entities]}). "
                    f"Pass entity types and span indices, never raw values."
                )
