# TacNet Manual Testing Guide

> **Purpose:** Step-by-step physical device testing for all assertions that cannot be verified by unit tests alone.
> **Estimated time:** 90–120 minutes (linear, single session).
> **Date:** 2026-04-15

---

## Prerequisites

### Devices Required

| Label | Phone | Role | Notes |
|-------|-------|------|-------|
| **Phone 0** | iPhone (iOS 16+) | Commander (Root) | Organiser device — creates the network |
| **Phone 1** | iPhone (iOS 16+) | Alpha Lead (L1) | Intermediate node — compacts child messages |
| **Phone 2** | iPhone (iOS 16+) | Bravo Lead (L1) | Leaf node under root |
| **Phone 3** | iPhone (iOS 16+) | Alpha-1 (L2) | Leaf node under Alpha Lead |

All 4 phones must be iPhone 15 or 16 series (8 GB RAM minimum for Gemma 4 E4B inference at INT4).

**Physically label each phone** with tape or a sticky note: `Phone 0`, `Phone 1`, `Phone 2`, `Phone 3`.

### Build & Install

1. Open `/Users/yifuzuo/Desktop/yifu/startup/projects/hackathon/YC-hack/TacNet.xcodeproj` in Xcode.
2. Select your Apple Developer team under **Signing & Capabilities** for the `TacNet` target.
3. For each phone:
   - Connect via USB.
   - Select the device in Xcode's destination picker.
   - `Cmd+R` to build and run.
   - Trust the developer certificate on the phone: **Settings → General → VPN & Device Management**.
4. Repeat for all 4 phones. Keep Xcode console open on a Mac to view logs (connect via USB or wireless debugging).

### Model Weights (First Launch)

- The app downloads **6.7 GB** of Gemma 4 E4B INT4 weights on first launch.
- **Ensure all phones are on WiFi** before first launch.
- Download takes 5–15 minutes depending on connection speed.
- You can install and launch on all 4 phones simultaneously to download in parallel.
- After download completes once, the weights persist across app relaunches.

### Console Log Access

- Connect each phone to a Mac via USB.
- Open **Console.app** (macOS) or Xcode's debug console.
- Filter by process name `TacNet` to see relevant logs.
- Alternatively, use `Xcode → Debug → Attach to Process` for phones not actively running from Xcode.

### Tree Topology for Testing

All tests use this hierarchy (created in Phase 3):

```
Phone 0: Commander (Root)
├── Phone 1: Alpha Lead (L1)
│   └── Phone 3: Alpha-1 (L2)
└── Phone 2: Bravo Lead (L1)
```

---

## Phase 1: First Launch & Model Download

**Phones used:** Phone 0 only (fresh install)
**Goal:** Verify model download progress UI, feature gating, and Cactus SDK initialization.

> If you already downloaded the model during setup, delete and reinstall the app on Phone 0 to test fresh.

### Step 1.1: Fresh Install — Download Progress UI

1. **Action (Phone 0):** Launch the app for the first time on WiFi.
2. **Observe (Phone 0):** A download progress screen appears showing:
   - A percentage indicator (0% → 100%)
   - Progress updates monotonically (never jumps backward)
3. **Observe (Phone 0):** At least 5 intermediate progress updates appear between 0% and 100%.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-005**

### Step 1.2: Feature Gate During Download

1. **Action (Phone 0):** While download is in progress (between 10%–90%), attempt to navigate to any tactical feature (Create Network, Join Network, Push-to-Talk).
2. **Observe (Phone 0):** All tactical features are blocked/grayed out. The app does not allow creating or joining a network until download completes.
3. **Observe (Phone 0):** Within 3 seconds of download completion, features become available.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-006**

### Step 1.3: Cactus SDK Initialization After Download

1. **Action (Phone 0):** Wait for download to complete. The app should automatically initialize the Cactus SDK.
2. **Observe (Console log, Phone 0):** Look for log messages indicating:
   - `cactusInit` succeeded (non-nil handle returned)
   - A trivial `cactusComplete` call returned a non-empty string
   - `cactusDestroy` completed without crash (or the context is held for reuse)
3. **Observe (Phone 0):** The app transitions to the main screen (Create/Join Network) without errors.

- [ ] **Pass / Fail** — Verifies: **VAL-FOUND-008**, **VAL-CROSS-001** (first part: model download → cactusInit)

---

## Phase 2: BLE Discovery & Mesh Formation

**Phones used:** Phone 0, Phone 1 (add Phone 2 in Step 2.3)
**Goal:** Verify BLE peer discovery, bidirectional connections, and GATT characteristics.

### Step 2.1: Peer Discovery via TacNet Service UUID

1. **Action (Phone 0):** Tap **Create Network**. The app begins BLE advertising.
2. **Action (Phone 1):** Open the app (model already downloaded). Tap **Join Network**. The app begins scanning.
3. **Observe (Phone 1):** Within 10 seconds, Phone 0's network appears in the nearby networks list.
4. **Observe (Console log, both phones):** `didDiscover` callbacks logged with TacNet service UUID.

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-001**

### Step 2.2: Bidirectional Central + Peripheral Operation

1. **Observe (Console log, Phone 0):** Both `CBCentralManager` and `CBPeripheralManager` are active simultaneously.
2. **Observe (Console log, Phone 1):** Both `CBCentralManager` and `CBPeripheralManager` are active simultaneously.
3. **Observe (Console log, both phones):** `didConnect` callbacks appear on both phones (each connects to the other).
4. **Action:** From the console, confirm write operations succeed in both directions (Phone 0 → Phone 1 and Phone 1 → Phone 0).

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-002**

