//
// TacNetUITests.swift
//
// Automated XCUITest smoke walkthrough of every reachable non-BLE screen in the
// TacNet iOS app. Drives the app on the iPhone 17 Simulator via launch
// arguments that bypass the 6.7 GB model download gate and routes to
// synthetic hosts for screens that require real BLE (e.g. PIN entry).
//
// Mapped to validation contract assertions VAL-UI-001 through VAL-UI-013.
//

import XCTest

final class TacNetUISmokeTests: XCTestCase {

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func makeApp(
        route: String? = nil,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-test-skip-download"]
        if let route {
            args.append("--ui-test-route=\(route)")
        }
        args.append(contentsOf: additionalArguments)
        app.launchArguments = args
        return app
    }

    private func saveScreenshot(_ app: XCUIApplication, named name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForExistence(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        message: String = ""
    ) {
        let exists = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(
            exists,
            "\(message) Element \(element) was not found within \(timeout)s"
        )
    }

    /// Resolves an accessibility identifier irrespective of XCUIElement type (Other,
    /// ScrollView, StaticText, etc.) which depends on how SwiftUI composes the view.
    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    // MARK: - VAL-UI-001 · App launch, no crash, UI visible within 5s

    func testAppLaunchesAndRemainsAliveWithVisibleUI() {
        let app = makeApp()
        app.launch()

        let welcomeRoot = app.otherElements["tacnet.welcome.root"]
        waitForExistence(welcomeRoot, timeout: 8, message: "Welcome did not render after launch.")
        saveScreenshot(app, named: "launch-welcome")

        // App should remain alive for at least 15 seconds with UI still visible.
        let totalWaitSeconds: TimeInterval = 15
        let startDate = Date()
        while Date().timeIntervalSince(startDate) < totalWaitSeconds {
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "App left foreground state before \(totalWaitSeconds)s"
            )
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 1)
        }
        saveScreenshot(app, named: "launch-after-15s")
    }

    // MARK: - VAL-UI-002 · Real bootstrap/download gate renders with accurate gating UI

    /// Launches the app WITHOUT `--ui-test-skip-download`, using the deterministic
    /// `stuck` download fixture so the gate remains visible for the full test window.
    /// Asserts that the real `downloadGate` rendering satisfies VAL-UI-002:
    /// * gate container, title, progress bar are visible
    /// * "TacNet features are locked…" copy is visible
    /// * retry button is hidden until an error occurs
    /// * the app does not crash for ≥10 seconds on the download screen
    func testBootstrapDownloadGateRendersAndGatingUIIsAccurate() {
        let app = XCUIApplication()
        // NOTE: no --ui-test-skip-download. The `stuck` fixture keeps the gate
        // visible at 0% progress forever without pulling the real 6.7 GB payload.
        app.launchArguments = ["--ui-test-download-fixture=stuck"]
        app.launch()

        let gateRoot = app.otherElements["tacnet.downloadGate.root"]
        waitForExistence(gateRoot, timeout: 10, message: "Download gate did not render.")
        saveScreenshot(app, named: "download-gate-initial")

        // Title + progress bar + locked-copy must be visible on the gate.
        let title = anyElement(app, identifier: "tacnet.downloadGate.title")
        waitForExistence(title, timeout: 4, message: "Download gate title label is missing.")
        let progressBar = anyElement(app, identifier: "tacnet.downloadGate.progressBar")
        waitForExistence(progressBar, timeout: 4, message: "Download gate progress bar is missing.")
        let lockedCopy = anyElement(app, identifier: "tacnet.downloadGate.lockedCopy")
        waitForExistence(lockedCopy, timeout: 4, message: "Download gate locked-features copy is missing.")

        // Retry button is error-only; it must NOT exist while there is no error.
        let retryButton = app.buttons["tacnet.downloadGate.retryButton"]
        XCTAssertFalse(
            retryButton.exists,
            "Retry button should be hidden when no error has been surfaced."
        )

        // App must not crash for at least 10 seconds while the gate holds.
        let totalWaitSeconds: TimeInterval = 10
        let startDate = Date()
        while Date().timeIntervalSince(startDate) < totalWaitSeconds {
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "App left foreground state before \(totalWaitSeconds)s on the download gate."
            )
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 1)
        }

        // Gate remains visible after the 10s hold and still no retry button.
        XCTAssertTrue(gateRoot.exists, "Download gate disappeared before the 10s hold elapsed.")
        XCTAssertFalse(
            app.buttons["tacnet.downloadGate.retryButton"].exists,
            "Retry button became visible unexpectedly during the 10s gate hold."
        )
        saveScreenshot(app, named: "download-gate-after-10s")
    }

    // MARK: - VAL-UI-002 · Initial screen renders appropriately

    func testInitialScreenRendersWithoutBlankState() {
        let app = makeApp()
        app.launch()

        let welcomeRoot = app.otherElements["tacnet.welcome.root"]
        waitForExistence(welcomeRoot, timeout: 8)

        // Welcome screen must expose both affordances once the download gate is bypassed.
        XCTAssertTrue(app.buttons["tacnet.welcome.createNetworkButton"].exists)
        XCTAssertTrue(app.buttons["tacnet.welcome.joinNetworkButton"].exists)
        saveScreenshot(app, named: "initial-welcome")
    }

    // MARK: - VAL-UI-003 · Welcome navigates to Create and Join

    func testWelcomeNavigatesToCreateAndJoin() {
        let app = makeApp()
        app.launch()
        let createButton = app.buttons["tacnet.welcome.createNetworkButton"]
        let joinButton = app.buttons["tacnet.welcome.joinNetworkButton"]
        waitForExistence(createButton)

        // Tap Create Network — should navigate to Tree Builder.
        createButton.tap()
        let treeBuilderRoot = app.scrollViews["tacnet.treeBuilder.root"]
            .firstMatch.exists ? app.scrollViews["tacnet.treeBuilder.root"] : app.otherElements["tacnet.treeBuilder.root"]
        // Fall back to existence check via any Tree Builder control we know is present.
        let addChildButton = app.buttons["tacnet.treeBuilder.addChildButton"]
        waitForExistence(addChildButton, timeout: 6, message: "Tree Builder did not render.")
        saveScreenshot(app, named: "create-network-treebuilder")

        // Back to welcome.
        let backButton = app.buttons["tacnet.treeBuilder.backButton"]
        if backButton.exists {
            backButton.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        waitForExistence(joinButton, timeout: 6, message: "Welcome did not re-appear after Tree Builder back.")

        // Tap Join Network — should navigate to Network Scan.
        joinButton.tap()
        let scanRoot = app.otherElements["tacnet.scan.root"]
        waitForExistence(scanRoot, timeout: 6, message: "Network Scan did not render.")
        saveScreenshot(app, named: "join-network-scan")
    }

    // MARK: - VAL-UI-004 · Tree Builder add/rename/remove flow

    func testTreeBuilderAddRenameRemoveCycle() {
        let app = makeApp()
        app.launch()
        app.buttons["tacnet.welcome.createNetworkButton"].tap()

        let addChildButton = app.buttons["tacnet.treeBuilder.addChildButton"]
        waitForExistence(addChildButton, timeout: 6)
        saveScreenshot(app, named: "treebuilder-empty")

        // Add a child node.
        let newChildField = app.textFields["tacnet.treeBuilder.newChildField"]
        waitForExistence(newChildField)
        newChildField.tap()
        newChildField.typeText("Alpha")
        addChildButton.tap()
        saveScreenshot(app, named: "treebuilder-after-add")
        XCTAssertTrue(
            app.staticTexts["Alpha"].waitForExistence(timeout: 4),
            "Newly added child 'Alpha' did not appear in the tree."
        )

        // Rename the selected node (the just-added child is auto-selected).
        let renameField = app.textFields["tacnet.treeBuilder.renameField"]
        waitForExistence(renameField)
        renameField.tap()
        // Clear existing text by selecting all then typing.
        if let existing = renameField.value as? String, !existing.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
            renameField.typeText(deleteString)
        }
        renameField.typeText("Bravo")
        app.buttons["tacnet.treeBuilder.renameButton"].tap()
        saveScreenshot(app, named: "treebuilder-after-rename")
        XCTAssertTrue(
            app.staticTexts["Bravo"].waitForExistence(timeout: 4),
            "Renamed node 'Bravo' did not appear in the tree."
        )

        // Remove the node.
        app.buttons["tacnet.treeBuilder.removeButton"].tap()
        saveScreenshot(app, named: "treebuilder-after-remove")
        // After removal the 'Bravo' label should be gone.
        let bravoGone = !app.staticTexts["Bravo"].waitForExistence(timeout: 2)
        XCTAssertTrue(bravoGone, "Removed node 'Bravo' is still visible in the tree.")
    }

    // MARK: - VAL-UI-005 · Network Scan empty state

    func testNetworkScanRendersEmptyStateWithoutBLE() {
        let app = makeApp()
        app.launch()
        app.buttons["tacnet.welcome.joinNetworkButton"].tap()

        let scanRoot = app.otherElements["tacnet.scan.root"]
        waitForExistence(scanRoot, timeout: 6)
        saveScreenshot(app, named: "scan-empty")

        // Rescan and back should not crash.
        let rescan = app.buttons["tacnet.scan.rescanButton"]
        waitForExistence(rescan)
        rescan.tap()
        saveScreenshot(app, named: "scan-after-rescan")

        app.buttons["tacnet.scan.backButton"].tap()
        waitForExistence(
            app.buttons["tacnet.welcome.createNetworkButton"],
            timeout: 4,
            message: "Did not return to Welcome after Back from Scan."
        )
    }

    // MARK: - VAL-UI-006 · PIN entry renders and accepts input

    func testPinEntryRendersAndAcceptsDigits() {
        let app = makeApp(route: "pin-entry")
        app.launch()

        let pinField = app.secureTextFields["tacnet.pin.field"]
        waitForExistence(pinField, timeout: 6, message: "Pin entry field did not render.")
        saveScreenshot(app, named: "pin-entry")

        pinField.tap()
        pinField.typeText("1234")

        let submit = app.buttons["tacnet.pin.submitButton"]
        waitForExistence(submit)
        submit.tap()

        // Our UI-test host surfaces the submitted value for verification.
        let submitted = app.staticTexts["tacnet.pin.submittedValue"]
        waitForExistence(submitted, timeout: 4, message: "Pin submission did not reach host observer.")
        saveScreenshot(app, named: "pin-entry-submitted")
    }

    // MARK: - VAL-UI-007 · Role Selection with seeded tree

    func testRoleSelectionRendersSeededTreeAndClaimControl() {
        let app = launchAndPublishSeededNetwork()

        let roleRoot = app.otherElements["tacnet.roleSelection.root"]
        waitForExistence(roleRoot, timeout: 8, message: "Role Selection did not render.")
        saveScreenshot(app, named: "role-selection")

        // Seeded tree has a root + at least one claimable child (we added one).
        let alphaRow = app.staticTexts["Alpha"]
        XCTAssertTrue(
            alphaRow.waitForExistence(timeout: 4),
            "Role Selection does not show seeded 'Alpha' node."
        )

        // The Back button should always be present.
        XCTAssertTrue(app.buttons["tacnet.roleSelection.backButton"].exists)
    }

    // MARK: - VAL-UI-008 through VAL-UI-012 · Tabs render and switch without crash

    func testMainTreeDataFlowSettingsTabsRenderAndSwitch() {
        let app = launchAndPublishSeededNetwork()

        // Claim the seeded child node to reach the main tab shell. The row's
        // accessibility identifier is "tacnet.roleSelection.row.<nodeID>";
        // we locate it by the visible label we set (Alpha) inside any matching
        // button cell.
        let alphaStaticText = app.staticTexts["Alpha"]
        waitForExistence(alphaStaticText, timeout: 8)

        // Tap the enclosing button cell for reliability.
        let claimableCell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tacnet.roleSelection.row.")).element(matching: NSPredicate(format: "label CONTAINS %@", "Alpha"))
        if claimableCell.exists {
            claimableCell.tap()
        } else {
            alphaStaticText.tap()
        }
        saveScreenshot(app, named: "after-claim-tap")

        let tabBar = app.tabBars.firstMatch
        waitForExistence(tabBar, timeout: 12, message: "Tab bar did not appear after role claim.")

        // Main tab — PTT button interacts without crash.
        let mainTab = tabBar.buttons["Main"]
        waitForExistence(mainTab)
        mainTab.tap()
        let mainRoot = anyElement(app, identifier: "tacnet.main.root")
        waitForExistence(mainRoot, timeout: 6, message: "Main tab did not render.")
        saveScreenshot(app, named: "tab-main")

        // The PTT control is combined into a single element — look up by id.
        let pttControl = anyElement(app, identifier: "tacnet.main.pttControl")
        waitForExistence(pttControl, timeout: 6, message: "PTT control did not render on Main tab.")
        // Press (no crash expected even if mesh is disconnected — must NOT hang).
        pttControl.press(forDuration: 0.3)
        saveScreenshot(app, named: "tab-main-after-ptt")

        // Tree tab.
        let treeTab = tabBar.buttons["Tree View"]
        if treeTab.exists {
            treeTab.tap()
        }
        waitForExistence(anyElement(app, identifier: "tacnet.tree.root"), timeout: 4, message: "Tree tab did not render.")
        saveScreenshot(app, named: "tab-tree")

        // Data Flow tab.
        let dataFlowTab = tabBar.buttons["Data Flow"]
        if dataFlowTab.exists {
            dataFlowTab.tap()
        }
        waitForExistence(anyElement(app, identifier: "tacnet.dataflow.root"), timeout: 4, message: "Data Flow tab did not render.")
        XCTAssertTrue(app.staticTexts["INCOMING"].exists, "Data Flow tab missing INCOMING section header")
        XCTAssertTrue(app.staticTexts["PROCESSING"].exists, "Data Flow tab missing PROCESSING section header")
        XCTAssertTrue(app.staticTexts["OUTGOING"].exists, "Data Flow tab missing OUTGOING section header")
        saveScreenshot(app, named: "tab-dataflow")

        // Settings tab.
        let settingsTab = tabBar.buttons["Settings"]
        if settingsTab.exists {
            settingsTab.tap()
        }
        waitForExistence(anyElement(app, identifier: "tacnet.settings.root"), timeout: 4, message: "Settings tab did not render.")
        saveScreenshot(app, named: "tab-settings")

        // Cycle back through tabs in another order — no crash expected.
        mainTab.tap()
        waitForExistence(anyElement(app, identifier: "tacnet.main.root"), timeout: 4)
        if dataFlowTab.exists { dataFlowTab.tap() }
        waitForExistence(anyElement(app, identifier: "tacnet.dataflow.root"), timeout: 4)
        if treeTab.exists { treeTab.tap() }
        waitForExistence(anyElement(app, identifier: "tacnet.tree.root"), timeout: 4)
        if settingsTab.exists { settingsTab.tap() }
        waitForExistence(anyElement(app, identifier: "tacnet.settings.root"), timeout: 4)
        saveScreenshot(app, named: "tab-cycle-final")

        // App must still be running after the full walk.
        XCTAssertEqual(app.state, .runningForeground, "App is not running after full tab walkthrough.")
    }

    // MARK: - VAL-UI-011 · Settings role-appropriate affordances

    /// Covers VAL-UI-011: organiser sees tree-editor entry + promote + release-role,
    /// while a participant sees only release-role (organiser-only controls hidden).
    /// Uses the `--ui-test-route=settings` host with `--ui-test-role=<role>` to seed
    /// a deterministic network state without depending on BLE discovery.
    func testSettingsTabShowsRoleAppropriateAffordances() {
        // --- Organiser: all three affordances visible.
        let organiserApp = XCUIApplication()
        organiserApp.launchArguments = [
            "--ui-test-route=settings",
            "--ui-test-role=organiser",
        ]
        organiserApp.launch()

        let organiserSettingsRoot = anyElement(organiserApp, identifier: "tacnet.settings.root")
        waitForExistence(
            organiserSettingsRoot,
            timeout: 10,
            message: "Settings root did not render in organiser host."
        )
        let organiserEditTree = organiserApp.buttons["tacnet.settings.editTreeButton"]
        let organiserPromote = organiserApp.buttons["tacnet.settings.promoteButton"]
        let organiserRelease = organiserApp.buttons["tacnet.settings.releaseRoleButton"]
        XCTAssertTrue(
            organiserEditTree.waitForExistence(timeout: 4),
            "Organiser should see Edit Tree button in Settings."
        )
        XCTAssertTrue(
            organiserPromote.waitForExistence(timeout: 4),
            "Organiser should see Promote button in Settings."
        )
        XCTAssertTrue(
            organiserRelease.waitForExistence(timeout: 4),
            "Organiser should see Release Role button in Settings."
        )
        saveScreenshot(organiserApp, named: "settings-organiser")
        organiserApp.terminate()

        // --- Participant: only release-role visible; organiser controls hidden.
        let participantApp = XCUIApplication()
        participantApp.launchArguments = [
            "--ui-test-route=settings",
            "--ui-test-role=participant",
        ]
        participantApp.launch()

        let participantSettingsRoot = anyElement(participantApp, identifier: "tacnet.settings.root")
        waitForExistence(
            participantSettingsRoot,
            timeout: 10,
            message: "Settings root did not render in participant host."
        )
        let participantRelease = participantApp.buttons["tacnet.settings.releaseRoleButton"]
        XCTAssertTrue(
            participantRelease.waitForExistence(timeout: 4),
            "Participant should see Release Role button in Settings."
        )
        XCTAssertFalse(
            participantApp.buttons["tacnet.settings.editTreeButton"].exists,
            "Participant must NOT see Edit Tree button in Settings."
        )
        XCTAssertFalse(
            participantApp.buttons["tacnet.settings.promoteButton"].exists,
            "Participant must NOT see Promote button in Settings."
        )
        saveScreenshot(participantApp, named: "settings-participant")
        participantApp.terminate()
    }

    // MARK: - VAL-PTT-002 / VAL-PTT-003 · PTT button gesture dispatch + no gesture gate timeout

    /// Regression for the user-reported live-device bug where pressing and holding the PTT
    /// button on the Main tab produced zero `[PTT]` NSLog output, because the legacy
    /// `DragGesture(minimumDistance: 0)` on `pttControl` lost gesture arbitration to the
    /// parent `TabView` swipe gesture and triggered the iOS
    /// `Gesture: System gesture gate timed out.` log.
    ///
    /// Uses the `--ui-test-route=main-ptt` host, which hosts a stripped-down `PTTButton`
    /// wired to on-screen counters (`tacnet.main.pttDebugBegan` / `tacnet.main.pttDebugEnded`)
    /// so we can assert exactly-one press-began + exactly-one press-ended delivered from a
    /// real `press(forDuration:)` (not a synthetic `tap()`).
    func testPTTButtonLongPressDispatchesToViewModel() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-route=main-ptt"]
        app.launch()

        let hostRoot = anyElement(app, identifier: "tacnet.uiTestRoute.mainPTT.root")
        waitForExistence(hostRoot, timeout: 8, message: "main-ptt host did not render.")

        let pttButton = anyElement(app, identifier: "tacnet.main.pttButton")
        waitForExistence(pttButton, timeout: 6, message: "PTTButton did not render in main-ptt host.")

        // Snapshot counters before interaction — both counters should report 0.
        let beganLabel = anyElement(app, identifier: "tacnet.main.pttDebugBegan")
        let endedLabel = anyElement(app, identifier: "tacnet.main.pttDebugEnded")
        waitForExistence(beganLabel, timeout: 4, message: "pttDebugBegan counter did not render.")
        waitForExistence(endedLabel, timeout: 4, message: "pttDebugEnded counter did not render.")
        XCTAssertEqual(beganLabel.label, "Began:0", "Began counter should start at 0 before any press.")
        XCTAssertEqual(endedLabel.label, "Ended:0", "Ended counter should start at 0 before any press.")

        saveScreenshot(app, named: "ptt-dispatch-before-press")

        // Real long-press (not a synthetic tap()). 1.5s is well past the 0.5s iOS
        // long-press default threshold and is the duration called out in the
        // validation contract assertion VAL-PTT-003.
        pttButton.press(forDuration: 1.5)

        // Wait up to 2s for the counter labels to update to exactly 1.
        let beganFiredPredicate = NSPredicate(format: "label == %@", "Began:1")
        let endedFiredPredicate = NSPredicate(format: "label == %@", "Ended:1")
        let beganExpectation = expectation(for: beganFiredPredicate, evaluatedWith: beganLabel)
        let endedExpectation = expectation(for: endedFiredPredicate, evaluatedWith: endedLabel)
        let result = XCTWaiter.wait(for: [beganExpectation, endedExpectation], timeout: 2.0)
        XCTAssertEqual(
            result,
            .completed,
            "PTTButton press-began / press-ended counters did not both reach 1 within 2s after press(forDuration: 1.5). \(beganLabel.label) | \(endedLabel.label)"
        )

        XCTAssertEqual(
            beganLabel.label,
            "Began:1",
            "press-began handler must fire exactly once per physical press."
        )
        XCTAssertEqual(
            endedLabel.label,
            "Ended:1",
            "press-ended handler must fire exactly once per physical release."
        )

        saveScreenshot(app, named: "ptt-dispatch-after-press")
    }

    /// VAL-PTT-003 companion: performs a press-hold-release cycle on the PTTButton and
    /// asserts that the gesture is NOT swallowed by any ancestor gesture recognizer (which
    /// would manifest as the iOS `Gesture: System gesture gate timed out.` console line
    /// and dropped / duplicated press events).
    ///
    /// Because XCUITest runs in an iOS test-runner sandbox that cannot spawn host-side
    /// `xcrun simctl spawn booted log stream`, this test uses a behavioral proxy that
    /// is strictly equivalent on the SwiftUI gesture layer: two back-to-back `press(forDuration:)`
    /// cycles MUST each deliver exactly one press-began + one press-ended event (total
    /// Began:2 / Ended:2) with no missed or duplicated events. A gesture-gate timeout would
    /// produce a mismatch (0 or 2 on the first, or asymmetric counts), and the real
    /// `[PTT] Button press-began` / `[PTT] Button press-ended` NSLog lines emitted by
    /// `PTTButtonStyle` remain visible in `Console.app` for on-device verification.
    func testPTTButtonGestureDoesNotProduceGestureGateTimeout() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-route=main-ptt"]
        app.launch()

        let pttButton = anyElement(app, identifier: "tacnet.main.pttButton")
        waitForExistence(pttButton, timeout: 8, message: "PTTButton did not render.")
        let beganLabel = anyElement(app, identifier: "tacnet.main.pttDebugBegan")
        let endedLabel = anyElement(app, identifier: "tacnet.main.pttDebugEnded")
        waitForExistence(beganLabel, timeout: 4)
        waitForExistence(endedLabel, timeout: 4)
        XCTAssertEqual(beganLabel.label, "Began:0")
        XCTAssertEqual(endedLabel.label, "Ended:0")

        // First press-hold-release cycle — must tick the counters to 1/1.
        pttButton.press(forDuration: 1.5)
        let firstBegan = expectation(
            for: NSPredicate(format: "label == %@", "Began:1"),
            evaluatedWith: beganLabel
        )
        let firstEnded = expectation(
            for: NSPredicate(format: "label == %@", "Ended:1"),
            evaluatedWith: endedLabel
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [firstBegan, firstEnded], timeout: 2.0),
            .completed,
            "First press(forDuration:) did not deliver one began + one ended within 2s — gesture likely timed out at the iOS gate. \(beganLabel.label) | \(endedLabel.label)"
        )
        saveScreenshot(app, named: "ptt-gate-after-first-press")

        // Second press-hold-release cycle — counters should advance to 2/2. If the iOS
        // gesture gate had timed out on the first cycle, the second gesture is typically
        // swallowed too; counts would remain at 1/1.
        pttButton.press(forDuration: 1.5)
        let secondBegan = expectation(
            for: NSPredicate(format: "label == %@", "Began:2"),
            evaluatedWith: beganLabel
        )
        let secondEnded = expectation(
            for: NSPredicate(format: "label == %@", "Ended:2"),
            evaluatedWith: endedLabel
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [secondBegan, secondEnded], timeout: 2.0),
            .completed,
            "Second press(forDuration:) did not deliver one began + one ended within 2s. \(beganLabel.label) | \(endedLabel.label)"
        )
        saveScreenshot(app, named: "ptt-gate-after-second-press")

        XCTAssertEqual(
            beganLabel.label,
            "Began:2",
            "After two press cycles, press-began must fire exactly twice total (once per cycle, no swallowed events)."
        )
        XCTAssertEqual(
            endedLabel.label,
            "Ended:2",
            "After two press cycles, press-ended must fire exactly twice total (once per cycle, no swallowed events)."
        )
    }

    // MARK: - VAL-PTT-002 / VAL-PTT-003 · Real Main-tab coverage with console-log evidence

    /// VAL-PTT-002 regression on the REAL Main tab (no `--ui-test-route=main-ptt`
    /// synthetic host): launches the app through the normal bootstrap, walks the
    /// full Welcome → Create Network → Tree Builder → Publish → Role Selection →
    /// Claim flow until the live `TabView`/`NavigationStack` Main tab appears,
    /// performs a 1.5 s `press(forDuration:)` on the REAL `tacnet.main.pttButton`,
    /// and captures the in-process unified log via `UITestLogCapture` (activated
    /// via `--ui-test-capture-logs`). Seeds a single fake connected peer with
    /// `--ui-test-mesh-peers=1` so the view model takes the happy (connected)
    /// path and the `[PTT] Recording started…` line is emitted.
    ///
    /// Covers the VAL-PTT-002 evidence requirement: captured console log must
    /// contain at least one `[PTT]` line AND must NOT contain `Gesture: System
    /// gesture gate timed out`.
    func testPTTButtonLongPressOnRealMainTabDispatchesToViewModel() {
        let app = launchAndReachRealMainTab(
            additionalArguments: ["--ui-test-mesh-peers=1", "--ui-test-capture-logs"]
        )
        saveScreenshot(app, named: "real-main-tab-before-press")

        let pttButton = anyElement(app, identifier: "tacnet.main.pttButton")
        waitForExistence(pttButton, timeout: 8, message: "Real PTTButton did not render on Main tab.")

        // Single 1.5 s press on the real PTTButton — this is the contracted
        // `press(forDuration:)` call out of the validation contract.
        pttButton.press(forDuration: 1.5)

        let capturedLog = waitForPTTLogBufferToContainPTTLine(app: app, timeout: 4.0)
        attachCapturedLog(capturedLog, named: "real-main-tab-single-press.log")
        saveScreenshot(app, named: "real-main-tab-after-press")

        assertCapturedLogHasPTTEvidence(capturedLog)
        XCTAssertFalse(
            capturedLog.contains("Gesture: System gesture gate timed out"),
            "Captured log unexpectedly contains the iOS gesture-gate timeout marker:\n\(capturedLog)"
        )
    }

    /// VAL-PTT-003 regression on the REAL Main tab: performs two back-to-back
    /// `press(forDuration: 1.5)` cycles on the live `tacnet.main.pttButton` hosted
    /// inside the real `TabView` + `NavigationStack`, then asserts that the
    /// captured in-process log contains ≥2 press-began `[PTT]` lines, ≥2
    /// press-ended `[PTT]` lines, and zero `Gesture: System gesture gate timed
    /// out` entries.
    ///
    /// Uses the disconnected (gated) path deliberately — no
    /// `--ui-test-mesh-peers=1` — so the second form of `[PTT]` log line (the
    /// `❌ Rejected — disconnected from mesh` gated-path message) is exercised
    /// for evidence, complementing the happy-path coverage in
    /// `testPTTButtonLongPressOnRealMainTabDispatchesToViewModel`.
    func testPTTButtonGestureOnRealMainTabNoGateTimeoutAcrossRepeatedPresses() {
        let app = launchAndReachRealMainTab(
            additionalArguments: ["--ui-test-capture-logs"]
        )

        let pttButton = anyElement(app, identifier: "tacnet.main.pttButton")
        waitForExistence(pttButton, timeout: 8)

        // First cycle.
        pttButton.press(forDuration: 1.5)
        _ = waitForPTTLogBufferToContainPTTLine(app: app, timeout: 4.0)
        saveScreenshot(app, named: "real-main-tab-after-first-press")

        // Second cycle — if the iOS gesture gate had timed out on cycle #1, this
        // press typically also gets swallowed, so counters remain unchanged and
        // the assertion below fails.
        pttButton.press(forDuration: 1.5)
        let capturedLog = waitForPTTLogBufferEntryCount(
            app: app,
            minimumPressBeganLines: 2,
            minimumPressEndedLines: 2,
            timeout: 4.0
        )
        attachCapturedLog(capturedLog, named: "real-main-tab-repeated-press.log")
        saveScreenshot(app, named: "real-main-tab-after-second-press")

        // Validate the captured buffer: at least 2 press-began + at least 2
        // press-ended PTT lines, and zero system-generated gesture-gate timeouts.
        let pressBeganCount = countOccurrences(
            of: "[PTT] Button press-began",
            in: capturedLog
        )
        let pressEndedCount = countOccurrences(
            of: "[PTT] Button press-ended",
            in: capturedLog
        )
        XCTAssertGreaterThanOrEqual(
            pressBeganCount,
            2,
            "Captured log must contain at least 2 press-began `[PTT]` lines for 2 presses. Got:\n\(capturedLog)"
        )
        XCTAssertGreaterThanOrEqual(
            pressEndedCount,
            2,
            "Captured log must contain at least 2 press-ended `[PTT]` lines for 2 presses. Got:\n\(capturedLog)"
        )
        XCTAssertFalse(
            capturedLog.contains("Gesture: System gesture gate timed out"),
            "Captured log unexpectedly contains the iOS gesture-gate timeout marker after 2 presses:\n\(capturedLog)"
        )
    }

    // MARK: - Helpers for seeded flow

    /// Launches the app, walks Welcome → Create Network → Tree Builder, adds one child,
    /// publishes the network, and returns the app handle at the Role Selection screen.
    private func launchAndPublishSeededNetwork() -> XCUIApplication {
        let app = makeApp()
        app.launch()

        app.buttons["tacnet.welcome.createNetworkButton"].tap()

        let addChildButton = app.buttons["tacnet.treeBuilder.addChildButton"]
        waitForExistence(addChildButton, timeout: 8)

        let newChildField = app.textFields["tacnet.treeBuilder.newChildField"]
        waitForExistence(newChildField)
        newChildField.tap()
        newChildField.typeText("Alpha")
        addChildButton.tap()

        let publishButton = app.buttons["tacnet.treeBuilder.publishButton"]
        waitForExistence(publishButton, timeout: 4)
        publishButton.tap()

        return app
    }

    /// Boots the app into the REAL Main tab (no synthetic route): walks Welcome →
    /// Create Network → Tree Builder (adds Alpha) → Publish → Role Selection →
    /// Claim Alpha → TabView with Main tab selected. Returns the live app handle
    /// with the real `ContentView.TabView` + `NavigationStack` hierarchy. Any
    /// additional launch args (e.g. `--ui-test-mesh-peers=1`,
    /// `--ui-test-capture-logs`) are forwarded to the launch.
    private func launchAndReachRealMainTab(additionalArguments: [String] = []) -> XCUIApplication {
        let app = makeApp(additionalArguments: additionalArguments)
        app.launch()

        // Welcome → Create Network.
        let createButton = app.buttons["tacnet.welcome.createNetworkButton"]
        waitForExistence(createButton, timeout: 10, message: "Welcome did not render on real launch.")
        createButton.tap()

        // Tree Builder → add Alpha.
        let addChildButton = app.buttons["tacnet.treeBuilder.addChildButton"]
        waitForExistence(addChildButton, timeout: 8, message: "Tree Builder did not render.")
        let newChildField = app.textFields["tacnet.treeBuilder.newChildField"]
        waitForExistence(newChildField)
        newChildField.tap()
        newChildField.typeText("Alpha")
        addChildButton.tap()

        // Publish.
        let publishButton = app.buttons["tacnet.treeBuilder.publishButton"]
        waitForExistence(publishButton, timeout: 4)
        publishButton.tap()

        // Role Selection → claim Alpha so we reach the real Tab shell.
        let alphaStaticText = app.staticTexts["Alpha"]
        waitForExistence(alphaStaticText, timeout: 8, message: "Role Selection did not render Alpha row.")
        let claimableCell = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "tacnet.roleSelection.row."))
            .element(matching: NSPredicate(format: "label CONTAINS %@", "Alpha"))
        if claimableCell.exists {
            claimableCell.tap()
        } else {
            alphaStaticText.tap()
        }

        // Verify the real Tab shell is live (TabView + Main tab reachable).
        let tabBar = app.tabBars.firstMatch
        waitForExistence(tabBar, timeout: 12, message: "Real TabView did not appear after Role claim.")
        let mainTab = tabBar.buttons["Main"]
        if mainTab.exists {
            mainTab.tap()
        }
        let mainRoot = anyElement(app, identifier: "tacnet.main.root")
        waitForExistence(mainRoot, timeout: 6, message: "Real Main tab did not render.")
        return app
    }

    /// Taps the hidden debug-refresh button (installed when `--ui-test-capture-logs`
    /// is passed) so the in-app `UITestLogCapture` pulls fresh OSLogStore entries,
    /// then returns the current `tacnet.debug.logBuffer` text. Waits up to `timeout`
    /// seconds for at least one `[PTT]` line to land in the buffer.
    private func waitForPTTLogBufferToContainPTTLine(
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> String {
        let refreshButton = app.buttons["tacnet.debug.refreshLogBuffer"]
        if refreshButton.exists {
            refreshButton.tap()
        }
        let buffer = anyElement(app, identifier: "tacnet.debug.logBuffer")
        waitForExistence(buffer, timeout: 4, message: "PTT debug log buffer did not render.")

        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot = buffer.label
        while Date() < deadline {
            lastSnapshot = buffer.label
            if lastSnapshot.contains("[PTT]") {
                return lastSnapshot
            }
            if refreshButton.exists {
                refreshButton.tap()
            }
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.25)
        }
        if refreshButton.exists {
            refreshButton.tap()
        }
        return buffer.label
    }

    /// Polls the log buffer until at least `minimumPressBeganLines` press-began
    /// `[PTT]` lines and `minimumPressEndedLines` press-ended `[PTT]` lines are
    /// present, or the timeout elapses.
    private func waitForPTTLogBufferEntryCount(
        app: XCUIApplication,
        minimumPressBeganLines: Int,
        minimumPressEndedLines: Int,
        timeout: TimeInterval
    ) -> String {
        let refreshButton = app.buttons["tacnet.debug.refreshLogBuffer"]
        let buffer = anyElement(app, identifier: "tacnet.debug.logBuffer")
        waitForExistence(buffer, timeout: 4, message: "PTT debug log buffer did not render.")

        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot = buffer.label
        while Date() < deadline {
            lastSnapshot = buffer.label
            let began = countOccurrences(of: "[PTT] Button press-began", in: lastSnapshot)
            let ended = countOccurrences(of: "[PTT] Button press-ended", in: lastSnapshot)
            if began >= minimumPressBeganLines, ended >= minimumPressEndedLines {
                return lastSnapshot
            }
            if refreshButton.exists {
                refreshButton.tap()
            }
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.25)
        }
        return buffer.label
    }

    private func countOccurrences(of substring: String, in text: String) -> Int {
        guard !substring.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: substring, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// Attaches the captured log string to the XCTest run so the evidence can be
    /// inspected in the .xcresult bundle per VAL-PTT-002 / VAL-PTT-003.
    private func attachCapturedLog(_ log: String, named name: String) {
        let attachment = XCTAttachment(string: log)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertCapturedLogHasPTTEvidence(_ log: String) {
        // Require at least one `[PTT]` line as the validation-contract evidence.
        let hasPTTLine = log.contains("[PTT]")
        XCTAssertTrue(
            hasPTTLine,
            "Captured log must contain at least one `[PTT]` line during the real-Main-tab press interaction. Got:\n\(log)"
        )
    }
}
