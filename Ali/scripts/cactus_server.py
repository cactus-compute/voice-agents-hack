"""HTTP bridge between the Node browser-agent and Cactus's Python SDK.

Listens on :8765 by default. One endpoint: POST /v1/complete.

Cactus's Python bindings are bare ctypes — they take JSON STRINGS for
messages/options/tools, not Python dicts. This sidecar JSON-encodes on
the way in and decodes the response on the way out. Wire format docs:
https://github.com/cactus-compute/cactus/blob/main/docs/cactus_engine.md

Run:
    python scripts/cactus_server.py [--port 8765] [--model google/gemma-4-E4B-it]

Model can be either an HF id (`google/gemma-4-E4B-it` — auto-resolved
under /opt/homebrew/opt/cactus/libexec/weights/) or an absolute path.
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn

# ── Deferred cactus import so tests can import this module without the SDK ────
_MODEL = None
_loaded_model: str | None = None

log = logging.getLogger("cactus_server")
logging.basicConfig(level=logging.INFO, format="%(message)s")

# Where `cactus run <hf_id>` caches downloaded weights.
_CACTUS_WEIGHTS_DIR = Path("/opt/homebrew/opt/cactus/libexec/weights")


# ── Helper functions (testable without SDK) ───────────────────────────────────

def wrap_tools_for_cactus(tools: list[dict[str, Any]] | None) -> list[dict[str, Any]] | None:
    """Wrap bare {name, description, parameters} dicts into Cactus format.

    Returns None if tools is empty/None so Cactus skips tool RAG entirely
    (passing tools=[] would still activate RAG with zero candidates).
    """
    if not tools:
        return None
    return [{"type": "function", "function": t} for t in tools]


def decode_b64_images_to_paths(b64_list: list[str]) -> list[str]:
    """Decode a list of base64 PNG strings to temporary files on disk.

    Returns the list of file paths. Caller is responsible for cleanup.
    Uses mkstemp so files are created with O_EXCL — safe against races.
    Always writes as .png (Cactus engine sniffs MIME from extension).
    """
    paths: list[str] = []
    for b64 in b64_list:
        fd, path = tempfile.mkstemp(suffix=".png")
        with os.fdopen(fd, "wb") as fh:
            fh.write(base64.b64decode(b64))
        paths.append(path)
    return paths


def cleanup_image_paths(paths: list[str]) -> None:
    """Unlink tempfiles created by decode_b64_images_to_paths; ignores errors."""
    for p in paths:
        try:
            os.unlink(p)
        except OSError:
            pass


def resolve_model_path(model: str) -> str:
    """Accept either an HF id (`google/gemma-4-E4B-it`) or an absolute path.

    HF ids are resolved against the Cactus weights cache, dropping the org
    prefix and trying both the original casing and the lowercased form
    (Cactus's `cactus run` lowercases some directory names — observed with
    `gemma-4-E4B-it` becoming `gemma-4-e4b-it` on disk).
    """
    p = Path(model)
    if p.is_absolute():
        return str(p)
    short = model.split("/", 1)[-1]
    candidates = [_CACTUS_WEIGHTS_DIR / short, _CACTUS_WEIGHTS_DIR / short.lower()]
    for c in candidates:
        if c.exists():
            return str(c)
    # Return the original-case path so the "weights not found" error message
    # in _load_model points at the obvious location.
    return str(candidates[0])


def build_options(req: "CompleteRequest") -> dict[str, Any]:
    """Build the options JSON for cactus_complete.

    We disable tool RAG (we'll have ~13 tools in the agent loop and can't
    afford the default top-2 filter) and disable auto cloud handoff (the
    Node provider catches `cloud_handoff: true` and falls through to its
    own Vertex client per integration guide §3.6 Option B).
    """
    return {
        "max_tokens": req.max_tokens,
        "temperature": 0.0,
        "tool_rag_top_k": 0,
        "force_tools": False,
        "confidence_threshold": req.confidence_threshold,
        "auto_handoff": req.auto_handoff,
    }


# ── HTTP layer ───────────────────────────────────────────────────────────────

class CompleteRequest(BaseModel):
    messages: list[dict]          # [{"role", "content", "images_b64"?}]
    tools: list[dict] | None = None
    max_tokens: int = 2048
    confidence_threshold: float = 0.7
    auto_handoff: bool = False    # we manage handoff in Node (Option B)


app = FastAPI()


@app.get("/healthz")
def healthz():
    return {"ok": _MODEL is not None, "model": _loaded_model}


@app.post("/v1/complete")
def complete(req: CompleteRequest):
    if _MODEL is None:
        raise HTTPException(503, "Cactus model not loaded")

    # Base64 images → tempfile paths for each message that includes images_b64.
    all_temp_paths: list[str] = []
    for m in req.messages:
        b64_list = m.pop("images_b64", None)
        if b64_list:
            try:
                paths = decode_b64_images_to_paths(b64_list)
            except Exception as exc:
                cleanup_image_paths(all_temp_paths)
                raise HTTPException(400, f"image decode error: {exc}")
            all_temp_paths.extend(paths)
            m["images"] = paths

    tools_wrapped = wrap_tools_for_cactus(req.tools) or []
    options = build_options(req)

    t0 = time.time()
    try:
        from cactus import cactus_complete  # type: ignore  # lazy import
        raw = cactus_complete(
            _MODEL,
            json.dumps(req.messages),
            json.dumps(options),
            json.dumps(tools_wrapped),
            None,  # no streaming callback
        )
        result = json.loads(raw)
    except HTTPException:
        raise
    except Exception as e:
        log.exception("cactus completion failed")
        raise HTTPException(500, f"cactus error: {e}")
    finally:
        # Always clean up temp image files, even on exception.
        cleanup_image_paths(all_temp_paths)

    log.info(json.dumps({
        "model": _loaded_model,
        "latency_ms": int((time.time() - t0) * 1000),
        "in_tok": result.get("prefill_tokens", 0),
        "out_tok": result.get("decode_tokens", 0),
        "confidence": result.get("confidence"),
        "cloud_handoff": result.get("cloud_handoff"),
    }))
    return result


@app.on_event("shutdown")
def _shutdown():
    global _MODEL
    if _MODEL is not None:
        try:
            from cactus import cactus_destroy  # type: ignore
            cactus_destroy(_MODEL)
        except Exception:
            pass


# ── Entry point ──────────────────────────────────────────────────────────────

def _load_model(model: str):
    global _MODEL, _loaded_model
    from cactus import cactus_init  # type: ignore  # lazy so tests don't need SDK
    model_path = os.environ.get("CACTUS_MODEL_PATH") or resolve_model_path(model)
    if not Path(model_path).exists():
        raise RuntimeError(
            f"Model weights not found at {model_path}. "
            f"Run `cactus run {model}` once to download them."
        )
    log.info(f"loading {model_path} ...")
    # cactus_init(model_path, corpus_dir, cache_index) — corpus is for RAG, off here.
    _MODEL = cactus_init(model_path, None, False)
    _loaded_model = model
    log.info("model loaded")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--model", default="google/gemma-4-E2B-it")
    args = p.parse_args()

    _load_model(args.model)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="info")


if __name__ == "__main__":
    main()
