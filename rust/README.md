# Rust Privacy Core

This directory holds the Codex-owned privacy slice in Rust.

Current scope:
- deterministic PII/PHI detection
- HIPAA-first policy routing
- masking and output scrubbing
- a single-call `analyze_transcript()` entrypoint
- unit tests and a tiny CLI demo

Run:

```bash
cd rust
cargo test
cargo run -p masker-core
```
