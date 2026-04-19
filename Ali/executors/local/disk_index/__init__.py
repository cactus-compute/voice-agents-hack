"""
Public API for the Ali disk index.

Everything the rest of the agent needs — "does the index exist?", "find
files matching X", "answer this question from disk context" — funnels
through these helpers. They lazy-load the underlying SQLite + hnswlib +
MiniLM components, so importing this module is cheap.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

from . import answer as _answer_mod
from . import embed as _embed
from . import profile as _profile
from . import retrieve as _retrieve
from . import store as _store
from .answer import AnswerResult
from .retrieve import FileHit, Hit, IndexHandle
from .store import IndexStats

__all__ = [
    "AnswerResult",
    "FileHit",
    "Hit",
    "IndexStats",
    "answer_question",
    "get_user_profile",
    "index_exists",
    "index_is_complete",
    "index_needs_resume",
    "index_stats",
    "reset_handle",
    "retrieve_context",
    "search_content",
    "search_files",
    "warmup_embedder",
]


def _index_dir() -> Path:
    from config.settings import INDEX_DIR

    return Path(INDEX_DIR)


def _embed_model() -> str:
    from config.settings import INDEX_EMBED_MODEL

    return INDEX_EMBED_MODEL


def _cactus_model() -> str:
    from config.settings import CACTUS_GEMMA4_MODEL

    return CACTUS_GEMMA4_MODEL


def _cloud_fallback_enabled() -> bool:
    from config.settings import ALI_ALLOW_CLOUD_FALLBACK

    return bool(ALI_ALLOW_CLOUD_FALLBACK)


def _gemini_key() -> str | None:
    from config.settings import GEMINI_API_KEY

    return GEMINI_API_KEY or None


def index_exists() -> bool:
    db_path = _index_dir() / "index.db"
    if not db_path.exists():
        return False
    try:
        conn = _store.connect(db_path, create=False)
    except Exception:
        return False
    try:
        stats = _store.stats(conn)
        return stats.files > 0
    finally:
        conn.close()


def index_is_complete() -> bool:
    """Return True when the on-disk index reflects a fully-finished build.

    We treat a build as "complete" when:
      * `manifest.built_at` is set (only written at the end of `run_build`),
      * every chunk has an embedding (when embeddings are enabled),
      * `vectors.bin` + `vectors_meta.json` exist (when embeddings are enabled),
      * `profile.json` exists.
    Any missing piece means a previous build was interrupted; the caller
    should resume rather than skip.
    """
    from config.settings import INDEX_ENABLE_EMBEDDINGS

    index_dir = _index_dir()
    db_path = index_dir / "index.db"
    if not db_path.exists():
        return False
    try:
        conn = _store.connect(db_path, create=False)
    except Exception:
        return False
    try:
        stats = _store.stats(conn)
        if stats.built_at is None or stats.files <= 0:
            return False
        if INDEX_ENABLE_EMBEDDINGS:
            missing = _store.count_chunks_needing_embedding(conn)
            if missing > 0:
                return False
            if not (index_dir / "vectors.bin").exists():
                return False
            if not (index_dir / "vectors_meta.json").exists():
                return False
    finally:
        conn.close()
    if not (index_dir / "profile.json").exists():
        return False
    return True


def index_needs_resume() -> bool:
    """True when there's a partial index on disk that a future `run_build`
    would pick up incrementally."""
    return index_exists() and not index_is_complete()


def index_stats() -> IndexStats | None:
    db_path = _index_dir() / "index.db"
    if not db_path.exists():
        return None
    try:
        conn = _store.connect(db_path, create=False)
    except Exception:
        return None
    try:
        return _store.stats(conn)
    finally:
        conn.close()


def get_user_profile() -> dict[str, Any] | None:
    return _profile.load_profile(_index_dir() / "profile.json")


def search_files(query: str, *, limit: int = 20) -> list[FileHit]:
    handle = _retrieve.get_handle(_index_dir())
    if handle is None:
        return []
    return handle.search_files(query, limit=limit)


def search_content(query: str, *, k: int = 6) -> list[Hit]:
    handle = _retrieve.get_handle(_index_dir())
    if handle is None:
        return []
    return handle.search_content(query, k=k)


def retrieve_context(query: str, *, k: int = 6) -> list[Hit]:
    """Alias for `search_content`; kept for plan/API parity."""
    return search_content(query, k=k)


async def answer_question(
    transcript: str,
    *,
    k: int = 6,
) -> AnswerResult:
    """RAG answer over the local index. Gemma 4 (Cactus) is primary."""
    hits = search_content(transcript, k=k)
    profile = get_user_profile()
    return await _answer_mod.answer_question(
        transcript,
        profile=profile,
        hits=hits,
        cactus_model=_cactus_model(),
        allow_cloud_fallback=_cloud_fallback_enabled(),
        gemini_key=_gemini_key(),
    )


def warmup_embedder() -> None:
    """Load the MiniLM encoder eagerly (safe to call from a background thread)."""
    try:
        _embed.warmup(_embed_model())
    except Exception as exc:
        print(f"[disk-index] warmup failed: {exc}")


def reset_handle() -> None:
    """Force the next query to reopen the DB (call after a rebuild)."""
    _retrieve.reset_handle()
