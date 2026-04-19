# TacNet: Tactical Communication Network with On-Device AI Summarization

  

> A decentralized, offline-first voice communication system that mimics military radio hierarchy using a Bluetooth mesh of phones, each running Gemma 4 E4B (Edge 4B) via Cactus AI for real-time message compaction and upward propagation.

  

---

  

## 1. The Problem

  

In military operations (and disaster relief, construction sites, large events), radio communication hits a fundamental scaling wall:

  

- **A commander with 50 subordinates cannot listen to 50 simultaneous voice channels**

- Traditional radio requires humans to manually relay and summarize upward

- Centralized systems (cell towers, internet) are single points of failure

- Existing solutions require expensive proprietary hardware

  

**TacNet solves this**: every phone in the network runs a local AI that automatically compresses child messages into summaries and propagates them up a command tree — so the top-level operator gets a real-time, AI-compacted situational overview without hearing a single raw transmission.

  

---

  

## 2. System Architecture Overview

  

```

┌─────────────┐

│ ROOT NODE │ Commander / HQ

│ (Phone 0) │ Sees: compacted summary of ENTIRE network

└──────┬──────┘

│

Compacted summary from L1 nodes

│

┌────────────────┼────────────────┐

│ │ │

┌──────┴──────┐ ┌─────┴──────┐ ┌──────┴──────┐

│ L1 NODE │ │ L1 NODE │ │ L1 NODE │

│ (Phone 1) │ │ (Phone 2) │ │ (Phone 3) │ Platoon Leaders

└──────┬──────┘ └────────────┘ └──────┬──────┘

│ │

Compacted summary from L2 Compacted summary from L2

│ │

┌───────┼───────┐ ┌────────┼────────┐

│ │ │ │ │ │

┌──┴──┐ ┌─┴──┐ ┌──┴──┐ ┌───┴──┐ ┌──┴───┐ ┌──┴──┐

│ L2 │ │ L2 │ │ L2 │ │ L2 │ │ L2 │ │ L2 │

│ P4 │ │ P5 │ │ P6 │ │ P7 │ │ P8 │ │ P9 │ Squad Members

└─────┘ └─────┘ └─────┘ └──────┘ └──────┘ └─────┘

  

◄──── Siblings ────► ◄──── Siblings ────►

(hear each other (hear each other

via broadcast) via broadcast)

```

  

---

  

## 3. Two Communication Layers

  

The system operates on **two distinct layers** simultaneously:

  

### Layer 1: Broadcast (Radio Replacement)

  

```

┌─────────────────────────────────────────────────────────────┐

│ BROADCAST LAYER │

│ │

│ When Phone 4 pushes talk: │

│ │

│ 1. Phone 4 records audio and plays it LOCALLY │

│ 2. STT converts to transcript on-device (Cactus/Gemma) │

│ 3. Transcript crosses the BLE mesh to ALL phones │

│ │

│ Audio is NEVER transmitted over BLE — only transcript text │

│ crosses the mesh. No BLE audio profile is used. │

│ │

│ These nodes DISPLAY the transcript in their live feed: │

│ - Phone 5 (sibling) ✅ receives transcript via mesh │

│ - Phone 6 (sibling) ✅ receives transcript via mesh │

│ - Phone 1 (parent) ✅ receives transcript via mesh │

│ - Phone 0 (grandparent) ❌ filtered out (not sibling/parent) │

│ - Phone 7 (cousin) ❌ filtered out (not sibling/parent) │

│ │

│ Scope: siblings + immediate parent only │

│ Purpose: replaces traditional radio within a squad │

└─────────────────────────────────────────────────────────────┘

```

  

This mimics how a radio channel works — everyone on your channel (your siblings + your squad leader) sees your message. The key architectural difference: **audio is NEVER transmitted over BLE**; only the transcript text crosses the mesh. Receiving devices display the transcript in their live feed. No BLE audio profile is used.

  

### Layer 2: Compaction (AI Summarization Upward)

  

```

┌─────────────────────────────────────────────────────────────┐

│ COMPACTION LAYER │

│ │

│ Phone 1 (parent of P4, P5, P6) runs Gemma 4 locally: │

│ │

│ Input: │

│ - P4: Contact north side, 3 hostiles, engaging │

│ - P5: Moving to support P4, ETA 2 min │

│ - P6: South perimeter clear, holding position │

│ │

│ Gemma 4 compacts to: │

│ Squad Alpha: Contact north (P4 engaging, P5 │

│ reinforcing 2min). South clear (P6 holding). │

│ │

│ This summary is broadcast upward to Phone 0 (root). │

│ │

│ Phone 0 receives compacted summaries from ALL L1 nodes │

│ and runs Gemma 4 again to produce a top-level overview: │

│ │

│ SITREP: Alpha engaged north, reinforcing. │

│ Bravo holding east. Charlie advancing west on sched. │

│ │

└─────────────────────────────────────────────────────────────┘

```

  

---

  

## 4. Bluetooth Mesh Network

  

