# TacNet -- Linear Project Structure

> Copy-paste these into Linear to create issues for your team.
> Workspace: yc-hack | Team: YC | Project: TacNet

---

## PROJECT OVERVIEW

**TacNet**: Decentralized tactical communication app (iOS) with on-device AI summarization via Gemma 4 E4B / Cactus SDK over BLE mesh.

**Current Status**: All 22 implementation features DONE. 119 unit tests passing. Manual device testing pending.

**Repo**: https://github.com/Nalin-Atmakur/YC-hack (main branch)

**Key Files**:
- `Orchestrator.md` -- Full system spec
- `DECISIONS.md` -- 21 design decisions
- `SETUP_LOG.md` -- SDK/model setup notes
- `MANUAL_TESTING.md` -- Step-by-step device testing guide (53 assertions)
- `TacNet.xcodeproj` -- Xcode project

---

## COMPLETED FEATURES (mark as Done in Linear)

### Milestone 1: Foundation

**YC-F01: Xcode Project Setup** [Done]
- Created TacNet.xcodeproj with SwiftUI, iOS 16+ target
- Integrated Cactus SDK XCFramework + Cactus.swift
- Added CoreBluetooth, AVFoundation, CoreLocation, SwiftData frameworks
- Info.plist permissions for Bluetooth, Microphone, Location

**YC-F02: Data Models** [Done]
- TreeNode, NetworkConfig, Message envelope, NodeIdentity (all Codable)
- Version-based convergence logic
- GPS coordinate embedding in all messages
- 9 unit tests passing

**YC-F03: Tree Helpers & Message Deduplicator** [Done]
- parent/siblings/children/level lookup utilities
- UUID-based seen-set with bounded growth (ring buffer, capacity 50k)
- 17 tests passing (cumulative)

**YC-F04: BLE Mesh Service** [Done]
- CBCentralManager + CBPeripheralManager running simultaneously
- TacNet service UUID, GATT characteristics (broadcast, compaction, tree config)
- Message flooding with UUID dedup and TTL decrement/drop
- Connection state tracking per peer
- 24 tests passing (cumulative)

**YC-F05: Model Download Service** [Done]
- Checks storage before download, progress [0.0-1.0] with resume support
- Download gate blocks app until complete
- Cactus SDK init wrapper
- Mock URLSession tests for progress, storage, gate logic

### Milestone 2: Tree & Roles

**YC-F06: Tree Builder & Network Config** [Done]
- TreeBuilderView: add/remove/rename nodes, set network name + PIN
- Version increments per operation
- WelcomeView: Create Network / Join Network flow
- Tests for all operations including edge cases (empty tree, deep tree, Unicode labels)

**YC-F07: Network Discovery & Join** [Done]
- BLE scan for nearby networks (name, open slots)
- PIN authentication gate (wrong PIN rejected, PIN-less direct join)
- Full tree JSON transfer via BLE on join
- Version-based convergence (higher wins, out-of-order handled)
- 41 tests passing (cumulative)

**YC-F08: Role Claiming Protocol** [Done]
- CLAIM/RELEASE/CLAIM_REJECTED message handling
- RoleSelectionView with claimed/open status
- Organiser-wins conflict resolution
- Auto-release after 60s BLE disconnect
- 47 tests passing (cumulative)

**YC-F09: Live Tree Modification** [Done]
- Add/remove/rename/move nodes post-publish with TREE_UPDATE broadcast
- Remove claimed node kicks user with notification
- PROMOTE message for organiser transfer
- Claim preservation on unrelated edits

### Milestone 3: Communications Core

**YC-F10: PTT & Transcription** [Done]
- AVAudioEngine recording (16kHz mono 16-bit PCM)
- cactusTranscribe integration
- Empty/silence audio filtering, long audio cap, rapid PTT serialization

