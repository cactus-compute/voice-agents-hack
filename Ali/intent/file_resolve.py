"""
Layer 2 — Intent file resolver.

Turns a natural-language transcript + parsed intent into concrete local file
paths using a rules-first loop around macOS Spotlight (`mdfind`) predicates
proposed by Cactus / Gemma 4. Local-only by design — never calls cloud LLMs.

Output shape:
  intent.slots["resolved_local_files"]: dict[str, str]  # role -> absolute path
  intent.slots["resume_path"]: str                      # derived for backcompat

Per-role exit priority (fastest first):
  1. `intent.slots["resume_path"]` already set and readable (resume role only).
  2. `FILE_ALIASES` hit for the role.
  3. Cactus proposes a predicate -> mdfind -> rules gate (single/refine/pick).
  4. Bounded filesystem walk fallback + final picker.

Observability: every phase emits a one-line `[file-resolve]` event with
`event`, `timings_ms`, `counts`, `role`, and an `exit_reason` from a fixed
enum. Full paths and raw predicates are gated behind `FILE_RESOLVE_DEBUG`.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from config.resources import FILE_ALIASES
from config.settings import (
    CACTUS_GEMMA4_MODEL,
    FILE_INDEX_MAX_CHARS,
    FILE_MDFIND_MAX_RESULTS,
    FILE_PREDICATE_MAX_ROUNDS,
    FILE_RESOLVE_DEBUG,
    FILE_RESOLVER_ALIAS_FIRST,
    FILE_RESOLVER_ENABLED,
    FILE_RESOLVER_USE_SPOTLIGHT,
    FILE_SEARCH_ROOTS,
    FILE_WALK_MAX_DEPTH,
    FILE_WALK_MAX_FILES,
)
from executors.local.file_index import bounded_walk, run_mdfind, validate_predicate
from intent.schema import IntentObject, KnownGoal

# Max candidate lines we put in a single prompt. Spotlight's native ranking
# order is preserved — the first `_MAX_PICK_CANDIDATES` results are shown to
# Cactus verbatim as the "top K" candidates to choose from or abstain on.
_MAX_PICK_CANDIDATES = 12

# Roles that map to FILE_ALIASES entries when present.
_ALIAS_ROLES = {"resume", "cover_letter"}

# Tags in uses_local_data that imply a file role with the same name.
_LOCAL_ROLE_TAGS = {"resume", "cover_letter", "attachment", "document", "deck"}

CACTUS_CLI = shutil.which("cactus")


@dataclass(frozen=True)
class _PickResult:
    """Outcome of a single Cactus pick call.

    - `chosen` is the resolved `Path` when Cactus selected a valid candidate.
    - `abstain_reason` is set iff `chosen is None` and indicates why the loop
      should refine instead of failing outright (e.g. "null", "low_confidence",
      "out_of_set", "out_of_roots", "no_response").
    """

    chosen: Path | None
    abstain_reason: str | None

_MD_CHEAT_SHEET = (
    "Spotlight MDQuery attributes you can use:\n"
    "- kMDItemDisplayName, kMDItemFSName (filename)\n"
    "- kMDItemContentTypeTree (e.g. \"com.adobe.pdf\", \"public.image\")\n"
    "- kMDItemTextContent (indexed body text)\n"
    "- kMDItemFSCreationDate, kMDItemFSContentChangeDate\n"
    "Use simple expressions such as: kMDItemFSName == \"*resume*\"c\n"
    "Combine with && and ||; quote literals. No shell metacharacters."
)


# ─── Public entrypoint ────────────────────────────────────────────────────────


async def enrich_intent_with_resolved_files(intent: IntentObject, transcript: str) -> None:
    """
    Mutates `intent.slots` in place, populating a role-keyed map of resolved
    absolute file paths under `slots["resolved_local_files"]`, plus
    `slots["resume_path"]` (derived) for backcompat with YC Apply wiring.

    Idempotent: returns immediately if resolution has already run this intent.
    """
    if not FILE_RESOLVER_ENABLED:
        _emit("exit", exit_reason="disabled", outcome="skipped")
        return

    if intent.slots.get("resolved_local_files"):
        _emit("exit", exit_reason="already_resolved", outcome="skipped")
        return

    roles = _roles_for_intent(intent)
    if not roles:
        _emit("exit", exit_reason="no_task", outcome="skipped")
        return

    resolved: dict[str, str] = {}
    for role in roles:
        state = _ResolverState(role=role)
        path = await _resolve_role(intent, transcript, role, state)
        if path is not None:
            resolved[role] = str(path)

    intent.slots["resolved_local_files"] = resolved
    if "resume" in resolved:
        intent.slots.setdefault("resume_path", resolved["resume"])

    _emit(
        "summary",
        roles_requested=len(roles),
        roles_resolved=len(resolved),
        roles=list(resolved.keys()),
    )


# ─── Per-role pipeline ────────────────────────────────────────────────────────


async def _resolve_role(
    intent: IntentObject,
    transcript: str,
    role: str,
    state: "_ResolverState",
) -> Path | None:
    try:
        alias_for_found = _alias_for_found_query(intent, role, transcript, state)
        if alias_for_found is not None:
            return alias_for_found

        early = _early_exit_slot_valid(intent, role, state)
        if early is not None:
            return early

        if FILE_RESOLVER_ALIAS_FIRST:
            aliased = _alias_first(role, state)
            if aliased is not None:
                return aliased

        indexed = _disk_index_first(intent, transcript, role, state)
        if indexed is not None:
            return indexed

        if not CACTUS_CLI:
            if FILE_RESOLVER_USE_SPOTLIGHT:
                chosen = await _naive_mdfind_fallback(intent, role, state)
                if chosen is not None:
                    _finalize(
                        state,
                        exit_reason="naive_picked",
                        outcome="success",
                        slot=role,
                        basename=chosen.name,
                    )
                    return chosen
            chosen = await _walk_fallback(intent, transcript, role, state)
            if chosen is not None:
                _finalize(
                    state,
                    exit_reason="walk_only",
                    outcome="success",
                    slot=role,
                    basename=chosen.name,
                )
                return chosen
            _finalize(state, exit_reason="no_cactus", outcome="failure")
            return None

        if FILE_RESOLVER_USE_SPOTLIGHT:
            chosen = await _cactus_predicate_loop(intent, transcript, role, state)
            if chosen is not None:
                _finalize(
                    state,
                    exit_reason="picked",
                    outcome="success",
                    slot=role,
                    basename=chosen.name,
                )
                return chosen

        chosen = await _walk_fallback(intent, transcript, role, state)
        if chosen is not None:
            _finalize(
                state,
                exit_reason="walk_only",
                outcome="success",
                slot=role,
                basename=chosen.name,
            )
            return chosen

        exit_reason = "abstained" if state.last_round_abstained else "max_rounds"
        _finalize(state, exit_reason=exit_reason, outcome="failure")
        return None
    except Exception as exc:  # pragma: no cover - defensive
        _emit(
            "error",
            role=role,
            detail=str(exc)[:120],
            timings_ms=state.timings_snapshot(),
        )
        _finalize(state, exit_reason="error", outcome="failure")
        return None


def _disk_index_first(
    intent: IntentObject,
    transcript: str,
    role: str,
    state: "_ResolverState",
) -> Path | None:
    """Try the pre-built laptop-wide SQLite/FTS index before falling through to
    Spotlight + Cactus. Uses filename + content hits ranked by FTS5 BM25.

    We only accept the top hit if its basename shares a term with the query —
    otherwise we prefer the slower Cactus/Spotlight path that can reason about
    synonyms ("resume" ↔ "CV"). The alias path above already handles those
    common cases, so we don't need Cactus to synthesise them here.
    """
    try:
        from executors.local.disk_index import index_exists, search_files
    except Exception:
        return None
    if not index_exists():
        return None
    query = _query_for_role(intent, role, transcript)
    if not query or len(query.strip()) < 2:
        return None
    try:
        hits = search_files(query, limit=12)
    except Exception as exc:
        _emit("disk_index", role=role, result="error", detail=str(exc)[:120])
        return None
    if not hits:
        return None
    # Synthetic data-source hits (Contacts / Calendar / Messages) live under
    # the ``ali://`` scheme; they're useful for RAG answers but can't be
    # revealed in Finder, so drop them from the file-reveal candidate list.
    hits = [h for h in hits if not h.path.startswith("ali://")]
    if not hits:
        return None
    q_terms = {t for t in re.split(r"[^A-Za-z0-9]+", query.lower()) if len(t) >= 3}
    preferred, penalised = _preferred_extensions(role, query)
    scored: list[tuple[Path, tuple]] = []
    for h in hits:
        name_terms = {t for t in re.split(r"[^A-Za-z0-9]+", h.name.lower()) if t}
        if q_terms and not q_terms.intersection(name_terms):
            continue
        p = Path(h.path)
        scored.append((p, _rank_candidate(p, preferred, penalised, query)))
    if not scored:
        return None
    scored.sort(key=lambda kv: kv[1])
    best = scored[0][0]
    try:
        if not best.exists():
            return None
    except OSError:
        return None
    _emit(
        "disk_index",
        role=role,
        result="hit",
        basename=best.name,
        candidates=len(hits),
    )
    _finalize(
        state,
        exit_reason="disk_index_hit",
        outcome="success",
        slot=role,
        basename=best.name,
    )
    return best


def _alias_for_found_query(
    intent: IntentObject,
    role: str,
    transcript: str,
    state: "_ResolverState",
) -> Path | None:
    """
    Fast path: for generic find_file role='found', map common queries like
    "resume" / "cover letter" onto FILE_ALIASES immediately.
    """
    if role != "found":
        return None
    query = _query_for_role(intent, role, transcript).lower()
    # Wake phrases often arrive truncated to "open my". In that case, default
    # to resume alias so "Ali open my resume" still resolves on the first try.
    if not query.strip() or query.strip() in {"open my", "find my", "show my", "locate my"}:
        raw_resume = FILE_ALIASES.get("resume")
        if raw_resume:
            expanded_resume = os.path.expanduser(raw_resume)
            if os.path.isfile(expanded_resume):
                _emit("alias", role=role, mapped_from="resume_default", result="hit", basename=os.path.basename(expanded_resume))
                _finalize(
                    state,
                    exit_reason="alias_hit_default_resume",
                    outcome="success",
                    slot=role,
                    basename=os.path.basename(expanded_resume),
                )
                return Path(expanded_resume)
    alias_key: str | None = None
    if "resume" in query or "cv" in query:
        alias_key = "resume"
    elif "cover letter" in query or "coverletter" in query:
        alias_key = "cover_letter"
    if not alias_key:
        return None
    raw = FILE_ALIASES.get(alias_key)
    if not raw:
        return None
    expanded = os.path.expanduser(raw)
    if not os.path.isfile(expanded):
        _emit("alias", role=role, mapped_from=alias_key, result="missing_file")
        return None
    _emit("alias", role=role, mapped_from=alias_key, result="hit", basename=os.path.basename(expanded))
    _finalize(
        state,
        exit_reason="alias_hit",
        outcome="success",
        slot=role,
        basename=os.path.basename(expanded),
    )
    return Path(expanded)


def _early_exit_slot_valid(
    intent: IntentObject,
    role: str,
    state: "_ResolverState",
) -> Path | None:
    if role != "resume":
        return None
    current = intent.slots.get("resume_path")
    if not isinstance(current, str) or not current:
        return None
    expanded = os.path.expanduser(current)
    if os.path.isfile(expanded) and os.access(expanded, os.R_OK):
        _finalize(
            state,
            exit_reason="skipped_slot_path",
            outcome="success",
            slot=role,
            basename=os.path.basename(expanded),
        )
        return Path(expanded)
    return None


def _alias_first(role: str, state: "_ResolverState") -> Path | None:
    if role not in _ALIAS_ROLES:
        return None
    raw = FILE_ALIASES.get(role)
    if not raw:
        _emit("alias", role=role, result="miss")
        return None
    expanded = os.path.expanduser(raw)
    if not os.path.isfile(expanded):
        _emit("alias", role=role, result="missing_file")
        return None
    _emit("alias", role=role, result="hit", basename=os.path.basename(expanded))
    _finalize(
        state,
        exit_reason="alias_hit",
        outcome="success",
        slot=role,
        basename=os.path.basename(expanded),
    )
    return Path(expanded)


async def _cactus_predicate_loop(
    intent: IntentObject,
    transcript: str,
    role: str,
    state: "_ResolverState",
) -> Path | None:
    roots = list(FILE_SEARCH_ROOTS)
    if not roots:
        _emit("round", role=role, detail="no_search_roots")
        return None

    previous: list[dict[str, Any]] = []
    state.last_round_abstained = False

    for round_idx in range(max(FILE_PREDICATE_MAX_ROUNDS, 1)):
        state.predicate_rounds_used = round_idx + 1
        prompt = _build_predicate_prompt(
            intent=intent,
            transcript=transcript,
            role=role,
            roots=roots,
            previous=previous,
        )
        proposal = await _cactus_json(prompt, state)
        predicate_raw = str(proposal.get("predicate", "")) if proposal else ""
        predicate = validate_predicate(predicate_raw)
        root_idx_raw = proposal.get("only_in_root_index", 0) if proposal else 0
        try:
            root_idx = int(root_idx_raw)
        except (TypeError, ValueError):
            root_idx = 0
        if root_idx < 0 or root_idx >= len(roots):
            root_idx = 0

        if predicate is None:
            _emit(
                "round",
                role=role,
                round_index=round_idx,
                rule_decision="validation_failed",
                only_in_root_index=root_idx,
            )
            previous.append({"predicate": predicate_raw, "count": 0, "note": "invalid"})
            state.last_round_abstained = False
            continue

        mdfind_started = time.perf_counter()
        state.mdfind_calls += 1
        candidates = await run_mdfind(predicate, roots[root_idx], FILE_MDFIND_MAX_RESULTS)
        state.mdfind_total += time.perf_counter() - mdfind_started
        state.last_result_count = len(candidates)

        _emit(
            "mdfind",
            role=role,
            round_index=round_idx,
            only_in_root_index=root_idx,
            predicate_chars=len(predicate),
            result_count=len(candidates),
            **_debug_fields(predicate=predicate),
        )

        if not candidates:
            _emit(
                "round",
                role=role,
                round_index=round_idx,
                rule_decision="refine",
                result_count=0,
            )
            previous.append(
                {"predicate": predicate_raw, "count": 0, "note": "empty"}
            )
            state.last_round_abstained = False
            continue

        trimmed = candidates[:_MAX_PICK_CANDIDATES]
        pick_result = await _cactus_final_pick(
            intent, transcript, role, trimmed, roots, state
        )
        if pick_result.chosen is not None:
            _emit(
                "round",
                role=role,
                round_index=round_idx,
                rule_decision="pick",
                result_count=len(candidates),
            )
            return pick_result.chosen

        _emit(
            "round",
            role=role,
            round_index=round_idx,
            rule_decision="refine_after_abstain",
            result_count=len(candidates),
            abstain_reason=pick_result.abstain_reason or "abstained",
        )
        previous.append(
            {
                "predicate": predicate_raw,
                "count": len(candidates),
                "basenames": [c.name for c in trimmed],
                "note": pick_result.abstain_reason or "abstained",
            }
        )
        state.last_round_abstained = True

    return None


_NAIVE_STOPWORDS = {
    "find", "my", "the", "a", "an", "where", "is", "open", "show",
    "me", "reveal", "locate", "please", "can", "you", "file", "files",
    "attach", "attachment", "email", "mail", "send", "to", "of", "on",
    "and", "or", "pdf", "doc", "docx",
}

_DOCUMENT_EXTS = (".pdf", ".docx", ".doc", ".pages", ".rtf", ".txt", ".md")
_SPREADSHEET_EXTS = (".xlsx", ".xls", ".numbers", ".csv")
_SLIDES_EXTS = (".pptx", ".ppt", ".key")
_IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".svg", ".tiff", ".bmp", ".ico")
_MEDIA_EXTS = (".mp4", ".mov", ".m4a", ".mp3", ".wav", ".mkv", ".webm", ".avi")


def _preferred_extensions(role: str, query: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Return (preferred, penalised) extension lists for this role/query."""
    q = (query or "").lower()
    if role == "deck" or any(w in q for w in ("deck", "presentation", "slides", "keynote")):
        preferred = _SLIDES_EXTS + _DOCUMENT_EXTS
        penalised = _IMAGE_EXTS + _MEDIA_EXTS
    elif any(w in q for w in ("spreadsheet", "excel", "csv", "numbers")):
        preferred = _SPREADSHEET_EXTS + _DOCUMENT_EXTS
        penalised = _IMAGE_EXTS + _MEDIA_EXTS
    elif any(w in q for w in ("image", "photo", "picture", "icon", "logo", "screenshot")):
        preferred = _IMAGE_EXTS
        penalised = ()
    elif any(w in q for w in ("video", "movie", "recording", "clip")):
        preferred = _MEDIA_EXTS
        penalised = ()
    else:
        preferred = _DOCUMENT_EXTS + _SPREADSHEET_EXTS + _SLIDES_EXTS
        penalised = _IMAGE_EXTS + _MEDIA_EXTS
    return preferred, penalised


