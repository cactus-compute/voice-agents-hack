#!/bin/bash
set -e

# Resolve repo root dynamically (this script is invoked from the repo root by the mission runner)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Verify Xcode is available
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: xcodebuild not found. Ensure Xcode is installed."
    exit 1
fi

# Verify Xcode developer tools are pointing to Xcode.app (not CommandLineTools)
XCODE_PATH=$(xcode-select -p)
if [[ "$XCODE_PATH" != *"Xcode.app"* ]]; then
    echo "WARNING: xcode-select points to $XCODE_PATH, not Xcode.app"
    echo "Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# Verify Cactus XCFramework is present inside the repo
CACTUS_XCFRAMEWORK="$REPO_ROOT/Frameworks/cactus-ios.xcframework"
if [ ! -d "$CACTUS_XCFRAMEWORK" ]; then
    echo "WARNING: Cactus XCFramework not found at $CACTUS_XCFRAMEWORK"
    echo "This project requires the XCFramework to be vendored under Frameworks/."
fi

# Verify iPhone 17 simulator runtime is available
if ! xcrun simctl list devices available 2>/dev/null | grep -q 'iPhone 17'; then
    echo "WARNING: iPhone 17 simulator not found in available devices."
    echo "List available devices with: xcrun simctl list devices available"
fi

echo "Init complete. Repo root: $REPO_ROOT"
