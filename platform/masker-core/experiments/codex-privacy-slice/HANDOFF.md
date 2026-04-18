### Status
- What works: the Codex privacy core now lives in `platform/masker-core/experiments/codex-privacy-slice/masker-core` with one entrypoint, `analyze_transcript()`.
- What works: the crate returns detection result, policy decision, masked transcript, and timing metadata in one Rust value.
- What works: deterministic rules cover SSN, phone, email, MRN, insurance ID, simple name hooks, and healthcare-context keywords.
- What is blocked: Cursor's current Python integration path does not yet call into the Rust crate, so this is implemented as a clean Rust core but not yet wired into the voice loop.
- What changed: the new Python-only Codex files were removed from the branch and replaced by a standalone Rust crate plus tests and demo CLI.
- What next agent needs: Cursor can either shell out to `masker-core-demo` as a stopgap or add an FFI/binding layer to call `analyze_transcript()` directly.
- What next agent needs: Ona can use the JSON shape from the demo binary output to drive the explanation UI without waiting for full runtime wiring.
