# Aurora

A quiet place to think out loud.

Aurora is an on-device AI listening companion. You hold a circle, speak, and a thoughtful voice reflects back what it heard — entirely on your phone. No audio leaves the device.

Built with [Cactus](https://github.com/cactus-compute/cactus), Google's [FunctionGemma 270M](https://huggingface.co/google/functiongemma-270m-it) (a 270M-parameter Gemma 3 variant tuned for tool use and quick on-device chat), Expo, and React Native.

> Aurora is **not** a doctor, therapist, or crisis service. It's a calm presence to think alongside. If you're in crisis, call 988 (US) or your local emergency number.

---

## How it works

```
mic → on-device STT (iOS Speech / Android SpeechRecognizer)
    → FunctionGemma 270M via Cactus → expo-speech → speaker
```

Three on-device steps, no network. The native recognizer transcribes the user's voice locally, the transcript is fed to FunctionGemma through `cactus.complete`, and the streamed reply is spoken back with the system TTS voice.

| Stage      | Component                                              |
| ---------- | ------------------------------------------------------ |
| Listening  | `expo-speech-recognition` (on-device system recognizer) |
| Inference  | `cactus-react-native` running `functiongemma-270m-it`  |
| Speech out | `expo-speech` (system TTS, no download)                |
| Safety     | Local regex crisis detector + system-prompt rules      |

Architecture, design, and implementation followed the GSTACK fast-path workflow — context → architecture lock → design → scaffold → polish.

## Project layout

```
aurora/
├── App.tsx                     # stage machine: onboarding → disclaimer → conversation
├── app.json                    # expo + native permissions (mic on iOS/Android)
├── src/
│   ├── theme/                  # aurora palette, typography, spacing
│   ├── constants/
│   │   ├── systemPrompt.ts     # the entire personality of Aurora, hand-tuned
│   │   └── safety.ts           # crisis detector + resource copy
│   ├── state/
│   │   ├── types.ts            # SessionPhase, Message, ConversationState
│   │   └── conversationReducer.ts
│   ├── hooks/
│   │   ├── useSpeechInput.ts   # on-device speech recognition (iOS/Android)
│   │   ├── useTTS.ts           # expo-speech wrapper
│   │   └── useTherapist.ts     # the orchestrator: cactus + speech + tts + safety
│   ├── components/
│   │   ├── AuroraBackground.tsx
│   │   ├── BreathingOrb.tsx    # the centerpiece — reflects every state
│   │   ├── MicButton.tsx       # hold-to-talk with haptics
│   │   ├── TranscriptCard.tsx  # last exchange only (voice-first)
│   │   ├── Header.tsx
│   │   ├── DownloadProgress.tsx
│   │   └── DisclaimerModal.tsx # onboarding + crisis variants
│   └── screens/
│       ├── OnboardingScreen.tsx
│       └── ConversationScreen.tsx
```

## Getting started

```bash
cd aurora
npm install                       # 655 packages, expo SDK 55 + cactus 1.13
CI=1 npx expo prebuild --clean    # generates ios/ and android/ for cactus + nitro
# iOS — needs CocoaPods (brew install cocoapods if missing)
cd ios && pod install && cd ..
npm run ios                       # device or simulator
# Android
npm run android
```

A clean install + prebuild is verified working on macOS — `expo-doctor` reports 15/17 checks passing (the two failing checks are local CocoaPods presence and an informational warning about prebuilt folders, both expected).

The first launch downloads `google/functiongemma-270m-it` (~200 MB quantized) over Cactus's `useCactusLM` hook. Aurora shows a progress bar while this happens, then unlocks the conversation surface. The model is already present in `cactus/weights/` if you ran `cactus download google/functiongemma-270m-it --reconvert` from the repo root.

### Why Expo bare workflow?

Cactus needs `react-native-nitro-modules`, which is a native module. Bare RN works too, but Expo's `prebuild` gets us iOS/Android scaffolding for free, plus first-class speech recognition (`expo-speech-recognition`), TTS (`expo-speech`), haptics, keep-awake, and gradients without yak-shaving.

## Design language

A late-twilight palette: deep indigo base, an aurora that drifts through teal → violet → rose, soft white type. The breathing orb is the protagonist — it inhales when idle, opens and pulses with your voice when listening, slow-spins while thinking, and glows warmly while speaking. Inspirations: Calm, Headspace, Apollo Neuro.

Everything is voice-first. There is no chat scrollback. The transcript card shows only the last exchange because reading is a different mode than listening, and we want users in listening mode.

## Safety

Three layers:

1. **System prompt** (`src/constants/systemPrompt.ts`) — Aurora is told, in plain language, never to diagnose, prescribe, or chase a fix. Replies stay 1–3 sentences. One question per turn at most. No lists, no jargon, no emojis (this is read aloud).
2. **Local crisis detector** (`src/constants/safety.ts`) — a regex pass on every user transcript and assistant reply. If matched, the app surfaces a non-blocking modal with the 988 lifeline, Crisis Text Line, and the international IASP directory.
3. **Onboarding disclaimer** — first-launch modal makes the limitation explicit before any conversation starts.

## Demo notes

This is a hackathon scope: no auth, no persistence, no settings drawer. Sessions live in memory only. Closing the app wipes the conversation — which is intentional for the privacy story but also the simplest thing that demos well.

Two things to highlight when showing it:

- **Hold the orb, speak, release.** Watch the breathing orb shift colors through listening → thinking → speaking. The audio never leaves the device.
- **Open `src/constants/systemPrompt.ts`.** The entire personality is one prompt. Tweaking it changes Aurora's voice in real time.

## License

MIT.