### Step 2.3: GATT Characteristic Verification

1. **Action:** Using a BLE scanner app (e.g., **nRF Connect** on a separate device, or check console logs), inspect Phone 0's advertised service.
2. **Observe:** The TacNet service UUID is discoverable.
3. **Observe:** The following characteristics are present with correct properties:
   - **Broadcast characteristic:** Read, Write, Notify
   - **Compaction characteristic:** Read, Write, Notify
   - **Tree config characteristic:** Read

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-007**

### Step 2.4: Connection State Tracking

1. **Action (Phone 1):** Toggle Airplane Mode ON on Phone 1.
2. **Observe (Console log, Phone 0):** State for Phone 1 changes to `disconnected` with timestamp.
3. **Action (Phone 1):** Toggle Airplane Mode OFF.
4. **Observe (Console log, Phone 0):** State for Phone 1 changes to `connected` with timestamp.
5. **Observe:** State transitions are logged accurately with timestamps for connect, disconnect, and reconnect events.

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-008**

---

## Phase 3: Network Creation & Role Claiming

**Phones used:** All 4 phones
**Goal:** Create the network on Phone 0, join on others, claim roles, test PIN and conflict handling.

### Step 3.1: Create & Publish Network (Phone 0)

1. **Action (Phone 0):** In the tree builder, create this hierarchy:
   - Root node: rename to **"Commander"**
   - Add child: rename to **"Alpha Lead"**
   - Under Alpha Lead, add child: rename to **"Alpha-1"**
   - Add another child under root: rename to **"Bravo Lead"**
2. **Action (Phone 0):** Set network name to **"Test Network"**.
3. **Action (Phone 0):** Set a 4-digit PIN: **1234**.
4. **Action (Phone 0):** Tap **Publish Network**.
5. **Observe (Console log, Phone 0):** `CBPeripheralManager` starts advertising with TacNet service UUID and network name.
6. **Observe:** Using a BLE scanner or Phone 1's join screen, confirm the network is visible.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-006**

### Step 3.2: Discover Nearby Networks (Phones 1, 2, 3)

1. **Action (Phone 1):** Tap **Join Network**.
2. **Observe (Phone 1):** Within 10 seconds, **"Test Network"** appears with name and open slot count (3 open slots).
3. **Repeat** for Phone 2 and Phone 3.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-007**

### Step 3.3: PIN Authentication — Wrong PIN

1. **Action (Phone 1):** Tap **"Test Network"** to join.
2. **Observe (Phone 1):** A PIN entry screen appears.
3. **Action (Phone 1):** Enter wrong PIN: **0000**.
4. **Observe (Phone 1):** Error message displayed. No tree data is shown. Phone 1 remains on the join screen.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-008** (wrong PIN path)

### Step 3.4: PIN Authentication — Correct PIN

1. **Action (Phone 1):** Enter correct PIN: **1234**.
2. **Observe (Phone 1):** PIN accepted. Tree view appears showing all 4 nodes with their labels. All nodes except Commander show as **Available/Open**.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-008** (correct PIN path)

### Step 3.5: Tree Sync on Join

1. **Observe (Phone 1):** The tree displayed on Phone 1 exactly matches Phone 0's tree:
   - Commander (claimed by Phone 0)
   - Alpha Lead (open)
   - Alpha-1 (open)
   - Bravo Lead (open)
2. **Verify:** Node names, hierarchy, and claim status all match.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-009**

### Step 3.6: PIN-Less Network (Quick Detour)

1. **Action (Phone 0):** Unpublish the current network. Create a new network with **no PIN**. Publish it.
2. **Action (Phone 2):** Tap **Join Network**, then tap the new network.
3. **Observe (Phone 2):** No PIN prompt appears. Phone 2 goes directly to the tree/role selection view.
4. **Action:** Unpublish this test network. Re-publish the original **"Test Network"** with PIN **1234**.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-024**

### Step 3.7: Join Remaining Phones & Claim Roles

1. **Action (Phone 1):** Tap **"Alpha Lead"** node → **Claim this role**.
2. **Action (Phone 2):** Join with PIN **1234**. Tap **"Bravo Lead"** → **Claim this role**.
3. **Action (Phone 3):** Join with PIN **1234**. Tap **"Alpha-1"** → **Claim this role**.

### Step 3.8: Claim Propagation Across All Peers

1. **Observe (All 4 phones):** Within 5 seconds of each claim:
   - **Phone 0:** Shows Commander (self), Alpha Lead (Phone 1), Bravo Lead (Phone 2), Alpha-1 (Phone 3) — all claimed.
   - **Phone 1, 2, 3:** Each shows the same claim status on all nodes.
2. **Verify:** The CLAIM message propagated to every peer and all tree views are consistent.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-010**

### Step 3.9: Claim Conflict — Simultaneous Claim

1. **Action (Phone 0):** Unpublish and recreate the network. Add a new open node **"Scout"** under Commander. Publish.
2. **Action:** Have Phone 1 and Phone 2 rejoin the network.
3. **Action (Phone 1 and Phone 2 simultaneously):** Both tap **"Scout"** → **Claim this role** at the exact same moment.
4. **Observe:** The organiser (Phone 0) wins the conflict. The loser receives a `CLAIM_REJECTED` message and returns to role selection. All peers show a consistent state.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-011**, **VAL-CROSS-011**

