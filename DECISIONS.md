# TacNet — Design Decisions Log

All decisions captured from the spec review session.

---

## Decision 1: iOS Target

**Question:** What's the minimum iOS version you want to support?

**Choice:** `iOS 16+` (good balance)

**Rationale:** Provides access to modern Swift Concurrency, SwiftData, and stable BLE APIs without excluding too many devices.

---

## Decision 2: Cactus SDK Status

**Question:** Will the Cactus SDK be available as a real iOS library during the hackathon, or are you designing against a mock/spec?

**Choice:** `Real SDK available`

**Rationale:** Full integration expected — not a mock. All code references in the spec should reflect expected Cactus SDK APIs.

---

## Decision 3: BLE Audio Strategy

**Question:** How should audio data be transmitted over BLE given the ~20-byte characteristic limit?

**Choice:** `Audio stays local, only transcripts/summaries go over BLE`

**Rationale:** This is the key architectural win. By keeping audio playback local and only transmitting text (transcripts outbound, summaries inbound), the BLE mesh avoids all throughput constraints. No chunking, no sequencing, no Data Mode needed. Each phone plays received audio locally from the sender's transmission.

**Implication:** BROADCAST messages carry `transcript` (sender's STT output), not `audio_b64`. The receiving sibling/parent plays audio from the sender's local device (range permitting), while the transcript is what propagates up the compaction chain.

---

## Decision 4: STT Fallback

**Question:** If on-device STT via Cactus fails or is unavailable, which fallback do you prefer?

**Choice:** `Local-only processing. No internet, no fallbacks. All STT via on-device Cactus/SLM`

**Rationale:** Fully offline-first requirement. The system must work with zero connectivity. Gemma 4 via Cactus handles voice-to-text entirely on-device.

**Implication:** No Apple Speech framework fallback. STT quality depends entirely on Cactus/Gemma's voice capabilities.

---

## Decision 5: Compaction Latency

**Question:** What's your target latency from last child message to summary emission?

**Choice:** `1-2s (acceptable for tactical use)`

**Rationale:** Prioritizes accuracy and coherent summarization over raw speed. Real-time feel is not critical for the compaction layer — it's a summarization tool, not a live radio replacement.

---

## Decision 6: Tree Editor UI

**Question:** How detailed should the tree builder interface be?

**Choice:** `Full drag-and-drop reparenting and reordering`

**Rationale:** The organiser needs full visual control over the hierarchy during setup and mid-operation. Drag-and-drop is the most intuitive way to reparent nodes and restructure the tree.

**Implication:** `TreeBuilderView` uses SwiftUI drag gesture recognizers on `TreeNodeView` cells. Tree state is stored as a nested `TreeNode` model with `parent_id` references.

---

## Decision 7: Message Persistence

**Question:** Should messages be stored locally for after-action review?

**Choice:** `Yes — full history with search`

**Rationale:** Tactical operations require after-action review capability. All messages (BROADCASTs and COMPACTIONs) should be persisted locally with full-text search.

**Implication:** SwiftData used for message history. Search index on `transcript`, `summary`, and `sender_role`. Ring buffer optional for storage limits, but full history accessible.

---

## Decision 8: Role Transfer

**Question:** Can the organiser transfer ownership/control of the network to another participant mid-operation?

**Choice:** `Yes — organiser can promote any claimed node to organiser`

**Rationale:** Real-world scenarios require handover. If the commander goes down, someone else needs to take control and restructure the tree.

**Implication:** New message type `PROMOTE` — organiser broadcasts it with `target_node_id`. The target device receives organiser-level permissions. `NetworkConfig.created_by` updates. Old organiser becomes a regular participant.

---

## Decision 9: Conflict Resolution

**Question:** When two devices claim the same node simultaneously (race condition), how should it be resolved?

**Choice:** `Organiser device wins automatically`

**Rationale:** The organiser is the authority on tree state. If a conflict occurs, the organiser's claim takes precedence. This is simpler and more robust than timestamp-based resolution.

**Implication:** On simultaneous `CLAIM` received, organiser's claim is accepted. Loser receives a `CLAIM_REJECTED` message with reason: `organiser_wins`. Loser device returns to role selection.

---

## Decision 10: Dynamic Reparenting

**Question:** If a parent node goes offline, should its children automatically reparent to the nearest available ancestor?

**Choice:** `Yes — automatic reparenting`

**Rationale:** Network resilience is critical. If a squad leader goes down, their squad members shouldn't be stranded. Automatic reparenting keeps the tree functional even as nodes drop.

**Implication:** `TreeSyncService` monitors BLE connection state. On parent disconnect (60s timeout), children traverse upward to find nearest connected ancestor. `TREE_UPDATE` with new `parent_id` broadcast to all nodes. Routing rules update automatically.

---

## Decision 11: Encryption

**Question:** Do you want end-to-end encryption on BLE messages?

**Choice:** `Yes — pre-shared key on network join`

**Rationale:** Tactical communications are sensitive. All messages (BROADCAST, COMPACTION, CLAIM, TREE_UPDATE) should be encrypted end-to-end over the BLE mesh.

**Implication:** Key exchange happens after PIN verification during network join. Organiser generates a session key, encrypts it with the pre-shared network key (or PIN-derived key), and sends it to the joining participant. All subsequent messages use AES-256 or similar symmetric encryption.

---

## Decision 12: Location/GPS

**Question:** Should GPS coordinates be embedded in messages for a map view?

**Choice:** `Yes — embedded automatically`

**Rationale:** Situational awareness is enhanced by knowing where each node is. GPS data enables a shared map view showing all active nodes.

**Implication:** Every message envelope gets `location: { lat, lon, accuracy }` added automatically from Core Location. The root commander's screen can display a map with node positions. Map view is a potential 5th tab in the UI.

---

## Decision 13: Audio Transport Clarification

**Question:** The spec mentions audio plays on siblings/parent via "direct BLE audio profile" but Section 18 says "audio stays local on device; only transcripts cross the mesh." Which is the actual intent?

**Choice:** `Text-only over BLE, no audio streaming`

**Rationale:** Audio is NEVER transmitted over BLE. Only transcript text is sent over the mesh. Receiving devices display the text transcript. No BLE audio profile is used.

**Implication:** Removes all BLE audio streaming complexity. BROADCAST messages carry transcript text only. Siblings and parents see text in their live feed, not audio playback.

---

## Decision 14: STT Engine

**Question:** Should Apple's built-in Speech framework handle STT (with Gemma 4 for summarization only), or should Cactus/Gemma 4 handle both?

**Choice:** `Cactus/Gemma 4 E4B for both STT and summarization`

**Rationale:** Gemma 4 E4B has a native ~300M param audio conformer encoder — it handles audio input natively, not as a bolt-on. No separate STT model needed. Single model for both transcription and compaction.

**Implication:** Two-step pipeline using one model: (1) `cactusTranscribe` or `cactusComplete` with PCM audio to get transcript, (2) `cactusComplete` with collected transcripts to produce compacted summary. No Apple Speech framework, no Whisper.

---

## Decision 15: Model Tier Strategy

**Question:** Use different model sizes for different node roles (E2B for leaf, E4B for intermediate/root), or a single model for all?

**Choice:** `E4B on all devices for MVP simplicity`

**Rationale:** Hackathon MVP — one model simplifies deployment, testing, and debugging. E4B (4.5B params, ~2.8GB VRAM) fits on iPhone 15/16 with 8GB RAM. Can differentiate later if needed.

**Implication:** Single model download, single model init path, uniform performance expectations across all nodes.

---

## Decision 16: Audio Pipeline Architecture

**Question:** Should push-to-talk send raw audio directly to `cactusComplete` (one-pass audio-to-summary), or do a separate transcription step first?

**Choice:** `Two-step: transcribe audio first (show transcript in feed), then compact separately`

**Rationale:** The intermediate transcript is needed for the live feed display — siblings and parents see the text of what was said. Compaction is a separate step that aggregates multiple transcripts at the parent level.

**Implication:** Leaf nodes: record audio -> `cactusTranscribe` -> display + broadcast transcript. Parent nodes: collect child transcripts -> `cactusComplete` with summarization prompt -> broadcast compaction upward.

---

## Decision 17: Model Weight Delivery

**Question:** Bundle model weights (6.7GB) in the app binary, or download on first launch?

**Choice:** `Download on first launch`

**Rationale:** 6.7GB bundled in the IPA is impractical. First-launch download allows a smaller app binary. Requires WiFi and a download progress UI, but this is a one-time setup.

**Implication:** Need a model download manager with progress UI, storage check, and a "download complete" gate before the app becomes functional.

---

## Decision 18: Cactus SDK Integration Method

**Question:** How is the Cactus SDK integrated into the iOS project?

**Choice:** `Pre-built XCFramework from source`

**Rationale:** Cactus does not provide SPM or CocoaPods. The SDK is built from source via `apple/build.sh` (86 seconds), producing `cactus-ios.xcframework`. The Swift API is a single file (`Cactus.swift`) wrapping the C FFI.

**Details:**
- XCFramework: `cactus/apple/cactus-ios.xcframework/`
- Swift API: `cactus/apple/Cactus.swift` (free functions, not classes)
- Model weights: `/opt/homebrew/opt/cactus/libexec/weights/gemma-4-e4b-it/` (6.7GB INT4)
- Key functions: `cactusInit`, `cactusComplete`, `cactusTranscribe`, `cactusStreamTranscribeStart/Process/Stop`, `cactusDestroy`
- Audio format: 16-bit PCM, 16kHz mono

---

## Decision 19: Scope

**Question:** Build full spec or MVP first?

**Choice:** `Full spec — no cuts`

**Rationale:** 3+ days of build time, 4+ test iPhones, unlimited resources. All features from the Orchestrator.md will be built: encryption, auto-reparenting, SwiftData persistence, drag-and-drop tree editor, organiser promote, Data Flow screen, etc.

---

## Decision 20: Testing Strategy

**Question:** How will the app be tested during development?

**Choice:** `XCTest for logic + manual device testing for BLE/AI`

**Rationale:** XCTest unit tests cover all pure logic (models, routing, compaction, tree sync, message dedup). BLE mesh and on-device AI can only be validated on physical devices. 4+ iPhones available for full demo testing.

---

## Decision 21: Milestones

**Question:** How should the build be structured into vertical slices?

**Choice:** `5 milestones`

**Breakdown:**
1. **Foundation** — Xcode project setup, data models, Cactus SDK integration, BLE mesh core
2. **Tree & Roles** — tree builder UI, network discovery, role claiming protocol
3. **Comms Core** — push-to-talk, transcription, broadcast routing, compaction engine
4. **Full UX** — all 4 screens polished, SwiftData persistence, drag-and-drop tree editor
5. **Resilience** — encryption, auto-reparenting, dynamic tree editing, model download on first launch

---

## Summary Table

| # | Decision | Choice |
|---|---|---|
| 1 | iOS Target | iOS 16+ |
| 2 | Cactus SDK | Real SDK |
| 3 | Audio over BLE | Local only — transcripts/summaries only |
| 4 | STT Fallback | None — local-only |
| 5 | Compaction Latency | 1-2s |
| 6 | Tree Editor UI | Full drag-and-drop |
| 7 | Message Persistence | Full history + search |
| 8 | Role Transfer | Organiser can promote any node |
| 9 | Conflict Resolution | Organiser wins automatically |
| 10 | Dynamic Reparenting | Automatic |
| 11 | Encryption | E2E with pre-shared key |
| 12 | GPS/Location | Auto-embedded in all messages |
| 13 | Audio Transport | Text-only over BLE, no audio streaming |
| 14 | STT Engine | Cactus/Gemma 4 E4B for both STT and summarization |
| 15 | Model Tiers | E4B on all devices (MVP simplicity) |
| 16 | Audio Pipeline | Two-step: transcribe first, then compact separately |
| 17 | Model Delivery | Download on first launch |
| 18 | SDK Integration | Pre-built XCFramework + Cactus.swift |
| 19 | Scope | Full spec, no cuts |
| 20 | Testing Strategy | XCTest + manual device testing |
| 21 | Milestones | 5 vertical slices |