```

┌──────┐ ┌──────┐ ┌──────┐

│ P1 │◄──BT───►│ P2 │◄──BT───►│ P3 │

└──┬───┘ └──┬───┘ └──┬───┘

│ │ │

BT BT BT

│ │ │

┌──┴───┐ ┌──┴───┐ ┌──┴───┐

│ P4 │◄──BT───►│ P5 │◄──BT───►│ P6 │

└──┬───┘ └──┬───┘ └──────┘

│ │

BT BT

│ │

┌──┴───┐ ┌──┴───┐

│ P7 │◄──BT───►│ P8 │

└──────┘ └──────┘

  

BT = Bluetooth Low Energy connection

Every phone connects to all phones in BT range

Messages hop through the mesh to reach all nodes

```

  

**Key properties:**

- **Fully decentralized** — no central server, no internet required

- **Store-and-forward** — messages hop through intermediate phones

- **All nodes receive all messages** — the mesh floods every transmission

- **Logical filtering happens at the app layer** — each phone decides what to play/process based on the tree hierarchy

  

---

  

## 5. Node Roles & Responsibilities

  

Every phone in the network is identical software. The **tree configuration** determines its role:

  

| Role | Responsibilities | What it hears | What it produces |

|------|-----------------|---------------|-----------------|

| **Leaf Node** | Push-to-talk voice messages | Sibling broadcasts + parent broadcasts | Transcript text (STT on-device) |

| **Intermediate Node** | PTT + compaction of children | Sibling broadcasts + parent broadcasts + child broadcasts | Transcript text AND compacted summaries from children |

| **Root Node** | Compaction of all L1 summaries | L1 compacted summaries | Top-level SITREP (situation report) |

All messages carry embedded GPS coordinates (lat/lon/accuracy) from Core Location automatically.

  

---

  

## 6. On-Device AI Stack

  

```

┌─────────────────────────────────────────────┐

│ EACH PHONE RUNS: │

│ │

│ ┌───────────────────────────────────────┐ │

│ │ Cactus AI Runtime │ │

│ │ (Low-latency on-device inference) │ │

│ │ │ │ │

│ │ ┌─────────────────────────────────┐ │ │

│ │ │ Gemma 4 E4B Model │ │ │

│ │ │ (Google DeepMind's on-device │ │ │

│ │ │ multimodal model with native │ │ │

│ │ │ audio encoder — ~300M param │ │ │

│ │ │ audio conformer, no separate │ │ │

│ │ │ STT model needed) │ │ │

│ │ └─────────────────────────────────┘ │ │

│ └───────────────────────────────────────┘ │

│ │

│ ┌───────────────────────────────────────┐ │

│ │ Voice Processing Pipeline (2-step) │ │

│ │ │ │

│ │ Step 1: Mic ─► Gemma 4 E4B ─► Text │ │

│ │ (native audio conformer, STT) │ │

│ │ │ │

│ │ Step 2: Text ─► Gemma 4 E4B ─► │ │

│ │ Compacted Summary │ │

│ └───────────────────────────────────────┘ │

│ │

│ ┌───────────────────────────────────────┐ │

│ │ Bluetooth Mesh Module │ │

│ │ (Send/receive to all nearby phones) │ │

│ └───────────────────────────────────────┘ │

└─────────────────────────────────────────────┘

```

  

### Why Cactus + Gemma 4 E4B?

  

- **Gemma 4 E4B** is Google DeepMind's on-device multimodal model with native audio input (~300M param audio conformer encoder)

- **Single model** handles both STT and summarization — no separate Whisper/STT model needed

- **E4B = Edge 4B** — 4.5B effective params, 8B with embeddings, ~2.8GB VRAM at INT4

- **Fast** — 30s audio processes in ~0.3s on Apple Silicon, 40 tok/s decode

- **Cactus** provides the low-latency inference engine optimized for mobile/edge devices

- **No internet required** — entire AI pipeline runs on the phone

- **Hybrid routing** — if a phone has internet, complex tasks can optionally route to cloud (but the system works fully offline)

  

---

  

## 7. Message Flow: Complete Example

  

```

TIME ACTION

─────────────────────────────────────────────────────────────────

  

t=0 P4 (leaf) pushes talk: We've spotted movement in sector 7

│

├──► Bluetooth mesh floods message to ALL phones

│

├──► P5, P6 (siblings): DISPLAY transcript ✅ (received via mesh)

├──► P1 (parent): DISPLAY transcript ✅ (received via mesh) + QUEUE for compaction

├──► P0, P2, P3, P7-P9: RECEIVE transcript but IGNORE (not sibling/parent)

  

t=5 P5 (leaf) pushes talk: Confirmed, I see 4 individuals, armed

│

├──► P4, P6: DISPLAY transcript ✅ (received via mesh)

├──► P1 (parent): DISPLAY transcript ✅ (received via mesh) + QUEUE for compaction

  

t=8 P6 (leaf) pushes talk: Rear is clear, no movement

│

├──► P4, P5: DISPLAY transcript ✅ (received via mesh)

├──► P1 (parent): DISPLAY transcript ✅ (received via mesh) + QUEUE for compaction

  

t=10 P1's compaction triggers (time window / message threshold):

│

│ Gemma 4 processes queued messages:

│ IN: spotted movement sector 7

│ confirmed 4 armed individuals

│ rear clear

│ OUT: Squad-1: 4 armed contacts sector 7 (confirmed by 2),

│ rear secure.

│

└──► Compacted summary broadcast with COMPACTION tag

│

└──► P0 (root): RECEIVES compacted summary ✅

  

t=12 P0 receives compacted summaries from P1, P2, P3:

│

│ Gemma 4 compacts all L1 summaries:

│ OUT: SITREP: Squad-1 has 4 armed contacts sector 7.

│ Squad-2 holding perimeter east. Squad-3 advancing

│ on schedule.

│

└──► Displayed on root commander's screen as live SITREP

```

  

