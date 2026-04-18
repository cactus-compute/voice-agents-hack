# TacNetUITests target

The TacNetUITests target hosts XCUITest-driven smoke walkthrough of every
reachable non-BLE screen. It is wired into the shared `TacNet` scheme's
TestAction so `xcodebuild test -only-testing:TacNetUITests` runs it directly.

## Launch arguments consumed by the app

`TacNet/Views/ContentView.swift` defines a small `UITestMode` helper that reads
process launch arguments:

- `--ui-test-skip-download` — short-circuits `AppBootstrapViewModel` so the
  model-download gate unlocks immediately and the app navigates to the Welcome
  screen without attempting the 6.7 GB model download. Required for almost
  every UI test.
- `--ui-test-route=pin-entry` — replaces the root view with the dedicated
  `UITestPinEntryHost`, presenting the real `PinEntryView` against a seeded
  `DiscoveredNetwork`. Used by the PIN entry test because PIN entry is
  otherwise unreachable in Simulator (no BLE → no discovered networks).

Both flags are inert when not supplied, so production launches are unaffected.

## Key conventions

- Container views that have child accessibility identifiers (buttons,
  text fields) must use `.accessibilityElement(children: .contain)` **before**
  `.accessibilityIdentifier(...)`. Without `.contain`, SwiftUI propagates the
  container's identifier to every child and overrides their individual
  identifiers. The old `tacnet.*.root` identifiers on TabShell, TreeView,
  DataFlowView, SettingsView, etc. have all been migrated to this pattern.
- Tab-root identifiers (`tacnet.tree.root`, `tacnet.dataflow.root`,
  `tacnet.settings.root`, `tacnet.main.root`) can show up as any XCUIElement
  type depending on SwiftUI layout. Tests resolve them via
  `app.descendants(matching: .any).matching(identifier: ...).firstMatch` (see
  the `anyElement(_:identifier:)` helper in `TacNetUITests.swift`).
- The PTT control uses `.accessibilityElement(children: .combine)` to surface
  as a single static-text element named `tacnet.main.pttControl`.
- Reference screenshots live in `TacNetTests/Screenshots/` at the repo root
  (organiser walkthrough, welcome screen, PIN entry host). They are reference
  artifacts captured via `xcrun simctl io booted screenshot`, not asserted
  against in tests.

## Running

```bash
# Full test suite (unit + UI)
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# UI tests only
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TacNetUITests
```

The UI tests expect the `iPhone 17` Simulator to be available (UDID visible
in `xcrun simctl list devices available`). Pin appearance to light for stable
screenshots with `xcrun simctl ui 'iPhone 17' appearance light`.
