# TacNet Architecture

## Overview

TacNet is a native iOS app (Swift/SwiftUI) that creates decentralized tactical communication networks over BLE mesh. Phones are organized in a command tree. Leaf nodes push-to-talk, parent nodes run on-device AI (Gemma 4 E4B via Cactus) to compress child messages into summaries that propagate upward.

## Component Relationships

```
Views (SwiftUI)           ViewModels (ObservableObject)     Services (Actors/Classes)
─────────────             ──────────────────────────        ───────────────────────
MainView          ←──→    MainViewModel              ←──→  AudioService
TreeView          ←──→    TreeViewModel              ←──→  BluetoothMeshService
DataFlowView      ←──→    DataFlowViewModel          ←──→  CompactionEngine
SettingsView      ←──→    OnboardingViewModel         ←──→  MessageRouter
TreeBuilderView   ←──→    TreeBuilderViewModel        ←──→  RoleClaimService
RoleSelectionView ←──→    RoleSelectionViewModel      ←──→  TreeSyncService
NetworkScanView                                       ←──→  NetworkDiscoveryService
PinEntryView                                          ←──→  ModelDownloadService
```

## Data Flow

1. **PTT → Transcript**: AudioService records PCM → CompactionEngine calls cactusTranscribe → transcript text
2. **Transcript → Broadcast**: MessageRouter wraps transcript in Message envelope → BluetoothMeshService floods to mesh
3. **Receive → Route**: BluetoothMeshService receives message → MessageDeduplicator checks UUID → MessageRouter decides: display? queue for compaction? ignore?
4. **Compaction**: CompactionEngine collects child transcripts → triggers on count/time/priority → calls cactusComplete → emits COMPACTION message upward
5. **Persistence**: All received messages → SwiftData store for after-action review

## Key Invariants

- Audio is NEVER transmitted over BLE. Only text (transcripts and summaries) crosses the mesh.
- Every phone runs both CBCentralManager and CBPeripheralManager simultaneously.
- All messages flood the entire mesh. App-layer filtering (MessageRouter) decides what to show based on tree position.
- BROADCAST: visible to sender's siblings + sender's parent only.
- COMPACTION: visible to sender's parent only.
- Tree version is monotonically increasing. Higher version replaces local state.
- Organiser-wins on claim conflicts.
- 60s BLE disconnect timeout triggers auto-release and auto-reparent.

## Model Architecture

- Single model: Gemma 4 E4B (4.5B params, INT4, ~2.8GB VRAM) on all devices
- Two-step pipeline: (1) cactusTranscribe for STT, (2) cactusComplete for compaction
- Model weights: 6.7GB, downloaded on first launch via ModelDownloadService
- Cactus SDK: XCFramework + Cactus.swift (free functions wrapping C FFI)

## Concurrency Model

- Swift Concurrency: async/await and actors
- AudioService: manages AVAudioEngine on a dedicated actor
- CompactionEngine: actor that queues messages and runs inference
- BluetoothMeshService: manages CBCentralManager/CBPeripheralManager (must be on main actor for CoreBluetooth)
- UI: @MainActor via SwiftUI
