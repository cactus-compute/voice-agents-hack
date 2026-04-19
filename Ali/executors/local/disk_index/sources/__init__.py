"""
Non-filesystem data sources for the disk index.

Each module under this package exposes a `build(history_days: int)` function
that returns a ``DataSource`` — an iterable of ``SyntheticDoc`` objects that
the index pipeline treats like files. Synthetic paths use the ``ali://``
scheme so the rest of the codebase can recognise them and avoid opening them
in Finder.
"""

from __future__ import annotations

from typing import Iterable

from .base import DataSource, SyntheticDoc


def load_sources(names: Iterable[str], *, history_days: int) -> list[DataSource]:
    """Return the subset of built-in sources whose name is in `names` and
    which reports itself available on this machine."""
    enabled: list[DataSource] = []
    requested = {n.strip().lower() for n in names if n.strip()}
    if not requested:
        return enabled

    if "contacts" in requested:
        try:
            from . import contacts

            source = contacts.build()
            if source.available():
                enabled.append(source)
        except Exception as exc:
            print(f"[disk-index][source] contacts init failed: {exc}")

    if "calendar" in requested:
        try:
            from . import calendar as cal_mod

            source = cal_mod.build(history_days=history_days)
            if source.available():
                enabled.append(source)
        except Exception as exc:
            print(f"[disk-index][source] calendar init failed: {exc}")

    if "messages" in requested:
        try:
            from . import messages as msg_mod

            source = msg_mod.build(history_days=history_days)
            if source.available():
                enabled.append(source)
        except Exception as exc:
            print(f"[disk-index][source] messages init failed: {exc}")

    return enabled


__all__ = ["DataSource", "SyntheticDoc", "load_sources"]
