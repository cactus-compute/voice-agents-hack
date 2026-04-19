---
name: ios-worker
description: Native iOS (Swift/SwiftUI) implementation worker for TacNet app features — test-and-fix, UI smoke, and Simulator automation
---

# iOS Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE.

## When to Use This Skill

All TacNet iOS implementation, test-fixing, Simulator UI smoke, XCUITest authoring, warnings cleanup, and XCTest-level logic features. This is the only worker skill in the project.

## Required Skills

None. All work is done via the Xcode toolchain (`xcodebuild`) and Simulator tools (`xcrun simctl`).

## Work Procedure

### 1. Read the feature description thoroughly
- Identify whether the feature is: (a) fix-an-existing-failing-test, (b) add-tests-and-feature-code, (c) Simulator smoke / UI test authoring, or (d) warnings cleanup.
- Check preconditions. If a dependency is missing, return to orchestrator.
- Reference `.factory/library/architecture.md` for component relationships and `.factory/library/cactus-api.md` for Cactus SDK usage.

### 2. Write or verify tests FIRST (TDD)

**For fix-existing-failing-test features:**
- First, RUN the target test on the current code and confirm it fails (red). Capture the failure message.
- Do NOT modify the test to make it pass — fix the implementation.

**For new-behavior features:**
- Create or update XCTest cases in `TacNetTests/TacNetTests.swift` (project convention: single test file). New UI tests go into the `TacNetUITests` target.
- Tests must compile and FAIL (red) before implementation.
- Cover: normal path, edge cases from `expectedBehavior`, and at least one boundary condition.

Run a targeted test:
```bash
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TacNetTests/TacNetTests/<TestName> 2>&1 | tail -30
```

### 3. Implement the feature / fix

Conventions:
- Swift 5.9+, Swift Concurrency (`async`/`await`, actors).
- SwiftUI for views; do not introduce UIKit unless strictly required.
- `Codable` for models; explicit `CodingKeys` for wire format.
- Place files under `TacNet/Models/`, `TacNet/Services/`, `TacNet/Views/`, `TacNet/Utilities/` per existing layout.
- **Preserve existing NSLog debug additions** in `BluetoothMeshService.swift`, `Cactus.swift`, and `ContentView.swift`. Match the `[BLE] / [PTT] / [ModelDownload] / [MSG] / [Role]` prefix convention when adding new logs.

### 4. Make tests pass (green)

```bash
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TacNetTests/TacNetTests/<TestName> 2>&1 | tail -30
```

If tests still fail, fix implementation (not tests) until green.

### 5. Run full project build (fix warnings if warnings-cleanup feature)

```bash
xcodebuild build -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | tail -20
```

For warnings cleanup features, also:
```bash
xcodebuild clean build -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 \
  | grep ': warning:' | grep -v 'cactus.framework'
```
Expected line count: 0 for a clean feature. Upstream Cactus framework warnings are allowlisted.

### 6. Run ALL tests (full regression)

```bash
xcodebuild test -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | tail -40
```

All tests must pass. If a previously-passing test now fails, investigate — your change likely broke it.

### 7. Simulator smoke (when the feature involves UI behavior)

For UI-affecting features, boot the Simulator and exercise the relevant screens:

```bash
# Boot
xcrun simctl boot 'iPhone 17' 2>&1 || true  # idempotent

# Find the built .app
APP_PATH="$(xcodebuild -project TacNet.xcodeproj -scheme TacNet \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -showBuildSettings 2>/dev/null \
  | awk -F '= ' '/ BUILT_PRODUCTS_DIR / {bpd=$2} / WRAPPER_NAME / {wn=$2} END {print bpd"/"wn}')"

# Install + launch + screenshot + terminate
xcrun simctl install 'iPhone 17' "$APP_PATH"
xcrun simctl launch 'iPhone 17' com.tacnet.app
sleep 5
xcrun simctl io booted screenshot /tmp/tacnet-smoke.png
# ... interact via XCUITest or manually document what appears ...
xcrun simctl terminate 'iPhone 17' com.tacnet.app
xcrun simctl shutdown 'iPhone 17'
```

**Console red-flags to grep for** (any occurrence is a failure):
`Fatal error:`, `Thread 1: EXC_`, `SIGABRT`, `Modifying state during view update`, `AttributeGraph: cycle detected`, `Unhandled error`.

