"""Gemma backend wrappers. CURSOR OWNS THIS FILE.

Four backends, all behind the same `GemmaBackend` protocol:

  - LocalCactusBackend   → spawns `cactus run <model>` and pipes prompts in
  - CactusCloudBackend   → POSTs to Cactus Cloud /text (HTTP, X-API-Key)
  - GeminiCloudBackend   → calls Gemini API via google-genai (direct cloud)
  - StubBackend          → deterministic echo, used in CI / when no model present

`auto_attach()` monkey-patches `google.genai.Client.models.generate_content`
so any team using the Gemini SDK gets Masker filtering for free.
"""

from __future__ import annotations

import json
import os
import shutil
import ssl
import subprocess
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Protocol


class GemmaBackend(Protocol):
    name: str

    def generate(self, prompt: str, *, max_tokens: int = 256) -> str: ...


@dataclass
class StubBackend:
    """Deterministic backend used when no model / no API key is available.
    Ensures the integration loop is testable in CI and on plane wifi.
    """

    name: str = "stub"

    def generate(self, prompt: str, *, max_tokens: int = 256) -> str:
        head = prompt.strip().splitlines()[-1] if prompt.strip() else ""
        return f"[stub-gemma reply to] {head[:200]}"


@dataclass
class LocalCactusBackend:
    """Calls the on-device Gemma 4 model via the `cactus` CLI.

    `cactus run --prompt <text>` runs the chat binary in single-shot mode:
    it loads the model, generates one response, and exits. We send an empty
    stdin line to satisfy the one-time Cactus Cloud key prompt without
    requiring `cactus auth` to have been run first.

    Each call shells out and pays the model-load cost (~0.5s warm). A
    persistent FFI binding is a Phase-2 latency win.
    """

    model: str = "google/functiongemma-270m-it"
    cactus_bin: str = "cactus"
    timeout_s: float = 60.0
    system_prompt: str | None = None
    name: str = "cactus-local"

    def generate(self, prompt: str, *, max_tokens: int = 256) -> str:
        if not shutil.which(self.cactus_bin):
            raise RuntimeError(
                f"`{self.cactus_bin}` not on PATH. Activate the cactus venv: "
                f"`source cactus/venv/bin/activate`."
            )
        cmd = [self.cactus_bin, "run", self.model, "--prompt", prompt]
        if self.system_prompt:
            cmd += ["--system", self.system_prompt]
        try:
            proc = subprocess.run(
                cmd,
                input="\n",
                text=True,
                capture_output=True,
                timeout=self.timeout_s,
            )
        except subprocess.TimeoutExpired:
            return "[masker] Local model timed out."
        if proc.returncode != 0:
            return f"[masker] cactus run failed: {proc.stderr[:200].strip()}"
        return _extract_assistant_reply(proc.stdout)


@dataclass
class CactusCloudBackend:
    """Cloud handoff via Cactus Cloud's `/text` endpoint.

    Used when the local cactus CLI isn't available but the policy still says
    `safe-to-send` (or `masked-send` after detection has rewritten the
    prompt). This is the same hosted endpoint that `cactus run` falls back
    to when CACTUS_CLOUD_KEY is set, just reached over plain HTTPS so we
    don't need the cactus binary on PATH.

    Schema (confirmed against api/v1/text):
        POST  https://<host>/api/v1/text
        Hdr   X-API-Key: <key>
        Body  {"text": "...", "model": "gemini-2.5-flash"}
        Resp  {"text": "...", "duration_ms": 0, "model": "...", ...}

    The default endpoint matches the IP literal hardcoded in
    cactus/cactus/ffi/cactus_cloud.cpp (self-signed cert → SSL verify off
    by default, override with CACTUS_CLOUD_STRICT_SSL=1).
    """

    model: str = "gemini-2.5-flash"
    api_key_env: str = "CACTUS_CLOUD_KEY"
    endpoint: str = field(
        default_factory=lambda: os.environ.get(
            "CACTUS_CLOUD_ENDPOINT", "https://104.198.76.3/api/v1/text"
        )
    )
    timeout_s: float = 30.0
    name: str = "cactus-cloud"

    def generate(self, prompt: str, *, max_tokens: int = 256) -> str:
        api_key = os.environ.get(self.api_key_env) or os.environ.get(
            "CACTUS_CLOUD_API_KEY"
        )
        if not api_key:
            raise RuntimeError(
                f"{self.api_key_env} not set. Export your Cactus Cloud key "
                "(see .env.example) or pick a different backend."
            )
        payload = json.dumps({"text": prompt, "model": self.model}).encode("utf-8")
        req = urllib.request.Request(
            self.endpoint,
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-API-Key": api_key,
            },
        )
        ctx: ssl.SSLContext | None = None
        if not os.environ.get("CACTUS_CLOUD_STRICT_SSL"):
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_s, context=ctx) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:200]
            return f"[masker] cactus-cloud HTTP {exc.code}: {detail}"
        except (urllib.error.URLError, TimeoutError) as exc:
            return f"[masker] cactus-cloud unreachable: {exc}"
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return body.strip()
        return str(data.get("text", "")).strip() or body.strip()


