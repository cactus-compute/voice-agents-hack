# User Testing

## Validation Surface

**Primary surface for this mission:** iOS Simulator (iPhone 17, iOS 26.4 / latest).

The TacNet product is ultimately a native iOS app designed for multi-phone BLE operation, but this mission validates **only the single-device automation surface** — Simulator-runnable behavior. Multi-phone, BLE, real Cactus inference, and real mic flows are out of scope and documented in `MANUAL_TESTING.md` for future manual verification with 4 physical iPhones.

## Testing Tools

- **`xcodebuild test`** — XCTest unit/integration tests (existing suite in `TacNetTests/TacNetTests.swift`, 119 tests). Covers all pure logic: models, routing, compaction triggers, tree helpers, dedup, version convergence, role claim protocol, download state machine (mocked client), PTT state transitions (mocked mesh).
  - For this project, default scheme test execution may prioritize UI test-plan entries; to reliably validate unit assertions use explicit selectors: `-only-testing:TacNetTests` (and combine with `-only-testing:TacNetUITests` for full-sweep evidence).
- **`xcodebuild test` + XCUITest** — New `TacNetUITests` target (added by Feature 3 of the current mission) drives the simulator UI walkthrough. Used for VAL-UI-* assertions.
- **`xcrun simctl`** — Simulator lifecycle (boot, install, launch, screenshot, terminate, shutdown) and console streaming (`launch --console-pty`).
- **Screenshots** — Capture via `xcrun simctl io booted screenshot <path>.png` for evidence. Stored under `TacNetTests/Screenshots/` when committed as part of regression evidence.

## Validation Concurrency

Single `xcodebuild` invocation at a time. No parallelization of validators for this mission.

**Max concurrent validators: 1.** Rationale: one Simulator instance; `xcodebuild test` already parallelizes internally across test classes; resource headroom does not benefit from running multiple xcodebuild processes simultaneously.

## Console Red-Flag Grep Strings

During any smoke walkthrough, the console stream (captured via `xcrun simctl launch --console-pty 'iPhone 17' com.tacnet.app`) MUST NOT contain:

- `Fatal error:`
- `Thread 1: EXC_`
- `SIGABRT`
- `Modifying state during view update`
- `AttributeGraph: cycle detected`
- `Unhandled error`

Occurrences of any of these strings fail VAL-UI-013.

## Known Limitations (Documented, Not Bugs)

- **Simulator has no Bluetooth.** All BLE-dependent flows rely on mocked `BluetoothMeshTransporting` in unit tests. Simulator smoke walkthrough cannot exercise real BLE.
- **Cactus inference requires real weights (6.7 GB).** Tests mock `CactusClient`. Simulator smoke does NOT require real inference.
- **`AVAudioEngine` may be unreliable in Simulator.** Tests mock `AudioService`. Smoke tests do not exercise real mic capture.
- **GPS in Simulator is simulated** — can be controlled via `xcrun simctl location` if needed, but this mission does not exercise GPS end-to-end.

## Physical-Device-Only Assertions (Out of Scope This Mission)

Listed in `MANUAL_TESTING.md` — 53 manual assertions covering BLE mesh, real Cactus, real mic, multi-phone flows. They remain the definition of "fully working on hardware" and must be run on 4 physical iPhones before any production release. They are NOT part of this mission's `validation-contract.md`.

## Flow Validator Guidance: iOS Simulator

- Use only `iPhone 17` Simulator (`platform=iOS Simulator,name=iPhone 17,OS=latest`).
- Stay inside repo root `/Users/lucaspfingstenplanells/Desktop/YC-hack`; do not write outside `.factory/validation/<milestone>/user-testing/` and mission evidence directories.
- Respect single-run isolation: no parallel `xcodebuild` processes and no shared mutable simulator state across simultaneous validators.
- If your flow depends on simulator state, boot/clean/reset only within your own sequence and leave the simulator shut down when done.
- Keep evidence paths scoped to your assigned group id under `{missionDir}/evidence/<milestone>/<group-id>/`.
- Do not modify product logic for validation convenience; if environment/setup blocks testing, report blocker with concrete command output.