**YC-F11: Message Routing** [Done]
- BROADCAST: visible to siblings + parent only
- COMPACTION: visible to parent only
- Grandparent/cousin filtering
- Envelope construction with GPS embedding

**YC-F12: Compaction Engine** [Done]
- Time window, count threshold, priority keyword triggers
- Whole-word case-insensitive keyword match (no substring false positives)
- Tactical summarizer prompt (preserve critical info, under 30 words, remove filler)
- Root SITREP from L1 compactions

**YC-F13: Main Screen Live Feed** [Done]
- Live feed with sender role, timestamp, type badge
- PTT button state machine (idle->recording->sending->idle)
- Disconnected state blocks PTT with error
- 76 tests passing (cumulative)

### Milestone 4: Full UX

**YC-F14: Tab Navigation & Tree View** [Done]
- 4-tab shell (Main, Tree View, Data Flow, Settings)
- TreeView with live status indicators (green/amber/red)
- Compaction summaries inline at parent nodes
- claimed_by info on each node

**YC-F15: Data Flow Screen** [Done]
- INCOMING: all received messages with timestamp/sender/type
- PROCESSING: Gemma 4 status, trigger reason, latency, tokens, compression ratio
- OUTGOING: emitted compactions with destination, source IDs, text

**YC-F16: Settings & Organiser Controls** [Done]
- Release Role button -> role selection
- Organiser-only Edit Tree and Promote controls
- Tree editor sheet for add/remove/rename from Settings

**YC-F17: SwiftData Persistence** [Done]
- All BROADCAST/COMPACTION messages persisted with metadata
- Full-text search (case-insensitive) for after-action review
- Messages survive app restart
- 91 tests passing (cumulative)

**YC-F18: Drag-and-Drop Tree Editor** [Done]
- Reparent nodes by dragging onto new parent
- Reorder siblings by dragging within same parent
- TREE_UPDATE broadcast on each operation
- Order persists across restart
- 95 tests passing (cumulative)

### Milestone 5: Resilience

**YC-F19: E2E Encryption** [Done]
- AES-256 (AES.GCM) with PIN-derived session key
- Key exchange on network join
- All messages encrypted in transit and at rest (SwiftData)
- Key material never logged
- 98 tests passing (cumulative)

**YC-F20: Auto-Reparenting** [Done]
- Detect parent disconnect (60s timeout)
- Children traverse to nearest connected ancestor
- TREE_UPDATE with new parent_id broadcast
- Cascading multi-level disconnect handled

**YC-F21: Priority Escalation + Model Download UI** [Done]
- Priority keywords bypass normal compaction thresholds
- False-positive guards (contacted, emergency exit, etc.)
- Download progress UI with model name, percentage, bytes, progress bar
- Storage check, resume support, gate enforcement

**YC-F22: Cross-Area Integration** [Done]
- Scene-phase handling (background flush, foreground restart)
- 14 cross-area integration tests covering all end-to-end flows
- 119 tests passing (final)

---

## MANUAL TESTING SPRINT (create as To Do)

> See MANUAL_TESTING.md for detailed step-by-step instructions.
> Requires 4 iPhones with iOS 16+. Build/install via Xcode.

**YC-T01: First Launch & Model Download** [To Do]
- Fresh install on Phone 0
- Observe download progress UI, verify gate blocks features
- Verify download completes and app unlocks
- Assertions: VAL-RES-005, VAL-RES-006, VAL-CROSS-001 (partial)
- Time estimate: 15-30 min (depends on download speed)

**YC-T02: BLE Discovery & Mesh** [To Do]
- 2-3 phones: verify peer discovery, bidirectional connections
- GATT characteristic verification
- Connection state tracking
- Assertions: VAL-BLE-001, VAL-BLE-002, VAL-BLE-007, VAL-BLE-008
- Time estimate: 10 min