---

  

## 8. Message Types & Protocol

  

```

┌──────────────────────────────────────────────────────────┐

│ MESSAGE ENVELOPE │

├──────────────────────────────────────────────────────────┤

│ { │

│ id: uuid-v4, │

│ type: BROADCAST | COMPACTION | CLAIM | RELEASE | │
│         TREE_UPDATE | PROMOTE | CLAIM_REJECTED, │

│ sender_id: node-uuid, │

│ sender_role: Alpha-2 (position in tree), │

│ parent_id: node-uuid, │

│ tree_level: 2, │

│ timestamp: 1713200000, │

│ ttl: 5, // mesh hop limit │

│ payload: { │

│ location: { lat, lon, accuracy }, // auto-embedded GPS │

│ encrypted: true, // E2E via pre-shared key │

│ payload: { │

│   transcript: ..., // STT result (BROADCAST only) │

│   summary: ..., // for COMPACTION only) │

│   source_ids: [...], // messages summarized │

│   // CLAIM/RELEASE/TREE_UPDATE/PROMOTE/CLAIM_REJECTED │

│   // type field carries intent; payload varies by type │

│ } │

│ } │

└──────────────────────────────────────────────────────────┘

```

  

### Routing Rules (App Layer)

  

| Message Type | Sender | Who plays/displays it |

|---|---|---|

| `BROADCAST` | Any node | Sender's siblings + sender's parent |

| `COMPACTION` | Intermediate/root node | That node's parent only |

  

---

  

## 9. Tree Configuration — Organiser-Driven, Fluid Roles

  

The system has two distinct user modes: **Organiser** (creates the hierarchy) and **Participant** (joins and claims a role). The tree is fully customisable — there are no hardcoded roles.

  

### 9.1 Flow: Organiser Creates the Network

  

The organiser (typically the commander / site lead) opens the app first and builds the tree from scratch using a drag-and-drop editor:

  

```

┌─────────────────────────────────────────────┐

│ ORGANISER: BUILD YOUR NETWORK │

│ │

│ ┌─────────────────────────────────────┐ │

│ │ [+ Add Root Node] │ │

│ │ │ │

│ │ ┌──────────────┐ │ │

│ │ │ Commander │ ← tap to │ │

│ │ │ (rename) │ rename │ │

│ │ └──────┬───────┘ │ │

│ │ │ │ │

│ │ [+ Add Child] │ │

│ │ │ │ │

│ │ ┌────────┼────────┐ │ │

│ │ │ │ │ │ │

│ │ ┌──┴───┐ ┌──┴───┐ ┌──┴───┐ │ │

│ │ │Alpha │ │Bravo │ │ │ │ │

│ │ │Lead │ │Lead │ │[+ Add│ │ │

│ │ └──┬───┘ └──────┘ │ More]│ │ │

│ │ │ └──────┘ │ │

│ │ [+ Add Child] │ │

│ │ │ │ │

│ │ ┌──┴───┐ ┌──────┐ ┌──────┐ │ │

│ │ │A-1 │ │A-2 │ │[+] │ │ │

│ │ └──────┘ └──────┘ └──────┘ │ │

│ └─────────────────────────────────────┘ │

│ │

│ Network Name: [ Operation Nightfall ] │

│ Network PIN: [ 4-digit optional PIN ] │

│ │

│ [Publish Network] │

└─────────────────────────────────────────────┘

```

  

**Organiser capabilities:**

- Name each node (free text — Alpha Lead, Medic, Drone Operator, Foreman, anything)

- Add/remove children at any depth

- Set a network name + optional PIN for access control

- Reorder nodes via drag-and-drop

- Publish the tree — this starts BLE advertising the network

  

### 9.2 Flow: Participant Joins and Claims a Role

  

When a participant opens the app, they see nearby TacNet networks. They tap to join, enter the PIN if required, and then see the full tree with **available / claimed** status on every node:

  

