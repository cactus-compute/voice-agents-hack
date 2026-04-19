"""
Shared types for non-filesystem data sources.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator, Protocol


SYNTHETIC_SCHEME = "ali://"


@dataclass(frozen=True)
class SyntheticDoc:
    """One item pulled from a non-filesystem data source.

    Stored in the index as a regular `files` row whose `path` is
    ``ali://{source}/{id}``. The chunker/embedder treat it like any other
    file; file_resolve.py knows to skip these when resolving "reveal in
    Finder" requests.
    """

    source: str          # "contacts" | "calendar" | "messages"
    id: str              # stable unique id within the source
    display_name: str    # human-readable label (goes into `files.name`)
    content: str         # plain-text body (chunked + embedded)
    mtime: float         # Unix timestamp used for incremental skip checks
    size: int = 0
    metadata: dict = field(default_factory=dict)

    @property
    def path(self) -> str:
        return f"{SYNTHETIC_SCHEME}{self.source}/{self.id}"


class DataSource(Protocol):
    """Anything that yields synthetic docs for the index build."""

    name: str  # short label — must match the settings.py registration

    def available(self) -> bool:
        """Return True if this source has the prerequisites (tools,
        permissions, data files) to run on this machine."""
        ...

    def iter_docs(self) -> Iterator[SyntheticDoc]:
        ...


def is_synthetic_path(path: str) -> bool:
    return isinstance(path, str) and path.startswith(SYNTHETIC_SCHEME)