def _rank_candidate(
    path: Path,
    preferred: tuple[str, ...],
    penalised: tuple[str, ...],
    query: str,
) -> tuple:
    ext = path.suffix.lower()
    if ext in preferred:
        ext_rank = preferred.index(ext)
    elif ext in penalised:
        ext_rank = 1000 + penalised.index(ext)
    else:
        ext_rank = 500
    name = path.stem.lower()
    q = (query or "").lower().strip()
    if not q:
        exact_rank = 2
    elif name == q:
        exact_rank = 0
    elif q in name:
        exact_rank = 1
    else:
        exact_rank = 2
    try:
        mtime = path.stat().st_mtime
    except OSError:
        mtime = 0.0
    return (ext_rank, exact_rank, -mtime, len(path.name), str(path))


def _query_for_role(intent: IntentObject, role: str, transcript: str) -> str:
    query = intent.slots.get("file_query") if isinstance(intent.slots, dict) else None
    if isinstance(query, str) and query.strip():
        return query.strip()
    if role in {"resume", "cover_letter", "attachment", "document", "deck"}:
        return role
    return transcript


async def _naive_mdfind_fallback(
    intent: IntentObject,
    role: str,
    state: "_ResolverState",
) -> Path | None:
    """Build a best-effort mdfind predicate without Cactus, using the
    `file_query` slot (and role hint) as the search seed."""
    roots = list(FILE_SEARCH_ROOTS)
    if not roots:
        return None

    query = _query_for_role(intent, role, intent.raw_transcript)
    terms = [
        term.lower()
        for term in re.findall(r"[A-Za-z0-9]+", query)
        if len(term) >= 3 and term.lower() not in _NAIVE_STOPWORDS
    ]
    if not terms:
        terms = [role] if len(role) >= 3 else []
    if not terms:
        return None

    # Try the most distinctive (longest) term first.
    terms.sort(key=len, reverse=True)

    collected: list[Path] = []
    for term in terms[:3]:
        predicate = f'kMDItemFSName == "*{term}*"c'
        if validate_predicate(predicate) is None:
            continue
        for idx, root in enumerate(roots):
            mdfind_started = time.perf_counter()
            state.mdfind_calls += 1
            results = await run_mdfind(predicate, root, FILE_MDFIND_MAX_RESULTS)
            state.mdfind_total += time.perf_counter() - mdfind_started
            state.last_result_count = len(results)
            _emit(
                "mdfind",
                role=role,
                naive_term=term,
                only_in_root_index=idx,
                result_count=len(results),
                **_debug_fields(predicate=predicate),
            )
            if results:
                collected.extend(results)
        if collected:
            break

    if not collected:
        return None

    unique: list[Path] = []
    seen: set[str] = set()
    for path in collected:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)

    if len(unique) == 1:
        return unique[0]

    preferred, penalised = _preferred_extensions(role, query)
    unique.sort(key=lambda p: _rank_candidate(p, preferred, penalised, query))
    _emit(
        "round",
        role=role,
        rule_decision="naive_pick",
        result_count=len(unique),
        basename=unique[0].name,
        ext=unique[0].suffix.lower(),
    )
    return unique[0]