```

┌─────────────────────────────────────────────┐

│ JOIN: Operation Nightfall │

│ │

│ Select your role: │

│ │

│ ┌──────────────────┐ │

│ │ Commander │ 🔴 Claimed │

│ │ (Organiser) │ by: iPhone-Jake │

│ └──────┬───────────┘ │

│ │ │

│ ┌────────┼────────┐ │

│ │ │ │ │

│ ┌──┴──────┐ │ ┌─────┴────┐ │

│ │ Alpha │ │ │ Charlie │ │

│ │ Lead │ │ │ Lead │ │

│ │ 🔴 Jake │ │ │ 🟢 OPEN │ ← tap to │

│ └──┬──────┘ │ └──────────┘ claim │

│ │ │ │

│ ┌──┴──┐ ┌──┴──────┐ │

│ │ A-1 │ │ Bravo │ │

│ │🟢OPEN│ │ Lead │ │

│ └─────┘ │ 🟡 Pending│ │

│ └──────────┘ │

│ │

│ 🔴 Claimed 🟡 Pending 🟢 Open │

│ │

│ [ Claim Charlie Lead ] │

└─────────────────────────────────────────────┘

```

  

**Participant flow:**

1. App scans BLE → discovers nearby TacNet networks

2. Tap a network → enter PIN if set → receive the tree JSON

3. See all nodes with live claim status (synced via BLE)

4. Tap an open node → **Claim this role**

5. Claim broadcasts to all peers → node turns red (claimed) on everyone's screen

6. Participant is now live in the network with routing rules active

  

### 9.3 Role Claim Protocol

  

```

┌──────────────────────────────────────────────────────────┐

│ ROLE CLAIM PROTOCOL │

│ │

│ 1. DISCOVER │

│ Participant scans BLE for TacNet service UUID │

│ Receives: network_name, node_count, open_slots │

│ │

│ 2. AUTHENTICATE │

│ If PIN set: participant enters PIN │

│ Organiser's phone validates → grants/denies │

│ │

│ 3. SYNC TREE │

│ Full tree JSON transferred via BLE │

│ Includes claim status for every node │

│ │

│ 4. CLAIM │

│ Participant taps open node → sends CLAIM message: │

│ { │

│ type: CLAIM, │

│ node_id: charlie-lead, │

│ device_id: iPhone-Sara, │

│ timestamp: 1713200000 │

│ } │

│ Flooded to all peers via mesh │

│ │

│ 5. CONFIRM │

│ All nodes update their local tree state │

│ If two devices claim the same node simultaneously: │

│ → organiser device wins automatically │

│ → loser receives CLAIM_REJECTED: organiser_wins │

│ → loser returns to role selection │

│ │

│ 6. RELEASE │

│ If a device disconnects or user taps Release Role: │

│ → RELEASE message flooded │

│ → Node goes back to 🟢 OPEN │

│ → Auto-release after 60s BLE disconnect timeout │

│ │

│ 7. LIVE UPDATES │

│ Tree state changes (claim/release/new nodes) │

│ are broadcast as TREE_UPDATE messages in the mesh │

│ Every phone stays in sync │

└──────────────────────────────────────────────────────────┘

```

  

### 9.4 Organiser Can Modify the Tree Live

  

The organiser retains edit access even after publishing. They can:

  

| Action | What happens |

|---|---|

| **Add a node** | `TREE_UPDATE` broadcast → all phones see the new open slot |

| **Remove an empty node** | `TREE_UPDATE` broadcast → node disappears from everyone's tree |

| **Remove a claimed node** | Claimed user gets kicked back to role selection with a notification |

| **Rename a node** | `TREE_UPDATE` broadcast → label updates everywhere |

| **Move a node** (re-parent) | `TREE_UPDATE` broadcast → routing rules update automatically |
| **Promote to organiser** | `PROMOTE` broadcast → target device gains organiser permissions; `created_by` updates; old organiser becomes participant |

  

This means the hierarchy is **fluid during operation** — if the commander needs to restructure squads mid-mission, they edit the tree and everyone's routing updates instantly.

  

### 9.5 Tree Config Data Model

  

```

Example Tree Config (JSON) — as distributed over BLE:

{

network_name: Operation Nightfall,

network_id: uuid-v4,

created_by: iPhone-Jake,

pin_hash: sha256..., // null if no PIN

version: 7, // increments on every edit

tree: {

id: commander,

label: Commander,

claimed_by: iPhone-Jake,

children: [

{

id: alpha-lead,

label: Alpha Lead,

claimed_by: iPhone-Sara,

children: [

{ id: alpha-1, label: Alpha-1, claimed_by: null },

{ id: alpha-2, label: Alpha-2, claimed_by: iPhone-Tom },

{ id: alpha-3, label: Alpha-3, claimed_by: null }

]

},

{

id: bravo-lead,

label: Bravo Lead,

claimed_by: null,

children: [

{ id: bravo-1, label: Bravo-1, claimed_by: null },

{ id: bravo-2, label: Bravo-2, claimed_by: null }

]

}

]

}

}

```

  

The `version` field is key — when a phone receives a `TREE_UPDATE` with a higher version than its local copy, it replaces its tree. This ensures convergence across the mesh even if updates arrive out of order.

  

---

  

## 10. Mobile UX

  

