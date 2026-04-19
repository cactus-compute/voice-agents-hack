"""
Messages (iMessage / SMS) data source.

Reads `~/Library/Messages/chat.db` directly. Because the Messages app keeps
the DB WAL-locked while running, we copy the DB + its WAL sidecars to a
tmpdir and query from there — no impact on live Messages, safe to run
concurrently.

We group messages by chat (one synthetic doc per chat) and keep the last
N days so the index isn't dominated by ancient texts. Each doc becomes a
condensed transcript readable by the RAG answerer.

Requires Full Disk Access for the running terminal (System Settings →
Privacy & Security → Full Disk Access).
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sqlite3
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from .base import DataSource, SyntheticDoc


# Apple stores message.date as seconds (or ns on newer macOS) since 2001-01-01.
_APPLE_EPOCH = 978307200  # 2001-01-01 UTC as Unix time


@dataclass
class MessagesSource:
    name: str = "messages"
    history_days: int = 365
    max_messages_per_chat: int = 500
    max_chats: int = 2000

    def available(self) -> bool:
        db = _chat_db_path()
        if not db.exists():
            return False
        try:
            # `os.access` lies on macOS FDA paths — try opening for real.
            with open(db, "rb") as fh:
                fh.read(16)
        except (PermissionError, OSError):
            return False
        return True

    def iter_docs(self) -> Iterator[SyntheticDoc]:
        src = _chat_db_path()
        with tempfile.TemporaryDirectory(prefix="ali-chatdb-") as tmp:
            copy_path = Path(tmp) / "chat.db"
            try:
                shutil.copy2(src, copy_path)
                for sidecar in ("chat.db-wal", "chat.db-shm"):
                    side = src.with_name(sidecar)
                    if side.exists():
                        shutil.copy2(side, copy_path.with_name(sidecar))
            except (OSError, PermissionError) as exc:
                print(f"[disk-index][messages] copy failed: {exc}")
                return

            try:
                yield from self._iter_from_copy(copy_path)
            except sqlite3.DatabaseError as exc:
                print(f"[disk-index][messages] sqlite error: {exc}")

    def _iter_from_copy(self, db_path: Path) -> Iterator[SyntheticDoc]:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            cutoff_apple_s = int(time.time() - self.history_days * 86400 - _APPLE_EPOCH)
            # Pull a capped, ordered batch of messages joined with chat + handle.
            rows = conn.execute(
                """
                SELECT
                    chat.ROWID           AS chat_rowid,
                    chat.chat_identifier AS chat_id,
                    chat.display_name    AS chat_name,
                    chat.is_archived     AS is_archived,
                    message.ROWID        AS msg_id,
                    message.text         AS text,
                    message.is_from_me   AS is_from_me,
                    message.date         AS date_raw,
                    handle.id            AS handle_id
                FROM message
                JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
                JOIN chat              ON chat.ROWID = chat_message_join.chat_id
                LEFT JOIN handle       ON handle.ROWID = message.handle_id
                WHERE message.date / 1000000000 >= ?  -- ns variant, newer macOS
                   OR message.date              >= ?  -- seconds variant
                ORDER BY chat.ROWID, message.date DESC
                """,
                (cutoff_apple_s, cutoff_apple_s),
            ).fetchall()
        finally:
            conn.close()

        # Group rows by chat_rowid, keep first N (= most recent because of DESC).
        by_chat: dict[int, list[sqlite3.Row]] = {}
        for row in rows:
            cid = int(row["chat_rowid"])
            if cid not in by_chat:
                if len(by_chat) >= self.max_chats:
                    continue
                by_chat[cid] = []
            if len(by_chat[cid]) < self.max_messages_per_chat:
                by_chat[cid].append(row)

        for chat_rowid, msgs in by_chat.items():
            if not msgs:
                continue
            first = msgs[0]
            identifier = (first["chat_name"] or first["chat_id"] or "unknown chat").strip()
            latest_apple = first["date_raw"]
            mtime = _apple_to_unix(latest_apple)

            transcript_lines: list[str] = [f"Conversation with {identifier}"]
            handles: set[str] = set()
            # Chronological ascending reads more naturally in the RAG snippet.
            for m in reversed(msgs):
                txt = (m["text"] or "").strip()
                if not txt:
                    continue
                who = "Me" if int(m["is_from_me"] or 0) == 1 else (m["handle_id"] or identifier)
                if not int(m["is_from_me"] or 0) and m["handle_id"]:
                    handles.add(m["handle_id"])
                when = _apple_to_unix(m["date_raw"])
                when_str = time.strftime("%Y-%m-%d %H:%M", time.localtime(when)) if when else ""
                transcript_lines.append(f"[{when_str}] {who}: {txt}")

            if len(transcript_lines) == 1:
                continue  # no text-bearing messages

            content = "\n".join(transcript_lines)
            stable_id = hashlib.sha1(
                f"{chat_rowid}:{identifier}".encode("utf-8")
            ).hexdigest()[:16]

            yield SyntheticDoc(
                source=self.name,
                id=stable_id,
                display_name=identifier[:120],
                content=content,
                mtime=mtime or time.time(),
                size=len(content),
                metadata={
                    "chat_identifier": identifier,
                    "handles": sorted(handles),
                    "message_count": len(msgs),
                },
            )


def build(*, history_days: int = 365) -> MessagesSource:
    return MessagesSource(history_days=history_days)


def _chat_db_path() -> Path:
    return Path(os.path.expanduser("~/Library/Messages/chat.db"))


def _apple_to_unix(raw) -> float:
    """Normalise the two message.date formats to a Unix timestamp."""
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return 0.0
    if value == 0:
        return 0.0
    if value > 10**14:
        # Nanoseconds since 2001-01-01 (macOS 10.13+).
        return value / 1e9 + _APPLE_EPOCH
    return float(value) + _APPLE_EPOCH