async def _walk_fallback(
    intent: IntentObject,
    transcript: str,
    role: str,
    state: "_ResolverState",
) -> Path | None:
    roots = list(FILE_SEARCH_ROOTS)
    if not roots:
        return None
    walk_started = time.perf_counter()
    candidates = bounded_walk(roots, FILE_WALK_MAX_FILES, FILE_WALK_MAX_DEPTH)
    state.walk_total += time.perf_counter() - walk_started
    state.walk_file_count = len(candidates)
    _emit("walk", role=role, file_count=len(candidates))
    if not candidates:
        return None

    if len(candidates) == 1:
        return candidates[0] if _is_under_any_root(candidates[0], roots) else None

    trimmed = candidates[:_MAX_PICK_CANDIDATES]
    pick_result = await _cactus_final_pick(
        intent, transcript, role, trimmed, roots, state
    )
    return pick_result.chosen


async def _cactus_final_pick(
    intent: IntentObject,
    transcript: str,
    role: str,
    candidates: list[Path],
    roots: list[Path],
    state: "_ResolverState",
) -> _PickResult:
    if not candidates:
        return _PickResult(None, "no_candidates")
    trimmed = candidates[:_MAX_PICK_CANDIDATES]
    prompt = _build_pick_prompt(intent, transcript, role, trimmed)
    result = await _cactus_json(prompt, state)
    if not result:
        return _PickResult(None, "no_response")

    confidence = str(result.get("confidence", "")).strip().lower()
    chosen_raw_val = result.get("chosen_path")
    if chosen_raw_val is None:
        return _PickResult(None, "null")
    chosen_raw = str(chosen_raw_val).strip()
    if not chosen_raw or chosen_raw.lower() == "null":
        return _PickResult(None, "null")

    if confidence == "low":
        _emit("round", role=role, detail="pick_low_confidence")
        return _PickResult(None, "low_confidence")

    try:
        chosen = Path(chosen_raw).expanduser()
    except (OSError, ValueError):
        return _PickResult(None, "invalid_path")
    if chosen not in trimmed:
        match = next((c for c in trimmed if str(c) == str(chosen)), None)
        if match is None:
            _emit("round", role=role, detail="pick_out_of_set")
            return _PickResult(None, "out_of_set")
        chosen = match
    if not _is_under_any_root(chosen, roots):
        _emit("round", role=role, detail="pick_out_of_roots")
        return _PickResult(None, "out_of_roots")
    return _PickResult(chosen, None)


