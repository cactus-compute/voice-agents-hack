# TacNet Communication Pipeline

## Architecture

```
Audio In → [STT] → Text → [LLM] → Text → [TTS] → Audio Out
```

## Stage 1: Speech-to-Text (STT)

**Model:** Cactus-Compute/parakeet-ctc-0.6b (INT4, Apple NPU)

- 600M params, ~300-400 MB
- 201 ms latency on 20s audio, RTF 0.01 (100x real-time)
- 9.3% WER
- English-only, optimized for on-device live transcription
- Runs through existing `cactus_transcribe()` FFI
- Small enough to bundle in-app or fast-download, enabling instant STT without waiting for full Gemma download

## Stage 2: Text-to-Text (LLM Inference)

**Model:** Cactus-Compute/gemma-4-E4B-it (INT4, Apple NPU)

- ~4B params, ~6.4 GB runtime download from HuggingFace
- Handles summarization/compaction of tactical comms
- Runs through existing `cactus_complete()` FFI
- Already integrated via `CactusTacticalSummarizer` and `CompactionEngine`

## Stage 3: Text-to-Speech (TTS)

**Current choice:** Apple AVSpeechSynthesizer (Option 1)

No TTS models exist in the Cactus Compute ecosystem. Three options evaluated:

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| **1. AVSpeechSynthesizer** | Built-in iOS API | Zero download, zero dependencies, works offline, lowest integration effort | Robotic voice quality |
| 2. Cloud TTS API | ElevenLabs, Google, OpenAI | High quality, natural voices | Requires network, latency, cost, privacy concern for tactical comms |
| 3. On-device open-source TTS | Kokoro (~82M), Piper, OuteTTS | Natural voice, offline, private | Needs separate inference runtime (CoreML/ONNX), additional integration work |

**Decision:** Starting with Option 1 (AVSpeechSynthesizer). Can revisit with Option 3 if voice quality is insufficient. Option 2 is a fallback but less ideal for offline tactical scenarios.

## Setup: Parakeet Model Weights

The Parakeet CTC 0.6B model weights must be bundled in the app. Download them once during development:

```bash
# Download INT4 Apple NPU weights from HuggingFace
cd TacNet/Resources/ParakeetCTC/
# Download the apple zip from:
# https://huggingface.co/Cactus-Compute/parakeet-ctc-0.6b/tree/main/weights
# Extract the zip contents into this directory
```

After extraction, the directory should contain the model weight files. Then in Xcode:
1. Add `ParakeetCTC` folder to the project as a **folder reference** (blue folder icon)
2. Ensure it appears in Build Phases → Copy Bundle Resources

The weights are excluded from git via `.gitignore` (too large for version control).

## Implementation Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Model Handle Layer                         │
│                                                              │
│  ModelHandleProviding (protocol)                             │
│  ├── BundledModelInitializationService.parakeet  → STT       │
│  └── CactusModelInitializationService.shared     → LLM      │
└──────────────────────────────────────────────────────────────┘

┌──────────────┐    ┌───────────────────┐    ┌────────────────┐
│  PTT Record  │    │  Gemma Compaction │    │  TTS Playback  │
│              │    │                   │    │                │
│ AVAudioEngine│    │ CactusTactical-   │    │ AVSpeech-      │
│ → Parakeet   │    │ Summarizer        │    │ Synthesizer    │
│ → transcript │    │ → summary         │    │ → audio out    │
└──────┬───────┘    └────────┬──────────┘    └────────▲───────┘
       │                     │                        │
       ▼                     ▼                        │
┌──────────────────────────────────────────────────────────────┐
│              BLE Mesh (BluetoothMeshService)                 │
│  broadcast(transcript) ←→ compaction(summary)                │
│                                                              │
│  Receive path: message → MainViewModel → TTS speaks aloud   │
└──────────────────────────────────────────────────────────────┘
```
