# CrisisIntake

Voice-driven housing intake app. Field workers have a natural conversation with displaced individuals; the app extracts structured data on-device via Gemma 4 on Cactus.

## Prerequisites

Before cloning, make sure you have these installed:

1. **Node.js >= 22** — check with `node -v`
   - Install via [nvm](https://github.com/nvm-sh/nvm): `nvm install 22 && nvm use 22`
   - Or download from [nodejs.org](https://nodejs.org/)

2. **Ruby >= 2.6.10** — check with `ruby -v`
   - macOS ships with Ruby, but if yours is too old: `brew install ruby`

3. **Xcode** (full app, not just Command Line Tools)
   - Install from the Mac App Store
   - After install, set the developer directory:
     ```sh
     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
     ```
   - Open Xcode once and accept the license agreement
   - Install an iOS Simulator: Xcode > Settings > Platforms > iOS

4. **Watchman** (optional but recommended for Fast Refresh)
   ```sh
   brew install watchman
   ```

## Setup (run these in order)

```sh
# 1. Clone the repo and cd into the app
git clone <repo-url>
cd voice-agents-hack/CrisisIntake

# 2. Install JS dependencies
npm install

# 3. Install Ruby bundler (if you don't have it)
gem install bundler

# 4. Install CocoaPods via bundler
bundle install

# 5. Install iOS native pods
cd ios && bundle exec pod install && cd ..

# 6. Start Metro bundler (keep this terminal open)
npm start

# 7. In a NEW terminal, build and run on iOS simulator
npx react-native run-ios
```

If `run-ios` can't find a simulator, list available ones and pick one:
```sh
xcrun simctl list devices available | grep iPhone
npx react-native run-ios --simulator="iPhone 16"
```

## Troubleshooting

**`xcode-select: error: tool 'xcodebuild' requires Xcode`**
You have Command Line Tools but not full Xcode. Install Xcode from the App Store, then run:
```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**`RNGestureHandlerModule could not be found`**
Native pods aren't linked. Re-run:
```sh
cd ios && bundle exec pod install && cd ..
```
Then rebuild: `npx react-native run-ios`

**`No simulator available with name "iPhone 15 Pro"`**
Your Xcode has different simulators. Run `xcrun simctl list devices available | grep iPhone` and use an available name.

**`bundle install` fails with permission errors**
Try: `sudo gem install bundler` then `bundle install` again.

**Metro bundler port in use**
Kill the old process: `lsof -ti:8081 | xargs kill -9` then `npm start` again.

## Project Structure

```
src/
├── types/          # Shared TypeScript types (intake, transcript, cloud, sanitized)
├── store/          # Zustand store (useAppStore.ts)
├── theme/          # Design tokens (colors, spacing, typography)
├── utils/          # Utility functions (createEmptyIntake, mergeFields)
├── screens/        # Screen components (IntakeSession, DocumentScan, ResourcePlan)
├── components/
│   ├── audio/      # Agent 1 — Audio pipeline components
│   ├── form/       # Agent 3 — Intake form components
│   ├── scanner/    # Agent 4 — Document scanner components
│   └── cloud/      # Agent 5 — Cloud/resource plan components
├── services/       # Agent 2 & 5 — Extraction, sanitization, Gemini
└── hooks/          # Agent 1 — useAudioPipeline
```

## Agent Development

Each agent works on a separate branch from `skeleton-complete`:

```sh
git checkout skeleton-complete
git checkout -b agent-N/your-section
```

See `AGENTS.md` for your file ownership and interface contracts.
See `CLAUDE.md` for project-wide coding standards.
See `docs/plans/2026-04-18-crisis-intake-implementation.md` for your task list.
