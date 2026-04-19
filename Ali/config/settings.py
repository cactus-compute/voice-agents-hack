"""
Global configuration.
API keys are loaded from .env in the project root (never commit that file).
"""

import os
from pathlib import Path

# Load .env from project root (silently ignored if file doesn't exist)
try:
    from dotenv import load_dotenv  # type: ignore
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except ImportError:
    pass  # dotenv not installed — fall back to environment variables only

# ── Gemini API (for fast text intent parsing) ─────────────────────────────────
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")

# ── Cactus Cloud API ──────────────────────────────────────────────────────────
CACTUS_API_KEY = os.environ.get("CACTUS_API_KEY", "")

# ── Cactus / Gemma 4 ─────────────────────────────────────────────────────────
CACTUS_GEMMA4_MODEL = "google/gemma-4-E2B-it"

# ── Cactus VL (browser sub-agent) ────────────────────────────────────────────
# The browser sub-agent runs inside a Chrome extension whose LLM is configured
# via chrome.storage.local. scripts/cactus_server.py is the HTTP sidecar the
# extension talks to when provider='cactus'; the AI Studio path (default) is
# used when provider='google'.
CACTUS_VL_MODEL    = os.getenv("CACTUS_VL_MODEL",    "google/gemma-4-E2B-it")
CACTUS_SIDECAR_URL = os.getenv("CACTUS_SIDECAR_URL", "http://127.0.0.1:8765")
AGENT_NODE_BIN     = os.getenv("AGENT_NODE_BIN",     "node")

# ── Whisper fallback ──────────────────────────────────────────────────────────
WHISPER_MODEL_SIZE = "base.en"   # tiny.en | base.en | small.en

# ── Chrome persistent context ─────────────────────────────────────────────────
# macOS default Chrome profile. Change "Default" if you use a different profile.
CHROME_PROFILE_PATH = os.path.expanduser(
    "~/Library/Application Support/Google/Chrome/Default"
)

# ── Push-to-talk hotkey ───────────────────────────────────────────────────────
# Configured in voice/capture.py — keyboard.Key.alt = Option key

# ── Demo safety ────────────────────────────────────────────────────────────────
# When set (1/true/yes), irreversible actions are skipped.
DRY_RUN = os.environ.get("VOICE_AGENT_DRY_RUN", "").lower() in {"1", "true", "yes"}

# ── Vision-first orchestration ─────────────────────────────────────────────────
VISION_FIRST_ENABLED = os.environ.get("VOICE_AGENT_VISION_FIRST", "1").lower() in {"1", "true", "yes"}
VISION_MAX_ACTION_STEPS = int(os.environ.get("VOICE_AGENT_VISION_MAX_ACTION_STEPS", "8"))
VISION_ARTIFACT_DIR = os.path.expanduser(
    os.environ.get("VOICE_AGENT_VISION_ARTIFACT_DIR", "~/tmp/yc_voice_agent_observations")
)

# ── macOS app names ───────────────────────────────────────────────────────────
MESSAGES_APP = "Messages"
MAIL_APP = "Mail"
CALENDAR_APP = "Calendar"
CONTACTS_APP = "Contacts"
