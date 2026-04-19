# TacNet Setup Log

## Date: 2026-04-15

---

## 1. Gemma 4 E4B Model Download

### Problem: HuggingFace Download Failure
- Attempted to download `google/gemma-4-E4B-it` (14.89 GB, full precision BF16) via `huggingface_hub` / `huggingface-cli`.
- Download repeatedly reset to 0% at ~90% progress.
- **Root cause:** Bug in `hf-xet` protocol (v1.4.3). The xet CAS reconstruction endpoint returns `416 Range Not Satisfiable` errors. Even when the download internally "completes," `huggingface_hub` fails to rename the `.incomplete` file, so the next run starts from scratch.
- Confirmed via xet logs at `~/.cache/huggingface/xet/logs/` -- 8 separate download attempts, all hit the same 416 error.
- This is a known issue: https://github.com/huggingface/xet-core/issues/581
- Workaround (if ever needed): `HF_HUB_DISABLE_XET=1` forces plain HTTP download with proper resume support.

### Solution: Cactus CLI
Instead of downloading raw safetensors from HuggingFace, we use the **Cactus CLI** which:
1. Downloads pre-quantized INT4 weights from `Cactus-Compute/gemma-4-E4B-it` on HuggingFace (bypasses xet entirely)
2. Converts to Cactus's optimized `.weights` format with Apple NPU support
3. Is the same engine used in the iOS app at runtime

### Installation Steps
```bash
# Install Cactus CLI
brew install cactus-compute/cactus/cactus

# Download Gemma 4 E4B (auto-downloads, converts, quantizes to INT4)
cactus download google/gemma-4-E4B-it --precision INT4

# Test interactively
cactus run google/gemma-4-E4B-it
```

### Model Location
- **Path:** `/opt/homebrew/opt/cactus/libexec/weights/gemma-4-e4b-it/`
- **Size:** 6.7 GB (INT4 quantized)
- **Format:** Cactus `.weights` files (2088 files: LLM layers, audio conformer, vision encoder with `.mlpackage` for Apple NPU)
- **Library:** `/opt/homebrew/opt/cactus/lib/libcactus.dylib` (3.7 MB)

### Model Specs (Gemma 4 E4B)
| Property | Value |
|---|---|
| Effective Parameters | 4.5B (8B with embeddings) |
| Layers | 42 |
| Context Length | 128K tokens |
| Modalities | Text, Image, Audio |
| Audio Encoder | ~300M params (native, not bolt-on STT) |
| Vision Encoder | ~150M params |
| VRAM at INT4 | ~2.8 GB |
| Target Hardware | iPhone 15/16 (8 GB RAM) |

### Obsolete Files (safe to delete)
- `/Users/yifuzuo/Desktop/yifu/startup/projects/hackathon/download_model.py` -- HuggingFace download script, no longer needed
- `/Users/yifuzuo/Desktop/yifu/startup/projects/hackathon/gemma-4-E4B-it/` -- 15 GB raw safetensors, not used by Cactus

---

## 2. Cactus SDK for iOS

### Build Command
```bash
# PREREQUISITE: Xcode must be the active developer toolchain (not just CommandLineTools)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Build from the cloned source repo (Homebrew install doesn't include build scripts)
cd /Users/yifuzuo/Desktop/yifu/startup/projects/hackathon/cactus
bash apple/build.sh     # Produces static libs + XCFrameworks for iOS/macOS
```

### Build Fix Applied
The CMakeLists.txt referenced `kernel_sve2.cpp` which doesn't exist in the repo yet (WIP feature).
Fixed by setting `ENABLE_SVE2` to `"OFF"` in `apple/CmakeLists.txt` line 252.

### Build Output (86 seconds, all successful)
| Artifact | Path |
|---|---|
| **iOS Device static lib** | `cactus/apple/libcactus-device.a` |
| **iOS Simulator static lib** | `cactus/apple/libcactus-simulator.a` |
| **iOS XCFramework** | `cactus/apple/cactus-ios.xcframework` |
| **macOS XCFramework** | `cactus/apple/cactus-macos.xcframework` |

Warnings during build are all deployment-target availability warnings (iOS 13.0 vs 16.0 APIs) -- harmless since TacNet targets iOS 16.0+.

### Cactus Source Repo
- **Path:** `/Users/yifuzuo/Desktop/yifu/startup/projects/hackathon/cactus/`
- **Branch:** `main` (commit `1e1a300` -- "Made non-thinking default for gemma4 & simultaneous multimodality")
- **Apple SDK files:** `cactus/apple/` contains `build.sh`, `Cactus.swift`, `module.modulemap`
- **Swift bindings:** `cactus/apple/Cactus.swift` -- the Swift wrapper for the C FFI

### iOS Integration
- SDK: `cactus-apple` XCFramework with NPU support
- Swift API: `CactusModel.load()` -> `model.generate(prompt:)`
- Weights bundled in app or downloaded on first launch
- Docs: https://docs.cactuscompute.com/v1.12/
- GitHub: https://github.com/cactus-compute/cactus (v1.13, /apple directory)

### Key Cactus Commands
```bash
cactus run <model>              # Interactive chat playground
cactus transcribe               # Live mic transcription
cactus download <model>         # Download model weights
cactus build --apple            # Build static lib for iOS/macOS
cactus build --android          # Build for Android
cactus test --ios               # Run tests on connected iPhone
```

---

## 3. Architecture Decision: Model Selection

Per Gemini analysis and Cactus docs:
- **Leaf nodes (squad members):** Gemma 4 E2B (2.3B params, ~1.4 GB VRAM, faster)
- **Intermediate/root nodes (squad leads, commander):** Gemma 4 E4B (4.5B params, ~2.8 GB VRAM, better summarization)
- Both E2B and E4B have **native audio input** (no separate STT needed)
- 26B and 31B models do NOT have audio and do NOT fit on iPhone

---

## 4. Performance Benchmarks (from Cactus docs)

| Metric (Apple Silicon) | E2B |
|---|---|
| 4096-token prefill | 660 tok/s |
| 1024-token decode | 40 tok/s |
| 30s audio end-to-end | 0.3s |
| Image encode (ANE) | 0.7s |