```

┌─────────────────────────────────┐

│ TacNet v1.0 │

│ │

│ ┌─────────────────────────┐ │

│ │ LIVE FEED │ │

│ │ │ │

│ │ Alpha-2: Movement │ │

│ │ in sector 7 │ │

│ │ │ │

│ │ Alpha-3: Confirmed, │ │

│ │ 4 armed │ │

│ │ │ │

│ │ ─── COMPACTION ─── │ │

│ │ Squad Alpha: 4 armed │ │

│ │ contacts sector 7, │ │

│ │ rear secure. │ │

│ │ │ │

│ └─────────────────────────┘ │

│ │

│ ┌─────────────────────────┐ │

│ │ │ │

│ │ 🎙 PUSH TO TALK │ │

│ │ │ │

│ └─────────────────────────┘ │

│ │

│ [Config] [Tree View] [Map] │

└─────────────────────────────────┘

```

  

### Screens

  

1. **Main Screen** — Live feed of broadcasts from siblings + compaction summaries from children. Large push-to-talk button.

2. **Config Screen** — View the full tree. Tap a node to claim it as my position. Shows connection status of Bluetooth mesh peers.

3. **Tree View** — Visual tree with live status indicators (active, idle, disconnected). Compaction summaries shown inline at parent nodes.

4. **Data Flow Screen** — Transparent view of what the AI is doing on this phone. Shows raw input, processing status, and output.

  

### Data Flow Tab (Screen 4)

  

This screen gives full visibility into what data is entering the node, how Gemma 4 is processing it, and what is being emitted. Critical for debugging in the field and for the hackathon demo.

  

```

┌─────────────────────────────────────┐

│ DATA FLOW — Alpha Lead │

│ │

│ ┌─ INCOMING ─────────────────────┐ │

│ │ │ │

│ │ 14:02:05 Alpha-1 [BROADCAST] │ │

│ │ Enemy spotted near bldg 4 │ │

│ │ │ │

│ │ 14:02:12 Alpha-2 [BROADCAST] │ │

│ │ Confirmed, 4 armed │ │

│ │ │ │

│ │ 14:02:30 Alpha-3 [BROADCAST] │ │

│ │ Rear clear, holding │ │

│ │ │ │

│ │ 14:02:35 HQ [COMPACTION ↓] │ │

│ │ All squads push to obj. │ │

│ └────────────────────────────────┘ │

│ │

│ ┌─ PROCESSING ───────────────────┐ │

│ │ ⚙ Gemma 4 via Cactus │ │

│ │ │ │

│ │ Status: ● Compacting (3 msgs) │ │

│ │ Trigger: msg_count >= 3 │ │

│ │ Latency: 340ms │ │

│ │ Model: gemma-4-2b-it │ │

│ │ │ │

│ │ Input tokens: 87 │ │

│ │ Output tokens: 22 │ │

│ │ Compression: 74.7% │ │

│ └────────────────────────────────┘ │

│ │

│ ┌─ OUTGOING ─────────────────────┐ │

│ │ │ │

│ │ 14:02:36 [COMPACTION → HQ] │ │

│ │ Squad Alpha: 4 armed │ │

│ │ contacts bldg 4 (2x conf). │ │

│ │ Rear secure. │ │

│ │ │ │

│ │ Sent to: HQ (parent) │ │

│ │ Summarized: 3 messages │ │

│ │ Source: Alpha-1, 2, 3 │ │

│ └────────────────────────────────┘ │

│ │

│ [Main] [Config] [Tree] [Flow] │

└─────────────────────────────────────┘

```

  

**Data Flow tab sections:**

  

| Section | Contents |

|---|---|

| **INCOMING** | All messages this node receives and processes — broadcasts from children, compactions from below, orders from above. Timestamped, labeled by type. |

| **PROCESSING** | Real-time status of the Gemma 4 compaction engine — is it idle, queuing, or actively compacting? Shows trigger reason, latency, token counts, and compression ratio. |

| **OUTGOING** | Every compaction summary this node has produced and emitted upward. Shows destination, source messages summarized, and the output text. |

  

---

  

## 11. Compaction Engine (Gemma 4 Prompt Design)

  

The on-device Gemma 4 model is prompted with a structured template:

  

```

SYSTEM: You are a tactical communications summarizer. Compress the

following radio messages from your subordinates into a brief, actionable

summary. Preserve: locations, threat counts, unit status, urgent items.

Remove: filler, repetition, acknowledgements. Keep under 30 words.

  

MESSAGES:

- [Alpha-1, 14:02:05]: We've spotted movement in sector 7, over

- [Alpha-2, 14:02:12]: Copy that, I can confirm, 4 individuals, armed

- [Alpha-3, 14:02:30]: Rear perimeter all clear, no movement, holding

  

SUMMARY:

```

  

**Output**: `Squad Alpha: 4 armed contacts sector 7 (2x confirmed). Rear clear, holding.`

  

### Compaction Triggers

  

| Trigger | Description |

|---------|-------------|

| **Time window** | Every N seconds (configurable, e.g. 30s) |

| **Message count** | After N messages from children (e.g. 3) |

| **Priority keyword** | Immediately on words like contact, casualty, emergency |

  

---

  

## 12. Technical Stack

  

### Platform: Native iOS (Swift)

  

| Layer | Technology | Notes |

|---|---|---|