# ─── Cactus JSON helper (mockable in tests) ───────────────────────────────────


async def _cactus_json(prompt: str, state: "_ResolverState") -> dict[str, Any] | None:
    """
    Run a single Cactus completion, parsing strict JSON from stdout.

    Tests monkeypatch this function to avoid shelling out.
    """
    if not CACTUS_CLI:
        return None
    started = time.perf_counter()
    try:
        proc = await asyncio.create_subprocess_exec(
            CACTUS_CLI,
            "run",
            CACTUS_GEMMA4_MODEL,
            "--prompt",
            prompt,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _stderr = await proc.communicate()
    except (OSError, asyncio.CancelledError):
        state.cactus_total += time.perf_counter() - started
        return None
    state.cactus_total += time.perf_counter() - started
    if proc.returncode != 0:
        return None
    return _parse_json(stdout.decode("utf-8", errors="ignore"))


def _parse_json(raw: str) -> dict[str, Any] | None:
    cleaned = raw.strip()
    if not cleaned:
        return None
    cleaned = re.sub(r"^```(?:json)?|```$", "", cleaned, flags=re.MULTILINE).strip()
    match = re.search(r"\{.*\}", cleaned, re.DOTALL)
    if not match:
        return None
    try:
        data = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    if isinstance(data, dict):
        return data
    return None


# ─── Prompt builders ──────────────────────────────────────────────────────────


def _build_predicate_prompt(
    intent: IntentObject,
    transcript: str,
    role: str,
    roots: list[Path],
    previous: list[dict[str, Any]],
) -> str:
    root_lines = "\n".join(f"  [{i}] {root}" for i, root in enumerate(roots))
    prev_block = ""
    if previous:
        summary = []
        for entry in previous[-2:]:
            pred = entry.get("predicate", "")
            if len(pred) > 200:
                pred = pred[:200] + "…"
            basenames = entry.get("basenames") or []
            summary.append(
                f"- predicate: {pred}\n  count: {entry.get('count', 0)}\n"
                f"  sample: {', '.join(basenames[:6])}"
            )
        prev_block = "Previous rounds:\n" + "\n".join(summary) + "\n\n"

    uses_local = ", ".join(intent.uses_local_data) or "(none)"
    slots_json = json.dumps(intent.slots, ensure_ascii=True)
    if len(slots_json) > FILE_INDEX_MAX_CHARS:
        slots_json = slots_json[:FILE_INDEX_MAX_CHARS] + "…"

    role_hint = _role_hint(role)

    return (
        "You are a local file search planner. Produce ONE JSON object with a\n"
        "Spotlight (mdfind) predicate that finds the file the user is asking for.\n"
        "Respond with JSON only, no prose.\n\n"
        f"{_MD_CHEAT_SHEET}\n\n"
        "Allowed search roots (index in square brackets):\n"
        f"{root_lines}\n\n"
        f"Role: {role} — {role_hint}\n"
        f"Intent goal: {intent.goal.value}\n"
        f"Intent uses_local_data: {uses_local}\n"
        f"Intent slots: {slots_json}\n"
        f"Transcript: {transcript!r}\n\n"
        f"{prev_block}"
        "Return JSON with fields:\n"
        "  \"predicate\": string,         // MDQuery expression\n"
        "  \"only_in_root_index\": int,   // choose from allowed roots above\n"
        "  \"rationale\": string          // short, for logs\n"
    )


def _build_pick_prompt(
    intent: IntentObject,
    transcript: str,
    role: str,
    candidates: list[Path],
) -> str:
    lines = [
        f"- {i}: {candidate.name}  (in {candidate.parent})"
        for i, candidate in enumerate(candidates)
    ]
    listing = "\n".join(lines)
    if len(listing) > FILE_INDEX_MAX_CHARS:
        listing = listing[:FILE_INDEX_MAX_CHARS] + "\n…"

    allowed = "\n".join(f"  {candidate}" for candidate in candidates)
    role_hint = _role_hint(role)

    return (
        "Pick exactly one path from the allowed list that best matches the user's\n"
        "request, OR abstain if none of them look right. Candidates are listed in\n"
        "Spotlight's native ranking order (top = most likely match).\n"
        "Respond with JSON only.\n\n"
        f"Role: {role} — {role_hint}\n"
        f"Intent goal: {intent.goal.value}\n"
        f"Transcript: {transcript!r}\n\n"
        "Candidates (ranked):\n"
        f"{listing}\n\n"
        "Allowed paths (must copy one verbatim into chosen_path if picking):\n"
        f"{allowed}\n\n"
        "Return JSON: { \"chosen_path\": string | null, "
        "\"confidence\": \"high\" | \"medium\" | \"low\", "
        "\"reason\": string }\n"
        "Set chosen_path to null to abstain when none of the candidates match."
    )


def _role_hint(role: str) -> str:
    return {
        "resume": "user's resume or CV document",
        "cover_letter": "user's cover letter document",
        "attachment": "a file the user wants to attach to an email or message",
        "document": "a general document the user referenced",
        "deck": "a slide deck or presentation",
        "found": "the file the user is asking the agent to find or reveal",
    }.get(role, role)


# ─── Helpers ──────────────────────────────────────────────────────────────────


def _roles_for_intent(intent: IntentObject) -> list[str]:
    roles: list[str] = []
    seen: set[str] = set()

    def _add(role: str) -> None:
        if role and role not in seen:
            seen.add(role)
            roles.append(role)

    for tag in intent.uses_local_data:
        if tag in _LOCAL_ROLE_TAGS:
            _add(tag)

    if intent.goal == KnownGoal.FIND_FILE:
        _add("found")
    elif intent.goal == KnownGoal.APPLY_TO_JOB and not roles:
        _add("resume")

    return roles


def _is_under_any_root(path: Path, roots: list[Path]) -> bool:
    try:
        resolved = path.expanduser().resolve()
    except OSError:
        return False
    for root in roots:
        try:
            root_resolved = root.expanduser().resolve()
        except OSError:
            continue
        try:
            if resolved.is_relative_to(root_resolved):
                return True
        except AttributeError:
            try:
                resolved.relative_to(root_resolved)
                return True
            except ValueError:
                continue
    return False


# ─── Structured logging ───────────────────────────────────────────────────────


class _ResolverState:
    __slots__ = (
        "role",
        "wall_started",
        "cactus_total",
        "mdfind_total",
        "walk_total",
        "predicate_rounds_used",
        "mdfind_calls",
        "last_result_count",
        "walk_file_count",
        "last_round_abstained",
    )

    def __init__(self, role: str) -> None:
        self.role = role
        self.wall_started = time.perf_counter()
        self.cactus_total = 0.0
        self.mdfind_total = 0.0
        self.walk_total = 0.0
        self.predicate_rounds_used = 0
        self.mdfind_calls = 0
        self.last_result_count = 0
        self.walk_file_count = 0
        self.last_round_abstained = False

    def timings_snapshot(self) -> dict[str, int]:
        return {
            "cactus_total": int(self.cactus_total * 1000),
            "mdfind_total": int(self.mdfind_total * 1000),
            "walk_total": int(self.walk_total * 1000),
            "resolver_wall": int((time.perf_counter() - self.wall_started) * 1000),
        }

    def counts_snapshot(self) -> dict[str, int]:
        return {
            "predicate_rounds_used": self.predicate_rounds_used,
            "mdfind_calls": self.mdfind_calls,
            "last_result_count": self.last_result_count,
            "walk_file_count": self.walk_file_count,
        }


def _finalize(state: "_ResolverState", **fields: Any) -> None:
    _emit(
        "exit",
        role=state.role,
        timings_ms=state.timings_snapshot(),
        counts=state.counts_snapshot(),
        **fields,
    )


def _emit(event: str, **fields: Any) -> None:
    parts = [f"event={event}"]
    for key, value in fields.items():
        parts.append(f"{key}={_format_value(value)}")
    print("[file-resolve] " + " ".join(parts))


def _format_value(value: Any) -> str:
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=True, separators=(",", ":"))
    if isinstance(value, (list, tuple)):
        return json.dumps(list(value), ensure_ascii=True, separators=(",", ":"))
    text = str(value)
    if " " in text or "=" in text:
        return json.dumps(text)
    return text


def _debug_fields(**fields: Any) -> dict[str, Any]:
    if FILE_RESOLVE_DEBUG:
        return fields
    return {}