@dataclass
class GeminiCloudBackend:
    """Cloud fallback. Used when policy says `safe-to-send` and the local
    model's confidence is low, or when the caller explicitly wants Gemini.
    """

    model: str = "gemini-2.0-flash"
    api_key_env: str = "GEMINI_API_KEY"
    name: str = "gemini-cloud"

    def generate(self, prompt: str, *, max_tokens: int = 256) -> str:
        api_key = os.environ.get(self.api_key_env)
        if not api_key:
            raise RuntimeError(
                f"{self.api_key_env} not set. Export your Gemini API key or use a different backend."
            )
        try:
            from google import genai  # type: ignore[import-not-found]
        except ImportError as exc:  # pragma: no cover
            raise RuntimeError("`pip install google-genai` to use the cloud backend.") from exc

        client = genai.Client(api_key=api_key)
        response = client.models.generate_content(model=self.model, contents=prompt)
        return getattr(response, "text", str(response))


def _extract_assistant_reply(stdout: str) -> str:
    """Pull just the model's reply out of the chat binary's mixed stdout.

    Layout of `cactus run --prompt`:
        ...banner / model load logs...
        You: <prompt>
        Assistant: <reply line 1>
        <reply line 2>
        ...
        [N tokens | latency: ... | total: ... | RAM: ...]
        ...

    We grab everything between `Assistant:` and the metrics line that starts
    with `[`. Falls back to a chrome-stripping pass if the markers are absent.
    """
    marker = "Assistant:"
    if marker in stdout:
        tail = stdout.split(marker, 1)[1]
        reply_lines: list[str] = []
        for line in tail.splitlines():
            stripped = line.strip()
            if stripped.startswith("[") and "tokens" in stripped:
                break
            reply_lines.append(line)
        reply = "\n".join(reply_lines).strip()
        if reply:
            return reply

    drop_prefixes = ("cactus", ">", "loading", "Loading", "[", "═", "─", "You:", "👋")
    cleaned = [
        ln for ln in stdout.splitlines()
        if ln.strip() and not ln.strip().startswith(drop_prefixes)
    ]
    return "\n".join(cleaned).strip() or stdout.strip()


def default_backend() -> GemmaBackend:
    """Pick the best available backend based on environment.

    Priority:
      1. cactus CLI on PATH                        → LocalCactusBackend
      2. CACTUS_CLOUD_KEY (or _API_KEY) exported   → CactusCloudBackend
      3. GEMINI_API_KEY exported                   → GeminiCloudBackend
      4. fallback                                  → StubBackend

    Cactus Cloud is preferred over direct Gemini because it's the same
    hosted endpoint the cactus binary uses, so the demo behaves the same
    way on a laptop with the binary as it does on one without.
    """
    if shutil.which("cactus"):
        return LocalCactusBackend()
    if os.environ.get("CACTUS_CLOUD_KEY") or os.environ.get("CACTUS_CLOUD_API_KEY"):
        return CactusCloudBackend()
    if os.environ.get("GEMINI_API_KEY"):
        return GeminiCloudBackend()
    return StubBackend()


def auto_attach(
    *,
    backend: GemmaBackend | None = None,
    on_filter: Callable[[str, str], None] | None = None,
) -> None:
    """Monkey-patch the google-genai client so any caller transparently
    routes through Masker's input/output filters.

    Usage in another team's code:

        from masker import auto_attach
        auto_attach()
        # ...their existing google-genai calls now get filtered for free.
    """
    from . import filter_input, filter_output  # local import to avoid cycle

    try:
        from google.genai import models as _gm  # type: ignore[import-not-found]
    except ImportError:  # pragma: no cover
        raise RuntimeError("google-genai not installed; cannot auto_attach().")

    original = _gm.Models.generate_content

    def patched(self, *, model, contents, **kwargs):  # type: ignore[no-untyped-def]
        prompt = contents if isinstance(contents, str) else str(contents)
        safe_prompt, _md = filter_input(prompt)
        if on_filter:
            on_filter(prompt, safe_prompt)
        result = original(self, model=model, contents=safe_prompt, **kwargs)
        result_text = getattr(result, "text", None)
        if result_text:
            safe_text = filter_output(result_text)
            try:
                result.text = safe_text  # type: ignore[attr-defined]
            except Exception:
                pass
        return result

    _gm.Models.generate_content = patched  # type: ignore[assignment]