| **Language** | Swift 5.9+ | Native iOS, no cross-platform overhead |

| **UI Framework** | SwiftUI | Declarative UI for all 4 tabs |

| **On-Device AI** | Cactus AI SDK (Swift) + Gemma 4 E4B | Cactus provides low-latency inference; Gemma 4 E4B handles both STT and summarization natively |

| **Voice Input** | AVFoundation (`AVAudioEngine`) | Push-to-talk recording, raw audio capture |

| **Speech-to-Text** | Gemma 4 E4B via Cactus (native audio encoder) | Native ~300M param audio conformer — not a separate STT model. On-device only, no internet. |

| **Bluetooth Mesh** | Core Bluetooth (BLE) | `CBCentralManager` + `CBPeripheralManager` — each phone acts as both central and peripheral |

| **Message Serialization** | `Codable` structs → JSON → BLE | Swift-native encoding, compact payloads over GATT characteristics |

| **Local Storage** | SwiftData | Full message history with full-text search for after-action review. Ring buffer optional for storage limits. |

| **Audio Playback** | AVFoundation (`AVAudioPlayer`) | Local recording feedback only — received messages are text transcripts displayed in feed, not played as audio. Model weights (6.7GB INT4) are downloaded on first launch, not bundled. |

| **Concurrency** | Swift Concurrency (`async`/`await`, Actors) | BLE scanning, AI inference, and audio on separate actors to avoid blocking UI |

| **Tree Config** | `Codable` JSON stored in app sandbox | Shared tree distributed via BLE handshake on first mesh connection |

| **Minimum iOS** | iOS 16.0+ | Required for modern Swift Concurrency, SwiftData, and stable BLE mesh APIs. |

  

### Architecture: Swift App Structure

  

```

TacNet/

├── TacNetApp.swift # App entry point — routes to Onboarding or Main

├── Models/

│ ├── TreeNode.swift # Tree hierarchy model (Codable, claimed_by, version)

│ ├── NetworkConfig.swift # Network name, id, pin_hash, version, tree root

│ ├── Message.swift # Message envelope (BROADCAST / COMPACTION / CLAIM / TREE_UPDATE)

│ └── NodeIdentity.swift # Local state: I am this node + device ID

├── Services/

│ ├── BluetoothMeshService.swift # Core Bluetooth central + peripheral

│ │ # Handles discovery, flooding, dedup (by UUID)

│ ├── NetworkDiscoveryService.swift # Scans for nearby TacNet networks (for participants)

│ ├── RoleClaimService.swift # Handles CLAIM / RELEASE protocol + conflict resolution

│ ├── TreeSyncService.swift # Distributes tree updates, version-based convergence

│ ├── AudioService.swift # AVAudioEngine for record + AVAudioPlayer for playback

│ ├── CompactionEngine.swift # Manages Gemma 4 E4B inference via Cactus SDK

│ │ # Queues child messages, triggers compaction, emits summary

│ ├── ModelDownloadService.swift # Handles first-launch model download with progress UI

│ │ # Downloads Gemma 4 E4B weights (6.7GB INT4) on first run

│ └── MessageRouter.swift # Decides: display transcript? queue for compaction? ignore?

│ # Applies tree-based routing rules

├── ViewModels/

│ ├── OnboardingViewModel.swift # Create vs Join network flow

│ ├── TreeBuilderViewModel.swift # Organiser: add/remove/rename/reorder nodes

│ ├── RoleSelectionViewModel.swift # Participant: browse tree, claim a node

│ ├── MainViewModel.swift # Live feed + PTT state

│ ├── TreeViewModel.swift # Visual tree with live claim indicators

│ └── DataFlowViewModel.swift # Incoming / Processing / Outgoing streams

├── Views/

│ ├── Onboarding/

│ │ ├── WelcomeView.swift # Create Network or Join Network

│ │ ├── TreeBuilderView.swift # Organiser: drag-and-drop tree editor

│ │ ├── NetworkScanView.swift # Participant: list of nearby networks

│ │ ├── PinEntryView.swift # PIN gate (if network requires it)

│ │ └── RoleSelectionView.swift # Participant: tap to claim a node

│ ├── Main/

│ │ ├── MainView.swift # Tab 1: Live feed + push-to-talk button

│ │ ├── TreeView.swift # Tab 2: Visual tree hierarchy with live status

│ │ ├── DataFlowView.swift # Tab 3: AI transparency view

│ │ └── SettingsView.swift # Tab 4: Release role, edit tree (organiser only)

│ └── Components/

│ ├── TreeNodeView.swift # Reusable node cell (name, claim status, indicator)

│ └── PTTButton.swift # Push-to-talk button component

└── Utilities/

├── MessageDeduplicator.swift # UUID-based seen-set for mesh flooding

└── TreeHelpers.swift # Parent/sibling/children lookups

```

  

### Key Swift Frameworks Used

  