**YC-T03: Network Creation & Role Claiming** [To Do]
- All 4 phones: create network, join, claim roles
- PIN entry (correct/wrong), conflict resolution
- Live tree modification, promote
- Assertions: VAL-TREE-006 through VAL-TREE-019, VAL-TREE-024, VAL-TREE-025
- Time estimate: 20 min

**YC-T04: Communication Flow** [To Do]
- All 4 phones: PTT, transcription, broadcast routing, compaction
- Verify live feed content and routing rules
- Assertions: VAL-COMM-001, VAL-COMM-015, VAL-COMM-017
- Time estimate: 15 min

**YC-T05: Full Demo Scenario (Section 14)** [To Do]
- All 4 phones: exact demo reproduction
- Alpha-1 speaks -> Alpha Lead compacts -> Commander SITREP
- Assertions: VAL-CROSS-002, VAL-CROSS-007
- Time estimate: 10 min

**YC-T06: Tree Modifications & Drag-and-Drop** [To Do]
- Organiser adds/removes/renames nodes live
- Drag-and-drop reparent with peers observing
- Assertions: VAL-UX-013, VAL-UX-017, VAL-CROSS-003
- Time estimate: 10 min

**YC-T07: Resilience -- Reparenting & Priority** [To Do]
- Power off Phone 1, observe auto-reparent
- Say "casualty" for priority escalation
- Organiser promote
- Assertions: VAL-RES-003, VAL-RES-004, VAL-RES-010, VAL-CROSS-004, VAL-CROSS-005, VAL-CROSS-009
- Time estimate: 15 min

**YC-T08: Encryption** [To Do]
- Create network with PIN, join, exchange messages
- Wrong PIN attempt
- Assertions: VAL-RES-001, VAL-RES-002, VAL-CROSS-008
- Time estimate: 10 min

**YC-T09: Message Flooding & TTL** [To Do]
- Multi-hop relay across 3-4 phones
- TTL edge cases (phones physically separated)
- Assertions: VAL-BLE-003 through VAL-BLE-006, VAL-BLE-009
- Time estimate: 15 min

**YC-T10: UX Polish Verification** [To Do]
- Tab navigation, tree view indicators, Data Flow screen
- After-action review search, Settings release role
- Assertions: VAL-UX-004, VAL-UX-005, VAL-CROSS-006, VAL-CROSS-010
- Time estimate: 15 min

**YC-T11: Edge Cases** [To Do]
- App backgrounding during compaction
- Download interruption (airplane mode toggle)
- GPS coordinates in messages
- Assertions: VAL-CROSS-012, VAL-CROSS-013, VAL-CROSS-014
- Time estimate: 15 min

---

## KNOWN ITEMS (create as Backlog)

**YC-B01: Swift Sendable Warnings** [Backlog]
- BluetoothMeshService.swift has Sendable-conversion warnings for cactusComplete and Date.init closures
- Non-blocking, cosmetic. Fix by wrapping in @Sendable closures.
- Priority: Low

**YC-B02: iPhone 16 Simulator Flakiness** [Backlog]
- Intermittent FBSOpenApplicationServiceErrorDomain on iPhone 16 simulator
- Workaround: use iPhone 17 simulator destination
- Not a code issue, Xcode/simulator bug
- Priority: None (workaround in place)

---

## QUICK REFERENCE FOR TEAMMATES

**To build and run**:
1. Open `TacNet.xcodeproj` in Xcode
2. Select your iPhone as destination (not simulator for BLE testing)
3. Build & Run (Cmd+R)
4. First launch downloads 6.7GB model -- needs WiFi

**To run unit tests**:
```
xcodebuild test -project TacNet.xcodeproj -scheme TacNet -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

**Phone assignments for demo**:
- Phone 0: Commander (root node)
- Phone 1: Alpha Lead (intermediate)
- Phone 2: Bravo Lead (intermediate)
- Phone 3: Alpha-1 (leaf node under Alpha Lead)

**Total manual testing time**: ~2.5 hours with 4 phones
