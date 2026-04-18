"""Route execution. CURSOR OWNS THIS FILE.

Given a PolicyDecision, decide what actually happens with the request:

  - local-only   → answer locally with the on-device model only, never touches cloud
  - masked-send  → forward the masked text to the chosen backend (could be cloud)
  - safe-to-send → forward verbatim to the chosen backend

The router is intentionally side-effect free except for calling the backend;
the trace is appended via the supplied Tracer.
"""

from __future__ import annotations

from dataclasses import dataclass

from .contracts import MaskedText, PolicyDecision
from .gemma_wrapper import GemmaBackend, LocalCactusBackend, StubBackend
from .trace import Tracer


@dataclass
class Router:
    local_backend: GemmaBackend
    cloud_backend: GemmaBackend | None = None

    def execute(
        self,
        *,
        original_text: str,
        masked: MaskedText,
        decision: PolicyDecision,
        tracer: Tracer,
    ) -> str:
        if decision.route == "local-only":
            backend = self.local_backend
            prompt = original_text
        elif decision.route == "masked-send":
            backend = self.cloud_backend or self.local_backend
            prompt = masked.text
        elif decision.route == "safe-to-send":
            backend = self.cloud_backend or self.local_backend
            prompt = original_text
        else:
            raise ValueError(f"Unknown route: {decision.route}")

        with tracer.span(
            "llm",
            f"{backend.name} via route={decision.route}",
            backend=backend.name,
            route=decision.route,
            prompt_chars=len(prompt),
        ):
            try:
                return backend.generate(prompt)
            except Exception as exc:  # noqa: BLE001
                tracer.event(
                    "llm",
                    f"backend error, falling back to stub: {exc}",
                    backend=backend.name,
                )
                return StubBackend().generate(prompt)


def default_router() -> Router:
    """Local-first router. Cloud backend is wired only if its credentials
    are present; otherwise everything stays local.
    """
    from .gemma_wrapper import GeminiCloudBackend, default_backend
    import os

    cloud = GeminiCloudBackend() if os.environ.get("GEMINI_API_KEY") else None
    local = default_backend() if not cloud else LocalCactusBackend()
    return Router(local_backend=local, cloud_backend=cloud)
