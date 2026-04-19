# Environment

## Development Machine

- macOS (darwin 25.4.0), Apple Silicon
- Xcode 26.4 at `/Applications/Xcode.app`
- Swift 5.9+
- `xcode-select -p` should point to Xcode.app (not CommandLineTools)

## Repo Root

This project's canonical path is the current git repo root (resolved dynamically by `.factory/init.sh`). Do NOT hardcode absolute user paths in any script or config — use relative paths or resolve from `$(git rev-parse --show-toplevel)`.

## Cactus SDK

- XCFramework (vendored): `Frameworks/cactus-ios.xcframework` — binary artifact. Do NOT modify.
- Swift API reference: `.factory/library/cactus-api.md`
- Real model weights (dev-only, not required for Simulator mission): installed via Homebrew at `/opt/homebrew/opt/cactus/libexec/weights/gemma-4-e4b-it/` (6.7GB INT4). Tests use mocks; the Simulator does not need real weights.

## Test Devices

- **For this mission:** iPhone 17 Simulator on iOS 26.4 (or latest available). Single device only.
- **Future (out of scope):** 4+ physical iPhones with iOS 16+ for BLE mesh, real Cactus inference, real mic, and multi-phone flows. See `MANUAL_TESTING.md`.

## Simulator Lifecycle Commands

```bash
xcrun simctl boot 'iPhone 17'
xcrun simctl install 'iPhone 17' <path-to-TacNet.app>
xcrun simctl launch 'iPhone 17' com.tacnet.app
xcrun simctl io booted screenshot /tmp/step.png
xcrun simctl terminate 'iPhone 17' com.tacnet.app
xcrun simctl shutdown 'iPhone 17'
```

## Git

- Remote: https://github.com/Nalin-Atmakur/YC-hack (main branch)
- **Do NOT push** unless the orchestrator explicitly instructs. Commit locally only.
