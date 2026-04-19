"""
Global configuration.
API keys are loaded from .env in the project root (never commit that file --- Alspencer --- I know claude--- don't leak your source code next time).
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

# ── Deepgram API (real-time streaming STT for meeting capture) ────────────────
DEEPGRAM_API_KEY = os.environ.get("DEEPGRAM_API_KEY", "")

# ── Cactus Cloud API ──────────────────────────────────────────────────────────
CACTUS_API_KEY = os.environ.get("CACTUS_API_KEY", "")

# ── Cactus / Gemma 4 ─────────────────────────────────────────────────────────
CACTUS_GEMMA4_MODEL = "google/gemma-4-E2B-it"
# CACTUS_GEMMA4_MODEL = "google/functiongemma-270m-it"

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

# ── File resolver ─────────────────────────────────────────────────────────────
# Local-only resolver that turns natural-language transcripts into concrete
# file paths using Spotlight (mdfind) + Cactus-proposed predicates.

def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "1" if default else "0")
    return raw.lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return default


def _parse_search_roots(raw: str) -> list[Path]:
    roots: list[Path] = []
    seen: set[str] = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item:
            continue
        try:
            resolved = Path(item).expanduser().resolve()
        except OSError:
            continue
        key = str(resolved)
        if key in seen:
            continue
        if not resolved.exists() or not resolved.is_dir():
            continue
        seen.add(key)
        roots.append(resolved)
    return roots


FILE_RESOLVER_ENABLED = _env_bool("VOICE_AGENT_FILE_RESOLVER", True)
FILE_RESOLVER_ALIAS_FIRST = _env_bool("VOICE_AGENT_FILE_RESOLVER_ALIAS_FIRST", True)
FILE_RESOLVER_USE_SPOTLIGHT = _env_bool("VOICE_AGENT_USE_SPOTLIGHT", True)

FILE_SEARCH_ROOTS: list[Path] = _parse_search_roots(
    os.environ.get(
        "VOICE_AGENT_FILE_SEARCH_ROOTS",
        "~/Desktop,~/Documents,~/Downloads",
    )
)

FILE_PREDICATE_MAX_ROUNDS = _env_int("VOICE_AGENT_FILE_PREDICATE_MAX_ROUNDS", 2)
FILE_MDFIND_MAX_RESULTS = _env_int("VOICE_AGENT_FILE_MDFIND_MAX_RESULTS", 40)
FILE_INDEX_MAX_CHARS = _env_int("VOICE_AGENT_FILE_INDEX_MAX_CHARS", 2000)
FILE_WALK_MAX_FILES = _env_int("VOICE_AGENT_FILE_WALK_MAX_FILES", 500)
FILE_WALK_MAX_DEPTH = _env_int("VOICE_AGENT_FILE_WALK_MAX_DEPTH", 4)

FILE_RESOLVE_DEBUG = _env_bool("VOICE_AGENT_FILE_RESOLVE_DEBUG", False)

# ── Disk index (laptop-wide content + embeddings) ────────────────────────────
# Local-first retrieval-augmented Q&A over the user's files + macOS data.
# Default is a focused scope: the three docs folders, /Applications, plus
# Contacts / Calendar / Messages. Set ALI_INDEX_FULL_DISK=1 (or pass
# `--full-disk` on the CLI) for a full home-directory scan.

INDEX_DIR: Path = Path(os.path.expanduser(
    os.environ.get("ALI_INDEX_DIR", "~/.cache/ali/index")
))

INDEX_FULL_DISK = _env_bool("ALI_INDEX_FULL_DISK", False)

_DEFAULT_SCAN_ROOTS = "~/Documents,~/Downloads,~/Desktop,/Applications"
_FULL_DISK_ROOTS = "~,/Applications"

INDEX_SCAN_ROOTS: list[Path] = _parse_search_roots(
    os.environ.get(
        "ALI_INDEX_SCAN_ROOTS",
        _FULL_DISK_ROOTS if INDEX_FULL_DISK else _DEFAULT_SCAN_ROOTS,
    )
)

INDEX_MAX_FILE_BYTES = _env_int("ALI_INDEX_MAX_FILE_BYTES", 5_000_000)
INDEX_EMBED_MODEL = os.environ.get(
    "ALI_INDEX_EMBED_MODEL", "sentence-transformers/all-MiniLM-L6-v2"
)
INDEX_CHUNK_TOKENS = _env_int("ALI_INDEX_CHUNK_TOKENS", 400)
INDEX_ENABLE_EMBEDDINGS = _env_bool("ALI_INDEX_EMBEDDINGS", True)

# Comma-separated list of non-filesystem data sources to index alongside the
# filesystem walk. Each entry names a module under
# `executors/local/disk_index/sources/`. Set to "" to disable all of them.
INDEX_SOURCES: list[str] = [
    name.strip().lower()
    for name in os.environ.get(
        "ALI_INDEX_SOURCES", "contacts,calendar,messages"
    ).split(",")
    if name.strip()
]

# How far back to go when indexing time-ordered sources (Messages, Calendar).
INDEX_SOURCE_HISTORY_DAYS = _env_int("ALI_INDEX_SOURCE_HISTORY_DAYS", 365)

# Local-first RAG. Default: 100% on-device via Cactus/Gemma 4. Set to 1 to
# allow falling back to Gemini if Cactus is unavailable for answer generation.
ALI_ALLOW_CLOUD_FALLBACK = _env_bool("ALI_ALLOW_CLOUD_FALLBACK", False)