```

┌─────────────────────────────────────────────────────────────────┐

│ iOS FRAMEWORK MAP │

│ │

│ ┌──────────────┐ ┌──────────────┐ ┌────────────────────┐ │

│ │ SwiftUI │ │ AVFoundation │ │ Core Bluetooth │ │

│ │ (All UI) │ │ (Audio I/O) │ │ (BLE Mesh) │ │

│ └──────┬───────┘ └──────┬───────┘ └────────┬───────────┘ │

│ │ │ │ │

│ ▼ ▼ ▼ │

│ ┌──────────────────────────────────────────────────────────┐ │

│ │ Swift Concurrency (Actors) │ │

│ │ UI Actor Audio Actor BLE Actor AI Actor │ │

│ └──────────────────────────┬───────────────────────────────┘ │

│ │ │

│ ▼ │

│ ┌──────────────────┐ │

│ │ Cactus SDK │ │

│ │ (Gemma 4) │ │

│ └──────────────────┘ │

│ │

│ ┌──────────────┐ │

│ │ SwiftData │ │

│ │ (Storage + Search) │ │

│ └──────────────┘ │

└─────────────────────────────────────────────────────────────────┘

```

  

### BLE Implementation Detail (Core Bluetooth)

  

Each phone runs **both** a `CBCentralManager` (scanner/client) and a `CBPeripheralManager` (advertiser/server) simultaneously:

  

```swift

// Simplified BLE service architecture

let tacNetServiceUUID = CBUUID(string: TACNET-...)

  

// GATT Characteristics:

let broadcastCharUUID = CBUUID(...) // For BROADCAST messages

let compactionCharUUID = CBUUID(...) // For COMPACTION messages

let treeConfigCharUUID = CBUUID(...) // For initial tree sync

  

// Each phone:

// 1. Advertises as peripheral → other phones connect to it

// 2. Scans as central → connects to nearby phones

// 3. On message receive → check UUID dedup → re-broadcast to all peers

// 4. App layer filters by tree role (MessageRouter.swift)

```

  

### Cactus SDK Integration

  

```swift

// CompactionEngine.swift — uses real Cactus Swift API

import Cactus

  

actor CompactionEngine {

private var context: OpaquePointer? // Cactus context

private var messageQueue: [Message] = []

  

init(modelPath: String) async throws {

// Initialize Cactus context with Gemma 4 E4B model

// cactusInit returns an OpaquePointer context

let params = cactusDefaultParams()

context = cactusInit(modelPath, params)

}

  

// Step 1: Transcribe audio to text (native Gemma 4 E4B audio encoder)

func transcribeAudio(audioPath: String) async -> String {

// cactusTranscribe uses Gemma 4 E4B's native ~300M param audio conformer

// No separate STT model needed — single model handles audio input

return cactusTranscribe(context, audioPath)

}

  

// Step 2: Compact/summarize transcripts

func queueMessage(_ msg: Message) async -> CompactionResult? {

messageQueue.append(msg)

  

guard shouldTriggerCompaction() else { return nil }

  

let prompt = buildCompactionPrompt(from: messageQueue)

// cactusComplete runs text generation on Gemma 4 E4B

let summary = cactusComplete(context, prompt, 64) // maxTokens: 64

  

let result = CompactionResult(

summary: summary,

sourceIDs: messageQueue.map(\\.id)

)

  

messageQueue.removeAll()

return result

}

  

private func shouldTriggerCompaction() -> Bool {

messageQueue.count >= 3 // or time-based trigger

}

  

deinit {

if let ctx = context { cactusFree(ctx) }

}

}

```

  

---

  

## 13. Bluetooth Mesh Protocol

  

```

┌──────────────────────────────────────────────────┐

│ BLE MESH PROTOCOL │

│ │

│ 1. DISCOVERY │

│ Phone scans for nearby TacNet devices │

│ Connects to all found peers │

│ │

│ 2. ENCRYPT_KEY_EXCHANGE │

│ After BLE connection: participant receives session key │

│ Key encrypted with PIN-derived key │

│ All messages AES-256 E2E encrypted │

│ │

│ 3. FLOODING │

│ On send: message broadcast to all peers │

│ On receive: if not seen before, re-broadcast │

│ Dedup via message UUID │

│ │

│ 4. AUTO_REPARENT │
│ If parent disconnects (60s timeout): │
│ - Children traverse upward to find nearest connected ancestor │
│ - TREE_UPDATE broadcast with new parent_id │
│ - Routing rules update automatically │
│ │
│ 5. TTL (Time-To-Live) │

│ Each message has TTL (default: 10) │

│ Decremented on each hop │

│ Prevents infinite loops │

│ │

│ 6. DELIVERY │

│ All phones receive all messages │

│ App layer filters by tree role │

│ │

│ Range per hop: ~30-100m (BLE 5.0) │

│ Effective range: hops x range │

└──────────────────────────────────────────────────┘

```

  

---

  

## 14. Hackathon Demo Scenario

  

### Setup: 4 phones minimum

  

```

Phone 0 (Commander)

│

┌──────┴──────┐

│ │

Phone 1 Phone 2

(Alpha Lead) (Bravo Lead)

│

Phone 3

(Alpha-1)

```

  

### Demo Flow

  

1. **Phone 3** (Alpha-1): Push to talk — Enemy spotted near building 4

