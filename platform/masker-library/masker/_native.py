"""Optional bridge to the Rust `masker` binary.

The Python package remains the easiest integration surface for hackathon teams,
but the canonical privacy engine now lives in Rust. When a compiled `masker`
binary is available we delegate detection / policy / masking to it; otherwise
we fall back to the pure-Python implementation.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contracts import DetectionResult, Entity, EntityType, MaskedText, PolicyDecision, TraceEvent


_DISABLE_VALUES = {"0", "false", "no", "off", "disabled"}
_REQUIRE_VALUES = {"1", "true", "yes", "on", "force", "required"}


@dataclass(frozen=True)
class NativeFilterInputResult:
    masked_input: MaskedText
    policy: PolicyDecision
    detection: DetectionResult
    trace: list[TraceEvent]


@dataclass(frozen=True)
class NativeFilterOutputResult:
    safe_text: str
    trace: list[TraceEvent]


def available() -> bool:
    if _mode() == "disabled":
        return False
    return _find_binary() is not None


def try_filter_input(
    text: str,
    *,
    policy_name: str = "hipaa_base",
    mask_mode: str = "placeholder",
) -> NativeFilterInputResult | None:
    try:
        return filter_input(text, policy_name=policy_name, mask_mode=mask_mode)
    except Exception:
        if _mode() == "required":
            raise
        return None


def filter_input(
    text: str,
    *,
    policy_name: str = "hipaa_base",
    mask_mode: str = "placeholder",
) -> NativeFilterInputResult:
    payload = _run_json(
        [
            "filter-input",
            "--text",
            text,
            "--policy",
            policy_name.replace("_", "-"),
            "--mask-mode",
            mask_mode,
        ]
    )
    return NativeFilterInputResult(
        masked_input=_masked_from_dict(payload["masked_input"]),
        policy=_policy_from_dict(payload["policy"]),
        detection=_detection_from_dict(payload["detection"]),
        trace=_trace_list_from_payload(payload.get("trace", [])),
    )


def try_filter_output(
    text: str,
    *,
    detection: DetectionResult | None = None,
) -> NativeFilterOutputResult | None:
    try:
        return filter_output(text, detection=detection)
    except Exception:
        if _mode() == "required":
            raise
        return None


def filter_output(
    text: str,
    *,
    detection: DetectionResult | None = None,
) -> NativeFilterOutputResult:
    args = ["filter-output", "--text", text]
    if detection is not None:
        args.extend(["--detection-json", json.dumps(detection.to_dict())])
    payload = _run_json(args)
    return NativeFilterOutputResult(
        safe_text=str(payload["safe_text"]),
        trace=_trace_list_from_payload(payload.get("trace", [])),
    )


def _run_json(args: list[str]) -> dict[str, Any]:
    binary = _find_binary()
    if binary is None:
        raise RuntimeError("Rust masker binary not found.")

    proc = subprocess.run(
        [binary, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise RuntimeError(f"Rust masker failed ({proc.returncode}): {detail}")

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Rust masker emitted invalid JSON: {proc.stdout!r}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError(f"Rust masker emitted non-object JSON: {payload!r}")
    return payload


def _find_binary() -> str | None:
    override = os.environ.get("MASKER_RUST_BIN")
    if override:
        return override if Path(override).is_file() else None

    on_path = shutil.which("masker")
    if on_path:
        return on_path

    repo_root = Path(__file__).resolve().parents[3]
    for profile in ("release", "debug"):
        candidate = repo_root / "platform" / "masker-core" / "target" / profile / "masker"
        if candidate.is_file():
            return str(candidate)
    return None


def _mode() -> str:
    raw = os.environ.get("MASKER_NATIVE", "auto").strip().lower()
    if raw in _DISABLE_VALUES:
        return "disabled"
    if raw in _REQUIRE_VALUES:
        return "required"
    return "auto"


def _entity_from_dict(data: dict[str, Any]) -> Entity:
    return Entity(
        type=EntityType(str(data["type"])),
        value=str(data["value"]),
        start=int(data.get("start", -1)),
        end=int(data.get("end", -1)),
        confidence=float(data.get("confidence", 1.0)),
    )


def _detection_from_dict(data: dict[str, Any]) -> DetectionResult:
    return DetectionResult(
        entities=[_entity_from_dict(entity) for entity in data.get("entities", [])],
        risk_level=str(data["risk_level"]),
    )


def _policy_from_dict(data: dict[str, Any]) -> PolicyDecision:
    return PolicyDecision(
        route=str(data["route"]),
        policy=str(data["policy"]),
        rationale=str(data.get("rationale", "")),
    )


def _masked_from_dict(data: dict[str, Any]) -> MaskedText:
    token_map = {str(key): str(value) for key, value in dict(data.get("token_map", {})).items()}
    return MaskedText(text=str(data["text"]), token_map=token_map)


def _trace_from_dict(data: dict[str, Any]) -> TraceEvent:
    payload = {str(key): value for key, value in dict(data.get("payload", {})).items()}
    return TraceEvent(
        stage=str(data["stage"]),
        message=str(data["message"]),
        elapsed_ms=float(data.get("elapsed_ms", 0.0)),
        payload=payload,
    )


def _trace_list_from_payload(items: Any) -> list[TraceEvent]:
    if not isinstance(items, list):
        return []
    return [_trace_from_dict(item) for item in items if isinstance(item, dict)]
