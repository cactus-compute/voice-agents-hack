"""
Lazy embedding-model wrapper.

Prefers `sentence-transformers` (clean API + bundled pooling) but falls
back to raw `transformers` + mean pooling when sentence-transformers is
unavailable or broken — notably when sentence-transformers v5+ drags in
`torchcodec`, which requires FFmpeg libraries macOS doesn't ship by
default.

Both paths produce identical 384-dim MiniLM-L6-v2 embeddings; the
downstream HNSW index and FTS5 pipeline don't care which loader was used.
"""

from __future__ import annotations

import os
import threading

_model_lock = threading.Lock()
_model = None        # either SentenceTransformer or _HFMiniLM instance
_model_name: str | None = None
_loader: str | None = None  # "sbert" | "hf"

EMBED_DIM = 384  # MiniLM-L6-v2


def _load(model_name: str):
    global _model, _model_name, _loader
    with _model_lock:
        if _model is not None and _model_name == model_name:
            return _model

        os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

        # Path 1 — sentence-transformers (ideal).
        try:
            from sentence_transformers import SentenceTransformer  # type: ignore

            _model = SentenceTransformer(model_name)
            _model_name = model_name
            _loader = "sbert"
            return _model
        except Exception as exc:
            # Typical trigger: `sentence_transformers >= 5.0` imports
            # torchcodec (needs FFmpeg). We recover by driving transformers
            # directly — same weights, zero multimedia deps.
            print(
                f"[disk-index] sentence-transformers unavailable ({exc}); "
                "falling back to raw transformers loader."
            )

        # Path 2 — raw transformers + mean pooling.
        _model = _HFMiniLM(model_name)
        _model_name = model_name
        _loader = "hf"
        return _model


def warmup(model_name: str) -> None:
    """Pre-load the encoder in a background thread; safe to call more than once."""
    try:
        _load(model_name)
    except Exception as exc:
        print(f"[disk-index] embedder warmup failed: {exc}")


def embed_texts(
    texts: list[str],
    *,
    model_name: str,
    batch_size: int = 64,
    show_progress: bool = False,
):
    """Return an (N, EMBED_DIM) numpy array with L2-normalised embeddings."""
    import numpy as np

    if not texts:
        return np.zeros((0, EMBED_DIM), dtype="float32")
    model = _load(model_name)

    if _loader == "sbert":
        vectors = model.encode(
            texts,
            batch_size=batch_size,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=show_progress,
        )
        return vectors.astype("float32", copy=False)

    # raw-transformers path
    return model.encode(texts, batch_size=batch_size)


def embed_query(query: str, *, model_name: str):
    """Embed a single query string; shape (EMBED_DIM,)."""
    import numpy as np

    vecs = embed_texts([query], model_name=model_name, batch_size=1)
    if vecs.shape[0] == 0:
        return np.zeros(EMBED_DIM, dtype="float32")
    return vecs[0]


# ─── HuggingFace fallback ─────────────────────────────────────────────────────


class _HFMiniLM:
    """Minimal MiniLM loader via `transformers` + mean pooling.

    Matches the output of sentence-transformers for
    `sentence-transformers/all-MiniLM-L6-v2` by using mean-pooled token
    embeddings with an attention mask and L2 normalisation.
    """

    def __init__(self, model_name: str) -> None:
        from transformers import AutoModel, AutoTokenizer  # type: ignore

        self._tokenizer = AutoTokenizer.from_pretrained(model_name)
        self._model = AutoModel.from_pretrained(model_name)
        self._model.eval()

    def encode(self, texts: list[str], *, batch_size: int = 32):
        import numpy as np
        import torch

        out: list[np.ndarray] = []
        with torch.inference_mode():
            for start in range(0, len(texts), batch_size):
                batch = texts[start : start + batch_size]
                encoded = self._tokenizer(
                    batch,
                    padding=True,
                    truncation=True,
                    max_length=512,
                    return_tensors="pt",
                )
                model_out = self._model(**encoded)
                token_embeddings = model_out.last_hidden_state  # (B, T, H)
                attention_mask = encoded["attention_mask"].unsqueeze(-1).float()
                summed = (token_embeddings * attention_mask).sum(dim=1)
                counts = attention_mask.sum(dim=1).clamp(min=1e-9)
                mean_pooled = summed / counts
                norm = torch.nn.functional.normalize(mean_pooled, p=2, dim=1)
                out.append(norm.cpu().numpy().astype("float32"))
        if not out:
            return np.zeros((0, EMBED_DIM), dtype="float32")
        return np.concatenate(out, axis=0)