2. **Phone 1** (Alpha Lead): Hears the message live (sibling/parent)

3. **Phone 1** auto-compacts: *Alpha: Enemy contact near building 4*

4. **Phone 0** (Commander): Sees compacted summary appear on screen

5. **Phone 2** (Bravo Lead): Push to talk — Bravo in position, all clear

6. **Phone 0**: Sees both summaries, Gemma 4 produces: *SITREP: Alpha reports contact bldg 4. Bravo in position, clear.*

  

**Total demo time: ~2 minutes. Zero internet. Zero servers.**

  

---

  

## 15. Why This Wins at the Hackathon

  

| Criteria | TacNet |

|---|---|

| **Uses Cactus** | Core inference engine on every phone |

| **Uses Gemma 4** | On-device voice-to-summary, the exact new capability |

| **Voice-controlled** | Push-to-talk is the primary interaction |

| **On-device** | Fully offline, no cloud dependency |

| **Novel** | No one has done AI-compacted hierarchical comms over BLE mesh |

| **Demo-able** | Works with 3-4 phones in a room, visually compelling |

| **Real-world impact** | Military, disaster relief, construction, events |

  

---

  

## 16. Extension Opportunities

  

- **Priority escalation**: Gemma 4 detects urgency keywords and escalates directly to root, bypassing normal compaction timing

- **Two-way summaries**: Commander sends orders downward, compacted/expanded at each level for appropriate detail

- **Two-way summaries**: Commander sends orders downward, compacted and expanded at each level for appropriate detail at each tier
- **Offline-first sync**: When internet is available, sync all raw messages to cloud for after-action review
- **Multi-language**: Gemma 4 translates messages between nodes speaking different languages
- **Map view**: GPS coordinates auto-embedded in all messages — commander sees all node positions on a shared map (5th UI tab)

  

---

  

## 17. Data Flow Diagram (Complete)

  

```

┌─────────┐

│ ROOT │

│ Phone 0 │

└────┬────┘

│

┌──────────┼──────────┐

│ │ │

▼ ▼ ▼

┌─────────┐┌─────────┐┌─────────┐

│ L1 Node ││ L1 Node ││ L1 Node │

│ Phone 1 ││ Phone 2 ││ Phone 3 │

└────┬────┘└─────────┘└────┬────┘

│ │

┌────┼────┐ ┌────┼────┐

│ │ │ │ │ │

▼ ▼ ▼ ▼ ▼ ▼

P4 P5 P6 P7 P8 P9

  
  

════════════════════════════════════════

BROADCAST (blue): Sibling ↔ Sibling + Child → Parent

COMPACTION (purple): Parent collects → Gemma 4 summarizes → sends UP

════════════════════════════════════════

  

P4 speaks ──►┬──► P5 hears (sibling) ─── BROADCAST

├──► P6 hears (sibling) ─── BROADCAST

└──► P1 hears (parent) ─── BROADCAST

│

▼

P1 collects P4+P5+P6 msgs

P1 runs Gemma 4 compaction

P1 emits summary ─── COMPACTION

│

▼

P0 collects P1+P2+P3 summaries

P0 runs Gemma 4 compaction

P0 displays top-level SITREP ─── COMPACTION

```

  

---

  

*Built for the Cactus x Gemma 4 Hackathon at YC HQ*

---

## 18. Design Decisions & Clarifications

The following decisions were made to refine the spec:

| Decision | Choice |
|---|---|
| **Minimum iOS** | iOS 16.0+ | SwiftData, modern Swift Concurrency, stable BLE mesh APIs required. |
| **Cactus SDK** | Real SDK — XCFramework built from source (86s build), Swift API via Cactus.swift |
| **Audio over BLE** | Audio is NEVER transmitted. Only transcript text crosses the mesh. No BLE audio profile. |
| **STT** | Native via Gemma 4 E4B audio encoder (~300M params). No Whisper, no Apple Speech. Two-step: transcribe first, then compact. |
| **Compaction latency** | 1-2s target — acceptable for tactical use, prioritizes accuracy over raw speed. Benchmarked: 30s audio end-to-end in 0.3s, 40 tok/s decode on Apple Silicon. |
| **Tree editor** | Full drag-and-drop UI — add/remove/reparent/reorder nodes visually. |
| **Message history** | Full persistence with search — supports after-action review. |
| **Role transfer** | Organiser can promote any claimed node to organiser mid-operation. |
| **Conflict resolution** | If two devices race to claim the same node, organiser device wins automatically. |
| **Dynamic reparenting** | If a parent goes offline, children automatically reparent to the nearest available ancestor. |
| **Encryption** | End-to-end encryption on all BLE messages using a pre-shared key established on network join. |
| **Location data** | GPS coordinates embedded automatically in all messages. |
| **Model delivery** | Download on first launch (6.7GB INT4) |
| **Model tier** | E4B on all devices for MVP simplicity (4.5B params, ~2.8GB VRAM) |
| **Scope** | Full spec, no cuts. 5 milestones. |
| **Testing** | XCTest for logic + manual device testing for BLE/AI |