### 8. Clean up any started processes

- Always `xcrun simctl shutdown 'iPhone 17'` (or `shutdown all`) when done with Simulator work.
- Never leave watch-mode test runners, streaming console processes, or booted simulators behind.

### 9. Commit your changes before ending the session

The mission runner expects a commit per feature. Stage and commit the implementation + test files with a clear message.

---

## Xcode Project Manipulation Tips

### Adding new targets (e.g., a UI test target)

Editing `TacNet.xcodeproj/project.pbxproj` by hand is error-prone. Use the `xcodeproj` Ruby gem instead (pre-installed at `/opt/homebrew/opt/ruby/bin/gem`):

```bash
/opt/homebrew/opt/ruby/bin/gem install xcodeproj  # if missing
```

Then write a short Ruby script that opens the project, adds the target, wires it into the shared scheme (as a `TestableReference` + `BuildActionEntry`), and saves. This is the recommended approach for: adding `TacNetUITests`, adding new library targets, modifying build-phases programmatically.

## SwiftUI Accessibility Identifier Pitfall

When adding `.accessibilityIdentifier("foo")` on a container view (Stack/Group/NavigationView) that has identified children, SwiftUI will propagate the container id onto every child unless you FIRST mark the container as a compound element:

```swift
VStack { ... }
    .accessibilityElement(children: .contain)   // <-- required before the id
    .accessibilityIdentifier("tacnet.main.root")
```

Without `.accessibilityElement(children: .contain)`, XCUITest will see only the container's identifier and child identifiers become unreachable. This is a common footgun — check for it whenever a UI test can't find a child element it "should" see.

---

## Example Handoff

```json
{
  "salientSummary": "Fixed the 7 failing ModelDownload/AppBootstrap tests. Root cause was MockURLSessionDownloadClient returning a 19-byte error payload that failed the new size-sanity check in ModelDownloadService, combined with resumeData not being persisted between retry calls in AppBootstrapViewModel. Updated ModelDownloadService to distinguish interrupted vs size-mismatch errors, and corrected the resumeData hand-off in the retry path. All 7 target tests now pass; full suite runs 119 tests with 0 failures.",
  "whatWasImplemented": "Modified TacNet/Services/Cactus.swift (ModelDownloadService): added InterruptedError classification distinct from size-mismatch; introduced @MainActor-safe resumeData persistence keyed by attempt id. Modified TacNet/Views/ContentView.swift (AppBootstrapViewModel): retry() now reads stored resumeData and passes it to download(resumeData:); gate unlock uses Task.yield() to ensure the 3s deadline is met. Preserved all existing NSLog debug additions.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "xcodebuild test -project TacNet.xcodeproj -scheme TacNet -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:TacNetTests/TacNetTests/testModelDownloadServiceReportsMonotonicProgressWithAtLeastFiveIntermediateCallbacksAndUnlocksGate 2>&1 | tail -10",
        "exitCode": 0,
        "observation": "Test passed (0.042s). 5 intermediate callbacks observed, gate unlocked."
      },
      {
        "command": "xcodebuild test -project TacNet.xcodeproj -scheme TacNet -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | tail -10",
        "exitCode": 0,
        "observation": "Executed 119 tests, 0 failures, 0 unexpected. All 7 formerly-failing tests now pass."
      },
      {
        "command": "xcodebuild build -project TacNet.xcodeproj -scheme TacNet -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | tail -5",
        "exitCode": 0,
        "observation": "** BUILD SUCCEEDED **. No new warnings introduced."
      }
    ],
    "interactiveChecks": []
  },
  "tests": {
    "added": []
  },
  "discoveredIssues": []
}
```

---

## When to Return to Orchestrator

- Feature depends on a model/service/view/target that doesn't exist and isn't part of this feature.
- `TacNet.xcodeproj` structure needs changes you cannot make cleanly via `xcodebuild` (e.g., adding a new target like `TacNetUITests` is IN scope, but entitlement/signing changes are NOT).
- Cactus SDK integration breaks (framework not loading, API mismatch).
- BLE entitlements or Info.plist changes required.
- A test expectation appears genuinely wrong (not a bug to fix but a contract to renegotiate).
- A fix would require violating one of the Mission Boundaries in `AGENTS.md` (e.g., removing the preserved NSLog debug lines, modifying the Cactus XCFramework, pushing to remote).
