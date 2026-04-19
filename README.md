# TacNet

TacNet is a native iOS tactical mesh application. Every phone in the network runs
an on-device Gemma 4 E4B model via the Cactus XCFramework and participates in a
decentralized Bluetooth Low Energy (BLE) mesh. Leaf nodes push-to-talk, on-device
speech-to-text produces transcripts, and parent nodes automatically compact child
messages into summaries that propagate up a configurable command tree. The system
is designed to work fully offline, with no servers and no internet dependency.

## Requirements

- macOS on Apple Silicon (darwin 25.4.0 in this repo's dev environment).
- Xcode 26.4 at `/Applications/Xcode.app`; `xcode-select -p` must point at
  Xcode.app, not CommandLineTools.
- Swift 5.9+.
- iOS deployment target: **18.6** (applies to `TacNet`, `TacNetTests`, and
  `TacNetUITests` — bumped because the Cactus XCFramework requires it).
- Simulator target: **iPhone 17** Simulator with its iOS 26.4 (or latest) runtime
  installed.
- Cactus SDK: vendored as a prebuilt XCFramework at
  `Frameworks/cactus-ios.xcframework`. Do not modify the binary artifact. Real
  model weights (Gemma 4 E4B INT4, ~6.7 GB) are not required for Simulator
  builds — unit and UI tests use mocks. Real weights are needed only for
  on-device inference during multi-phone hardware testing.

## Project Layout

- `TacNet/` — app sources (SwiftUI views, view models, services, utilities).
- `TacNetTests/` — XCTest unit and integration tests plus committed screenshots.
- `TacNetUITests/` — XCUITest Simulator walkthroughs.
- `TacNet.xcodeproj/` — Xcode project and shared `TacNet` scheme.
- `Frameworks/` — vendored `cactus-ios.xcframework`.
- `.factory/` — repo-local automation: `services.yaml` (canonical commands),
  `library/` (environment + user-testing notes), `validation/` (per-mission
  evidence), `skills/`, and `init.sh`.

## Build and Run

All canonical commands are defined in `.factory/services.yaml` and target the
iPhone 17 Simulator. Run from the repo root.

```bash
# Build
xcodebuild build -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# Clean build
xcodebuild clean build -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# Clean only
xcodebuild clean -project TacNet.xcodeproj -scheme TacNet
```

The project's warning gate is the `warnings-only` pipeline in
`.factory/services.yaml`: it runs a clean build and filters for `: warning:`
lines while excluding the vendored `cactus.framework` (see "Known Constraints").

## Testing

The baseline expectation on a clean build is **≥122 unit tests** in
`TacNetTests` and **≥12 UI tests** in `TacNetUITests`, with zero failures and
zero non-upstream warnings.

```bash
# All tests
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# Unit tests only
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TacNetTests

# UI tests only
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TacNetUITests

# A specific test
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TacNetTests/TacNetTests/testTreeNodeRoundTripEncodingWithNestedChildren
```

### UI-test launch-argument hooks

The app reads these arguments from `ProcessInfo` to provide deterministic UI-test
entry points (see `TacNet/Views/ContentView.swift` and
`TacNet/Services/BluetoothMeshService.swift`):

- `--ui-test-skip-download` — bypass the model download gate.
- `--ui-test-route=<name>` — mount a dedicated test host view (for example
  `main-ptt`, `settings`, and other route identifiers handled in
  `ContentView.swift`).
- `--ui-test-role=<organiser|participant>` — seed role-scoped UI hosts with
  deterministic identities.
- `--ui-test-mesh-peers=<N>` — seed `BluetoothMeshService` with `N` fake peers
  (Simulator has no real BLE).
- `--ui-test-capture-logs` — enable an in-app log buffer that records PTT log
  lines so UI tests can assert on them.
- `--ui-test-download-fixture=<name>` — swap the real download flow for a named
  fixture.

## Key Subsystems

- **Bluetooth mesh** — `TacNet/Services/BluetoothMeshService.swift` implements
  the dual Core Bluetooth central + peripheral stack, UUID-based deduplication,
  and test-only peer seeding. Simulator cannot exercise real BLE; unit tests
  use a `BluetoothMeshTransporting` mock.
- **Model download bootstrap** — `ModelDownloadService` (actor) and supporting
  types live in `TacNet/Services/Cactus.swift`. The bootstrap flow is driven by
  `AppBootstrapViewModel` in `TacNet/Views/ContentView.swift`, which gates
  tactical features behind successful model readiness.
- **Push-to-Talk** — `PTTButton`, `PTTButtonStyle`, `PTTPressDispatcher`, and
  `MainViewModel` all live in `TacNet/Views/ContentView.swift`. The dispatcher
  owns press lifecycle and emits `[PTT]` log lines used by UI-test assertions.
- **Settings and roles** — role-scoped settings UI and organiser/participant
  behaviours are driven from `ContentView.swift` via the `--ui-test-role` and
  `--ui-test-route=settings` hooks.

## Logging Conventions

Runtime logs use `NSLog` with these prefixes so they can be filtered with
`xcrun simctl launch --console-pty` or Console.app:

- `[BLE]` — Bluetooth mesh discovery, connection, and transport events.
- `[PTT]` — push-to-talk gesture, dispatch, and state-machine transitions.
- `[ModelDownload]` — bootstrap download progress, retry, and readiness.
- `[MSG]` — message routing and envelope handling.
- `[Role]` — role claim, release, and organiser transfer events.

Red-flag strings the console must not contain during smoke walkthroughs are
listed in `.factory/library/user-testing.md`.

## Known Constraints

- The vendored upstream Cactus XCFramework emits umbrella-header warnings
  (framework includes that Xcode flags as non-modular in a framework module)
  that cannot be fixed inside this repo. They are intentionally excluded from
  the warning gate via the `warnings-only` step in `.factory/services.yaml`,
  which pipes `xcodebuild` output through `grep -v 'cactus.framework'`.
- Simulator has no Bluetooth, real Cactus inference, or reliable
  `AVAudioEngine`; hardware-only assertions are documented in
  `MANUAL_TESTING.md` for future physical-device runs.
- `IPHONEOS_DEPLOYMENT_TARGET` was raised to 18.6 across all targets (app and
  both test targets) because Cactus requires it. This is a deliberate,
  already-landed decision — not a pending upgrade.

## Contributing

- Follow the conventions already in place: canonical commands live in
  `.factory/services.yaml`, environment notes in `.factory/library/environment.md`,
  and validation guidance in `.factory/library/user-testing.md`.
- Architectural decisions are logged in `DECISIONS.md`. Manual-testing
  assertions for physical hardware are in `MANUAL_TESTING.md`. A high-level
  product and protocol reference is in `Orchestrator.md`.
- Mission-specific boundaries, when a mission is active, are documented in an
  `AGENTS.md` inside that mission's directory under
  `.factory/validation/<mission>/`. Respect those boundaries when one is
  present.
- Do not push to the remote unless explicitly instructed. Commit locally only.
