# Codex Privacy Slice

This directory holds the earlier Codex-owned Rust privacy slice. It now lives
under `platform/masker-core/experiments/` so the repo has one canonical Rust
home while still keeping the narrower prototype around for reference.

Current scope:
- deterministic PII/PHI detection
- HIPAA-first policy routing
- masking and output scrubbing
- a single-call `analyze_transcript()` entrypoint
- unit tests and a tiny CLI demo

Run:

```bash
cd platform/masker-core/experiments/codex-privacy-slice
cargo test
cargo run -p masker-core
```