> **After this step:** Restore the standard 4-node topology. Make sure all phones are joined and roles claimed as:
> Phone 0 = Commander, Phone 1 = Alpha Lead, Phone 2 = Bravo Lead, Phone 3 = Alpha-1.

### Step 3.10: TREE_UPDATE Does Not Reset Existing Claims

1. **Action (Phone 0):** In the tree editor, add a new node **"Alpha-2"** under Alpha Lead.
2. **Observe (All 4 phones):** The new node appears on all devices within 5 seconds.
3. **Observe (All 4 phones):** Existing claims on Commander, Alpha Lead, Bravo Lead, and Alpha-1 are **unchanged**. No one gets kicked out.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-025**

> **Cleanup:** Remove the "Alpha-2" node before proceeding.

---

## Phase 4: Communication Flow

**Phones used:** All 4 phones
**Goal:** Test PTT, transcription, broadcast routing, compaction, SITREP, and live feed.

### Step 4.1: PTT Audio Capture (Phone 3)

1. **Action (Phone 3):** Navigate to the Main tab. Press and hold the **Push-to-Talk** button.
2. **Observe (Phone 3):** The PTT button visually changes to a "recording" state.
3. **Action (Phone 3):** Say clearly: **"Enemy spotted near building 4"**. Release the PTT button.
4. **Observe (Phone 3):** The button transitions through: recording → sending → idle.
5. **Observe (Console log, Phone 3):** Audio buffer metadata logged: 16 kHz, mono, 16-bit PCM.

- [ ] **Pass / Fail** — Verifies: **VAL-COMM-001**, **VAL-UX-004**

### Step 4.2: Broadcast Received at Sibling & Parent

1. **Observe (Phone 1 — Alpha Lead, parent of Phone 3):** The transcript **"Enemy spotted near building 4"** (or close approximation) appears in the live feed with:
   - Sender role: Alpha-1
   - Timestamp
   - Type badge: BROADCAST
2. **Observe (Phone 0 — Commander, grandparent):** The raw transcript does **NOT** appear in the live feed (grandparent is excluded from broadcast routing).
3. **Observe (Phone 2 — Bravo Lead, uncle node):** The raw transcript does **NOT** appear in the live feed (different subtree).

- [ ] **Pass / Fail** — Verifies: **VAL-COMM-015** (live feed display with metadata)

### Step 4.3: Compaction at Alpha Lead (Phone 1)

1. **Action (Phone 3):** Send 2 more PTT messages:
   - PTT: **"They have rifles, moving toward the west entrance"**
   - PTT: **"Requesting backup from Alpha Lead"**
2. **Observe (Phone 1):** After the compaction trigger fires (3 messages or time window), a compaction summary appears in the live feed with a distinct **COMPACTION** badge.
3. **Observe (Console log, Phone 1):** Compaction engine log shows:
   - Input: 3 transcripts from Alpha-1
   - Output: Summary ≤ 30 words preserving key details (building 4, rifles, west entrance, backup)

- [ ] **Pass / Fail** — Verifies: **VAL-COMM-015** (compaction in feed), **VAL-CROSS-002** (partial: leaf → parent compaction)

### Step 4.4: Compacted Summary Reaches Commander (Phone 0)

1. **Observe (Phone 0):** The compacted summary from Alpha Lead appears in the live feed with:
   - Sender role: Alpha Lead
   - Type badge: COMPACTION
   - Summary text (not raw transcripts)
