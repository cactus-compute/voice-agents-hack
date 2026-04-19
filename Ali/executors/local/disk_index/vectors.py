"""
hnswlib wrapper: cosine-space HNSW index of chunk embeddings.

The index labels are the SQLite `chunks.id` values. A separate JSON sidecar
records the maximum element count and the last-known chunk count so a stale
index file doesn't silently drift from the DB.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import numpy as np  # noqa: F401
    import hnswlib  # type: ignore

from .embed import EMBED_DIM


@dataclass(frozen=True)
class VectorStoreMeta:
    count: int
    dim: int
    model: str


def build_index(
    path_bin: Path,
    path_meta: Path,
    *,
    ids: list[int],
    vectors,
    model_name: str,
    ef_construction: int = 200,
    M: int = 16,
) -> None:
    """Build a new HNSW index and persist it to disk."""
    import hnswlib  # type: ignore
    import numpy as np

    if len(ids) != len(vectors):
        raise ValueError("ids/vectors length mismatch")

    path_bin.parent.mkdir(parents=True, exist_ok=True)
    max_elements = max(1, len(ids))
    index = hnswlib.Index(space="cosine", dim=EMBED_DIM)
    index.init_index(max_elements=max_elements, ef_construction=ef_construction, M=M)
    if ids:
        index.add_items(np.asarray(vectors, dtype="float32"), ids)
    index.set_ef(max(32, min(200, max_elements)))
    index.save_index(str(path_bin))

    meta = {
        "count": len(ids),
        "dim": EMBED_DIM,
        "model": model_name,
    }
    path_meta.write_text(json.dumps(meta, indent=2), encoding="utf-8")


def load_index(path_bin: Path, path_meta: Path):
    """Load a persisted HNSW index. Returns (index, meta) or (None, None)."""
    if not path_bin.exists() or not path_meta.exists():
        return None, None
    try:
        import hnswlib  # type: ignore

        meta_raw = json.loads(path_meta.read_text(encoding="utf-8"))
        meta = VectorStoreMeta(
            count=int(meta_raw.get("count", 0)),
            dim=int(meta_raw.get("dim", EMBED_DIM)),
            model=str(meta_raw.get("model", "")),
        )
        index = hnswlib.Index(space="cosine", dim=meta.dim)
        index.load_index(str(path_bin), max_elements=max(1, meta.count))
        index.set_ef(max(32, min(200, max(1, meta.count))))
        return index, meta
    except Exception as exc:
        print(f"[disk-index] vector load failed: {exc}")
        return None, None


def query(
    index,
    vector,
    *,
    k: int = 12,
) -> list[tuple[int, float]]:
    """Return top-k `(chunk_id, cosine_distance)` pairs."""
    import numpy as np

    if index is None:
        return []
    arr = np.asarray(vector, dtype="float32").reshape(1, -1)
    k = max(1, min(k, index.get_current_count() or 1))
    try:
        labels, distances = index.knn_query(arr, k=k)
    except Exception as exc:
        print(f"[disk-index] vector query failed: {exc}")
        return []
    out: list[tuple[int, float]] = []
    for label, dist in zip(labels[0], distances[0]):
        out.append((int(label), float(dist)))
    return out