2. **Observe (Phone 0):** The raw transcripts from Alpha-1 are **NOT** visible — only the compacted summary.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-002** (compaction routes to parent only, raw doesn't leak to grandparent)

### Step 4.5: Bravo Lead Contribution (Phone 2)

1. **Action (Phone 2):** PTT: **"Bravo in position east side, all clear"**.
2. **Observe (Phone 0):** Bravo Lead's transcript or compaction appears in the live feed (Bravo Lead is a direct child of Commander, so the broadcast is visible to Phone 0).

- [ ] **Pass / Fail** — Verifies: **VAL-COMM-015**

### Step 4.6: Root SITREP (Phone 0)

1. **Observe (Phone 0):** After receiving compactions from both Alpha Lead and Bravo Lead, Phone 0's compaction engine runs and produces a top-level **SITREP**.
2. **Observe (Phone 0):** The SITREP appears on screen summarizing both squads (e.g., "Alpha reports contact building 4. Bravo in position, clear.").

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-002** (full cycle: leaf → compaction → root SITREP)

### Step 4.7: Very Long Audio Recording

1. **Action (Phone 3):** Press and hold PTT for **90 seconds** while speaking continuously.
2. **Observe (Phone 3):** No crash, no out-of-memory error. The recording is either capped at a maximum duration or fully processed.
3. **Observe:** A transcript is produced (may be truncated). The app remains responsive.

- [ ] **Pass / Fail** — Verifies: **VAL-COMM-017**

---

## Phase 5: Full Demo Scenario (Section 14)

**Phones used:** All 4 phones
**Goal:** Reproduce the exact hackathon demo scenario end-to-end within 2 minutes.

> **Reset:** Clear any pending compactions. Ensure all phones are on their claimed roles and live feeds are clear.

### Step 5.1: Alpha-1 Reports Contact

1. **Action (Phone 3 — Alpha-1):** PTT: **"Enemy spotted near building 4"**.
2. **Observe (Phone 1 — Alpha Lead):** Transcript appears in live feed immediately.

### Step 5.2: Alpha Lead Auto-Compacts

1. **Observe (Phone 1):** After compaction trigger, a summary appears (e.g., "Alpha: Enemy contact near building 4").
2. **Observe (Phone 0 — Commander):** The compacted summary from Alpha Lead appears on screen.

### Step 5.3: Bravo Reports

1. **Action (Phone 2 — Bravo Lead):** PTT: **"Bravo in position, all clear"**.
2. **Observe (Phone 0):** Bravo Lead's message appears in the live feed.

### Step 5.4: Commander SITREP

1. **Observe (Phone 0):** Commander's compaction engine produces a SITREP combining both squads.
2. **Observe (Phone 0):** SITREP text on screen (e.g., "SITREP: Alpha reports contact bldg 4. Bravo in position, clear.").

### Step 5.5: Timing Verification

1. **Verify:** The entire demo flow (Step 5.1 through 5.4) completed in **under 2 minutes**.
2. **Verify:** No internet connection was used. Toggle WiFi off on all phones before starting if desired.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-002**, **VAL-CROSS-007**

---

## Phase 6: Tree Modifications & Reparenting

**Phones used:** All 4 phones
**Goal:** Test live tree editing (add, remove, rename) and drag-and-drop reparenting by the organiser.

### Step 6.1: Organiser Adds Node Post-Publish

1. **Action (Phone 0):** Navigate to Settings or Tree Editor. Add a new child node under Alpha Lead named **"Alpha-2"**.
2. **Observe (All 4 phones):** Within 3 seconds, the new **"Alpha-2"** node appears in the tree view on all devices.
3. **Observe:** The new node shows as **Available/Open**.

- [ ] **Pass / Fail** — Verifies: **VAL-UX-017** (add propagation)

### Step 6.2: Organiser Renames Node

1. **Action (Phone 0):** Rename **"Alpha-2"** to **"Alpha Medic"**.
2. **Observe (All 4 phones):** Within 3 seconds, the label updates to **"Alpha Medic"** on all devices.
3. **Observe:** If the node were claimed, the claim would be preserved (in this case it's unclaimed).

- [ ] **Pass / Fail** — Verifies: **VAL-UX-017** (rename propagation)

### Step 6.3: Organiser Removes Node

1. **Action (Phone 0):** Remove the **"Alpha Medic"** node.
2. **Observe (All 4 phones):** Within 3 seconds, the node disappears from all devices.

- [ ] **Pass / Fail** — Verifies: **VAL-UX-017** (remove propagation)

### Step 6.4: Drag-and-Drop Reparenting

1. **Action (Phone 0):** Long-press on **"Alpha-1"** (currently under Alpha Lead) and drag it onto **"Commander"** (root) to reparent it.
2. **Observe (Phone 0):** Alpha-1 now appears as a direct child of Commander in the tree.
3. **Observe (All other phones):** The tree updates within 3 seconds to show the new hierarchy.
4. **Observe:** Phone 3's claim on Alpha-1 is **preserved** — it is still claimed by Phone 3.
5. **Observe (Console log):** A `TREE_UPDATE` message was broadcast to all peers.

- [ ] **Pass / Fail** — Verifies: **VAL-UX-013**, **VAL-CROSS-003** (partial: tree restructure)

### Step 6.5: Routing Updates After Reparent

1. **Action (Phone 3 — Alpha-1, now under Commander):** PTT: **"Testing new routing after reparent"**.
2. **Observe (Phone 0 — Commander, now Alpha-1's parent):** The transcript appears in Phone 0's live feed (new parent receives it).
3. **Observe (Phone 1 — Alpha Lead, old parent):** The transcript does **NOT** appear in Phone 1's live feed (no longer parent).

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-003** (routing rules update after reparent)

> **Cleanup:** Reparent Alpha-1 back under Alpha Lead to restore the standard topology.

---

## Phase 7: Resilience Testing

**Phones used:** All 4 phones
**Goal:** Test auto-reparenting on disconnect, priority escalation, and organiser promotion.

### Step 7.1: Auto-Reparenting — Parent Disconnect

1. **Verify setup:** Standard topology: Commander → Alpha Lead → Alpha-1, Commander → Bravo Lead.
2. **Action (Phone 1 — Alpha Lead):** Power off Phone 1 completely (hold side button → slide to power off).
3. **Start a timer.**
4. **Observe (Phone 3 — Alpha-1):** Within 55–65 seconds, Alpha-1 is automatically reparented to **Commander** (the nearest connected ancestor).
5. **Observe (Phone 0 — Commander):** The tree view updates to show Alpha-1 as a direct child. A `TREE_UPDATE` is broadcast.
6. **Record the time:** Should be 60s ± 5s from power-off.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-003**

### Step 7.2: Routing After Reparent

1. **Action (Phone 3 — Alpha-1, now under Commander):** PTT: **"Test message after auto-reparent"**.
2. **Observe (Phone 0 — Commander):** The transcript or compaction from Alpha-1 appears in Phone 0's live feed.
3. **Observe:** Data Flow screen on Phone 0 shows the message in INCOMING with Alpha-1 as sender.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-004**

### Step 7.3: Power Phone 1 Back On

1. **Action:** Power Phone 1 back on and relaunch TacNet.
2. **Action (Phone 1):** Rejoin the network and reclaim Alpha Lead.
3. **Action (Phone 0):** Reparent Alpha-1 back under Alpha Lead to restore standard topology.

### Step 7.4: Cascading Multi-Level Reparent

> This test requires a deeper tree. Temporarily modify the topology.

1. **Action (Phone 0):** Add a new node **"Alpha-1-Sub"** under Alpha-1. Have no phone claim it (or use a 5th phone if available). The point is to verify cascading logic.
2. **Actual test with 4 phones (simplified):** With the standard topology, first disconnect Phone 1 (Alpha Lead). Phone 3 (Alpha-1) reparents to Commander (tested in 7.1). Now also observe that if Phone 3 were disconnected too, its hypothetical children would reparent further up.
3. **Alternative verification (Console log, Phone 0):** Check that the auto-reparent logic traverses upward through the tree correctly. Log output should show the algorithm finding the nearest connected ancestor.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-010**

### Step 7.5: Priority Escalation — "Casualty" Keyword

1. **Verify setup:** Standard topology restored, all phones connected.
2. **Action (Phone 3 — Alpha-1):** PTT: **"We have a casualty, need medevac immediately"**.
3. **Observe (Phone 1 — Alpha Lead):** Compaction triggers **immediately** (within 5 seconds) — no waiting for the normal message count or time window.
4. **Observe (Console log, Phone 1):** Compaction trigger reason logged as **"priority keyword: casualty"**.
5. **Observe (Phone 0 — Commander):** The compacted summary reaches Commander faster than normal compaction cycle time.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-009**

### Step 7.6: Organiser Promote

1. **Action (Phone 0):** Navigate to Settings or the tree editor. Select Phone 1 (Alpha Lead) and tap **Promote to Organiser**.
2. **Observe (Phone 0):** Phone 0 loses organiser controls (Edit Tree button disappears or becomes disabled).
3. **Observe (Phone 1):** Phone 1 gains organiser controls (Edit Tree button appears and is enabled).
4. **Observe (All phones):** No dual-organiser state. The transition is atomic.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-005** (partial: promote)

### Step 7.7: New Organiser Edits Tree

1. **Action (Phone 1 — new organiser):** Add a node **"Alpha-2"** under Alpha Lead.
2. **Observe (All 4 phones):** The new node appears within 3 seconds on all devices.
3. **Action (Phone 1):** Remove the **"Alpha-2"** node.
4. **Observe:** Communication continues uninterrupted throughout organiser handover and edits.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-005** (full: promote → edit → propagate → comms uninterrupted)

> **Cleanup:** Promote Phone 0 back to organiser (Phone 1 promotes Phone 0), or recreate the network from Phone 0.

---

## Phase 8: Encryption

**Phones used:** Phone 0, Phone 1, Phone 2 (Phone 3 optional as late joiner)
**Goal:** Verify encrypted communication with PIN-based key exchange.

### Step 8.1: Create Encrypted Network

1. **Action (Phone 0):** Create a new network with PIN **5678**. Build the standard tree. Publish.

### Step 8.2: Join with Correct PIN & Exchange Messages

1. **Action (Phone 1):** Join with PIN **5678**. Claim Alpha Lead.
2. **Action (Phone 2):** Join with PIN **5678**. Claim Bravo Lead.
3. **Action (Phone 2):** PTT: **"Bravo reporting, perimeter secure"**.
4. **Observe (Phone 0):** The message is received and displayed correctly (decrypted).
5. **Observe (Phone 1):** The message is received (if routing applies).

- [ ] **Pass / Fail** — Verifies: **VAL-RES-002** (correct PIN decrypts)

### Step 8.3: Attempt Wrong PIN

1. **Action (Phone 3):** Attempt to join the network with wrong PIN **0000**.
2. **Observe (Phone 3):** Authentication rejected. Phone 3 cannot see tree data or read any messages.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-002** (wrong PIN cannot read), **VAL-CROSS-008** (partial)

### Step 8.4: Verify Encryption in Transit

1. **Action:** On a Mac with a BLE sniffer, or check console logs for raw BLE packet data.
2. **Observe:** BLE payloads contain no plaintext message fragments. Messages are encrypted before transmission.
3. **Alternatively (Console log):** Confirm no plaintext transcript strings appear in BLE write/read logs — only encrypted bytes.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-001** (in transit)

### Step 8.5: Verify Encryption at Rest

1. **Action (Phone 1):** Use Xcode's Devices & Simulators window to download the app container from Phone 1.
2. **Action:** Inspect the SwiftData database file (`.store` or `.sqlite`).
3. **Observe:** No plaintext message fragments in the database. Messages are encrypted at rest.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-001** (at rest)

### Step 8.6: Late Joiner Gets Key

1. **Action (Phone 3):** Now join with the correct PIN **5678**. Claim Alpha-1.
2. **Action (Phone 2):** Send another PTT message: **"Second report from Bravo"**.
3. **Observe (Phone 3):** Phone 3 can read the new message (received key on join).

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-008** (full: PIN join → key exchange → late joiner)

### Step 8.7: Encryption Key Not Leaked in Logs

1. **Action:** On the Mac, grep the Xcode console output for all 4 phones.
2. **Search for:** PIN digits ("5678"), base64 strings of key length (32+ chars), or any key material.
3. **Observe:** No key material, PIN plaintext, or key-length base64 strings in console logs.

- [ ] **Pass / Fail** — Verifies: **VAL-RES-011**

---

## Phase 9: Message Flooding & TTL

**Phones used:** Phone 0, Phone 1, Phone 2, Phone 3
**Goal:** Test multi-hop message relay, TTL decrement, and UUID deduplication.

> **Physical setup:** Place phones in a line. Ideally:
> - Phone 0 and Phone 3 should be far apart (different rooms if possible)
> - Phone 1 between Phone 0 and Phone 3
> - Phone 2 near Phone 0
>
> This ensures messages from Phone 3 may need to hop through Phone 1 to reach Phone 0.

### Step 9.1: Message Flooding Across 3 Phones

1. **Action (Phone 3 — Alpha-1):** Send a PTT message: **"Flood test from Alpha-1"**.
2. **Observe (Console log, Phone 1):** Message received from Phone 3 with original `sender_id` (Alpha-1) and TTL decremented by 1 from original.
3. **Observe (Console log, Phone 1):** Phone 1 re-broadcasts the message.
4. **Observe (Console log, Phone 0):** Message received (either directly from Phone 3 or relayed via Phone 1) with `sender_id` still showing Alpha-1 and TTL further decremented.
5. **Verify:** `sender_id` is preserved through hops. TTL is decremented at each hop.

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-003**

### Step 9.2: TTL Decrement and Drop at Zero

1. **Action:** If possible via debug settings or code, send a message with `TTL=2` from Phone 3.
2. **Observe (Console log, Phone 1):** Receives with TTL=1, re-broadcasts.
3. **Observe (Console log, Phone 0):** Receives with TTL=0, does **NOT** re-broadcast.
4. **Observe (Console log, Phone 2):** If Phone 2 is out of direct range of Phone 3 and Phone 1, it should **NOT** receive the message (TTL exhausted before reaching it).

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-004**

### Step 9.3: TTL=1 Edge Case

1. **Action:** Send a message with `TTL=1` from Phone 3.
2. **Observe (Console log, Phone 1):** Receives and processes locally but does **NOT** re-broadcast.
3. **Observe (Console log, Phone 0):** Does not receive this message (if out of direct range of Phone 3).

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-005**

### Step 9.4: UUID Dedup Prevents Infinite Loops

1. **Action (Phone 3):** Send a message. Due to mesh topology, the message may reach some phones via multiple paths.
2. **Observe (Console log, all phones):** Each phone logs exactly **one** `processMessage` event for this message UUID. No phone processes the same UUID twice.
3. **Verify:** No infinite relay loops. Message is seen once per device.

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-006**

### Step 9.5: Store-and-Forward Across 4 Phones

1. **Physical setup:** Arrange phones in a chain: Phone 0 ↔ Phone 1 ↔ Phone 2 ↔ Phone 3 (each only in BLE range of its neighbors).
2. **Action (Phone 3):** Send a PTT message: **"Chain relay test"**.
3. **Observe (Console log, Phone 2):** Receives from Phone 3, relays.
4. **Observe (Console log, Phone 1):** Receives from Phone 2, relays.
5. **Observe (Console log, Phone 0):** Receives from Phone 1. `sender_id` is still Alpha-1 (Phone 3). TTL decremented 3 times from original.
6. **Verify:** Timestamps show the message hopping through each intermediate phone.

- [ ] **Pass / Fail** — Verifies: **VAL-BLE-009**

---

## Phase 10: UX Polish Verification

**Phones used:** Any phone (Phone 0 recommended, or use multiple for live data)
**Goal:** Verify tab navigation, tree status indicators, Data Flow screen, after-action review, and settings.

### Step 10.1: Tab Navigation

1. **Action (Phone 0):** Tap through all 4 tabs: **Main**, **Tree View**, **Data Flow**, **Settings**.
2. **Observe:** Each tab renders its root view correctly. No blank screens, no error states.
3. **Observe:** Navigation is responsive (under 300ms per tab switch — subjective check for snappiness).

- [ ] **Pass / Fail** — Verifies: **VAL-UX-004** (tab navigation component)

### Step 10.2: Tree View Status Indicators

1. **Verify setup:** All 4 phones connected and active.
2. **Action (Phone 0):** Navigate to Tree View tab.
3. **Observe (Phone 0):** All claimed nodes show **green** (active) indicators.
4. **Action:** Set Phone 3 down and don't interact with it for 30+ seconds.
5. **Observe (Phone 0):** Phone 3's node (Alpha-1) transitions to **amber** (idle >30s).
6. **Action:** Toggle Airplane Mode ON on Phone 3 and wait 60+ seconds.
7. **Observe (Phone 0):** Phone 3's node transitions to **red** (disconnected >60s).
8. **Action:** Toggle Airplane Mode OFF on Phone 3.
9. **Observe (Phone 0):** Phone 3's node transitions back to **green** (after reconnection).

- [ ] **Pass / Fail** — Verifies: **VAL-UX-005**

### Step 10.3: Data Flow Screen During Active Comms

1. **Action (Phone 1 — Alpha Lead):** Navigate to the **Data Flow** tab.
2. **Action (Phone 3 — Alpha-1):** Send 3 PTT messages in sequence.
3. **Observe (Phone 1 — Data Flow):**
   - **INCOMING section:** Shows all 3 messages with timestamps, sender (Alpha-1), and type (BROADCAST).
   - **PROCESSING section:** Shows compaction status ("Compacting (3 msgs)"), trigger reason, latency, token counts, and compression ratio.
   - **OUTGOING section:** Shows the emitted compaction with destination (Commander), source IDs, and output text.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-010**

### Step 10.4: After-Action Review Search

1. **Action (Phone 0):** Navigate to after-action review / message history.
2. **Action (Phone 0):** Search for **"building"** (from earlier messages).
3. **Observe:** Matching messages appear (both BROADCAST and COMPACTION types) with metadata.
4. **Action (Phone 0):** Search for **"xyznonexistent"**.
5. **Observe:** 0 results returned.
6. **Action (Phone 0):** Search for **"BUILDING"** (uppercase).
7. **Observe:** Same results as lowercase search (case-insensitive).

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-006**

### Step 10.5: Settings — Release Role

1. **Action (Phone 2 — Bravo Lead):** Navigate to **Settings** tab. Tap **Release Role**.
2. **Observe (Phone 2):** Navigates back to role selection screen.
3. **Observe (All other phones):** Bravo Lead node reverts to **Available/Open** within 5 seconds.
4. **Observe (Phone 2):** Historical message data is still intact (after-action review still has Bravo Lead's messages).
5. **Action (Phone 2):** Reclaim Bravo Lead.

- [ ] **Pass / Fail** — Verifies: **VAL-UX-015**, **VAL-TREE-013**

---

## Phase 11: Edge Cases

**Phones used:** Phone 0, Phone 3 (others as needed)
**Goal:** Test app backgrounding, download interruption, and GPS coordinate embedding.

### Step 11.1: App Backgrounding During Compaction

1. **Action (Phone 3 — Alpha-1):** Send 2 PTT messages to Alpha Lead.
2. **Action (Phone 1 — Alpha Lead):** Immediately after the 3rd PTT message from Phone 3, press the **Home button** (or swipe up) to background the TacNet app on Phone 1.
3. **Wait 5 seconds.**
4. **Action (Phone 1):** Reopen TacNet.
5. **Observe (Phone 1):** The app returns to the correct state. No data loss. The compaction either completed in the background or resumes correctly.
6. **Observe (Phone 1):** BLE reconnects to peers (check console log for reconnection events).

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-013**

### Step 11.2: Model Download Interruption and Recovery

> Requires a fresh install or cleared app data on one phone.

1. **Action (Phone 0):** Delete and reinstall TacNet. Launch on WiFi. Download begins.
2. **Action (Phone 0):** At approximately 30–50% progress, toggle **Airplane Mode ON** to interrupt the download.
3. **Observe (Phone 0):** An error UI appears indicating the download was interrupted.
4. **Action (Phone 0):** Toggle **Airplane Mode OFF**.
5. **Action (Phone 0):** Tap **Retry** (or the app auto-retries).
6. **Observe (Phone 0):** Download resumes from approximately the same point (not from 0%).
7. **Wait** for download to complete.
8. **Observe (Phone 0):** `cactusInit` succeeds after download completion. The app transitions to the main screen.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-012**, **VAL-RES-005** (resume component)

### Step 11.3: GPS Coordinates in Messages

1. **Action (Phone 3):** Ensure Location Services are enabled for TacNet (Settings → Privacy → Location Services → TacNet → While Using).
2. **Action (Phone 3):** Send a PTT message: **"GPS coordinate test"**.
3. **Observe (Console log, Phone 3):** The outgoing message envelope includes `location` field with `lat`, `lon`, and `accuracy` values matching the phone's actual GPS position.
4. **Observe (Console log, Phone 1 — receiver):** The received message contains the same GPS coordinates.
5. **Observe:** Query SwiftData on Phone 1 (via Xcode or console) to verify the GPS fields are persisted.

- [ ] **Pass / Fail** — Verifies: **VAL-CROSS-014**

### Step 11.4: Auto-Release After 60s BLE Disconnect

1. **Verify:** Phone 3 has Alpha-1 claimed.
2. **Action (Phone 3):** Toggle **Airplane Mode ON** (simulates BLE disconnect).
3. **Start a timer.**
4. **Observe (Phone 0):** After 55–65 seconds, Alpha-1 reverts to **Available/Open** (auto-released).
5. **Action (Phone 3):** Toggle **Airplane Mode OFF** within 30 seconds of step 2 (before the 60s timeout) in a **separate test**.
6. **Observe (Phone 0):** Alpha-1's claim is **preserved** (reconnected before timeout).

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-014**

### Step 11.5: Remove Claimed Node Kicks User

1. **Verify:** Phone 3 has Alpha-1 claimed. Phone 1 has Alpha Lead claimed.
2. **Action (Phone 0 — Organiser):** In the tree editor, remove the **"Alpha-1"** node.
3. **Observe (Phone 3):** Phone 3 gets kicked back to the role selection screen with a notification that their node was removed.
4. **Observe (All phones):** Alpha-1 node is gone from the tree view.

- [ ] **Pass / Fail** — Verifies: **VAL-TREE-016**

> **Cleanup:** Re-add Alpha-1 node and have Phone 3 reclaim it.

---

## Results Summary

Record the outcome of each assertion below. Mark **✅** for pass or **❌** for fail.

| Phase | Assertion ID | Description | Result |
|-------|-------------|-------------|--------|
| 1 | VAL-RES-005 | Model download progress UI | ⬜ |
| 1 | VAL-RES-006 | Model download gate blocks app | ⬜ |
| 1 | VAL-FOUND-008 | Cactus SDK initialization — success path | ⬜ |
| 1 | VAL-CROSS-001 | First-time user journey (download → init) | ⬜ |
| 2 | VAL-BLE-001 | Peer discovery via TacNet service UUID | ⬜ |
| 2 | VAL-BLE-002 | Bidirectional central + peripheral operation | ⬜ |
| 2 | VAL-BLE-007 | GATT characteristic setup | ⬜ |
| 2 | VAL-BLE-008 | Connection state tracking | ⬜ |
| 3 | VAL-TREE-006 | Network publish starts BLE advertising | ⬜ |
| 3 | VAL-TREE-007 | Participant discovers nearby networks | ⬜ |
| 3 | VAL-TREE-008 | PIN authentication gate (wrong + correct) | ⬜ |
| 3 | VAL-TREE-009 | Tree sync on join | ⬜ |
| 3 | VAL-TREE-010 | Claim open node updates all peers | ⬜ |
| 3 | VAL-TREE-011 | Claim conflict — organiser wins | ⬜ |
| 3 | VAL-TREE-024 | PIN-less network allows direct join | ⬜ |
| 3 | VAL-TREE-025 | TREE_UPDATE does not reset existing claims | ⬜ |
| 3 | VAL-CROSS-011 | Concurrent role claim conflict | ⬜ |
| 4 | VAL-COMM-001 | PTT audio capture start/stop | ⬜ |
| 4 | VAL-COMM-015 | Live feed display with metadata | ⬜ |
| 4 | VAL-COMM-017 | Very long audio recording (90s) | ⬜ |
| 4 | VAL-UX-004 | Push-to-talk button state machine | ⬜ |
| 4 | VAL-CROSS-002 | Full communication cycle (leaf → compaction → SITREP) | ⬜ |
| 5 | VAL-CROSS-007 | Demo scenario end-to-end (Section 14) | ⬜ |
| 6 | VAL-TREE-015 | Live tree modification — add node post-publish | ⬜ |
| 6 | VAL-TREE-017 | Rename node propagates to all peers | ⬜ |
| 6 | VAL-TREE-018 | Move node preserves claim | ⬜ |
| 6 | VAL-UX-013 | Drag-and-drop reparenting | ⬜ |
| 6 | VAL-UX-017 | Organiser live tree modification broadcast | ⬜ |
| 6 | VAL-CROSS-003 | Tree restructure mid-operation | ⬜ |
| 7 | VAL-TREE-019 | Organiser promote transfers role | ⬜ |
| 7 | VAL-UX-018 | Organiser promote transfers role (UX) | ⬜ |
| 7 | VAL-RES-003 | Auto-reparenting on parent disconnect | ⬜ |
| 7 | VAL-RES-004 | Routing rules update after reparent | ⬜ |
| 7 | VAL-RES-010 | Cascading multi-level reparent | ⬜ |
| 7 | VAL-CROSS-004 | Node failure recovery | ⬜ |
| 7 | VAL-CROSS-005 | Organiser handover | ⬜ |
| 7 | VAL-CROSS-009 | Priority escalation end-to-end | ⬜ |
| 8 | VAL-RES-001 | Message encryption at rest and in transit | ⬜ |
| 8 | VAL-RES-002 | Key exchange on network join | ⬜ |
| 8 | VAL-RES-011 | Encryption key not leaked in logs | ⬜ |
| 8 | VAL-CROSS-008 | Encrypted communication (full flow) | ⬜ |
| 9 | VAL-BLE-003 | Message flooding across mesh | ⬜ |
| 9 | VAL-BLE-004 | TTL decrement and drop at zero | ⬜ |
| 9 | VAL-BLE-005 | TTL edge case — message arrives with TTL=1 | ⬜ |
| 9 | VAL-BLE-006 | UUID dedup prevents infinite loops | ⬜ |
| 9 | VAL-BLE-009 | Store-and-forward across intermediate phones | ⬜ |
| 10 | VAL-UX-005 | Tree view real-time status indicators | ⬜ |
| 10 | VAL-CROSS-006 | After-action review search | ⬜ |
| 10 | VAL-CROSS-010 | Data flow transparency during active comms | ⬜ |
| 10 | VAL-UX-015 | Settings — release role returns to role selection | ⬜ |
| 10 | VAL-TREE-013 | Manual role release floods RELEASE | ⬜ |
| 11 | VAL-CROSS-012 | Model download interruption and recovery | ⬜ |
| 11 | VAL-CROSS-013 | Compaction persistence across app backgrounding | ⬜ |
| 11 | VAL-CROSS-014 | GPS coordinates through full message chain | ⬜ |
| 11 | VAL-TREE-014 | Auto-release after 60s BLE disconnect | ⬜ |
| 11 | VAL-TREE-016 | Remove claimed node kicks user | ⬜ |

**Total assertions:** 53 | **Passed:** ___ / 53 | **Failed:** ___ / 53

---

### Notes

_Use this space to record observations, issues, screenshots, or timestamps during testing._

| Assertion ID | Notes |
|-------------|-------|
| | |
| | |
| | |
