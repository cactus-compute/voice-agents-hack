# Crisis Intake — Project Standards

## What This Is
A React Native iOS app for voice-driven housing intake. Field workers have a natural conversation with displaced individuals; the app extracts structured data on-device via Gemma 4 on Cactus.

## Tech Stack
- React Native (TypeScript), iOS only (iPhone 15 Pro+)
- Cactus React Native SDK (`cactus-react-native` + `react-native-nitro-modules`)
- Zustand for state management
- React Navigation (stack navigator)
- Gemini 2.5 Flash REST API (cloud, optional)

## Architecture Rules
1. **Single Zustand store** — all state lives in `src/store/useAppStore.ts`. No local component state for shared data. Import `useAppStore` and use selectors.
2. **STT and LLM never run simultaneously** — they share device compute. Enforce sequential execution. Pipeline phases: idle -> listening -> transcribing -> reviewing -> extracting -> listening.
3. **Audio never persists to disk** — ring buffer is in-memory only. Flushed after every STT pass. No `fs.writeFile` for audio. No temp audio files.
4. **Images are ephemeral** — temp file only during vision processing. `fs.unlink()` immediately after extraction or cancel.
5. **Confirmed fields are sacred** — LLM extraction NEVER overwrites a field with status `"confirmed"`. Only human action can unlock it.
6. **Sanitization is the only path to cloud** — `sanitizeIntake()` is the ONLY function that prepares data for Gemini. No other code sends data externally.

## Coding Standards
- TypeScript strict mode. No `any` except in delta merge (extraction output is dynamic).
- All components use the theme from `src/theme/index.ts`. No hardcoded colors, spacing, or font sizes.
- Use `theme.colors.fieldEmpty`, `theme.colors.fieldInferred`, `theme.colors.fieldConfirmed` for field states. Never raw hex values.
- Components go in `src/components/<section>/`. Screens go in `src/screens/`.
- Services (non-React, pure logic) go in `src/services/`. Hooks go in `src/hooks/`.
- Shared types go in `src/types/`. Do NOT duplicate type definitions — import from there.
- Modern iOS design: cards with 12-16px radii, subtle shadows, SF Pro system font, generous spacing, smooth animations.

## Store Convention
- Read state with selectors: `const phase = useAppStore(s => s.pipelinePhase)`
- Call actions directly: `useAppStore.getState().confirmField("client_first_name")`
- Never destructure the entire store. Use granular selectors to prevent unnecessary re-renders.

## File Ownership
- `src/hooks/useAudioPipeline.ts`, `src/components/audio/` — Agent 1 (Audio Pipeline)
- `src/services/extraction.ts`, `src/services/toolSchema.ts`, `src/services/prompts.ts`, `src/services/parseToolCall.ts` — Agent 2 (Extraction Engine)
- `src/components/form/`, `src/screens/IntakeSessionScreen.tsx` — Agent 3 (UI & Form)
- `src/components/scanner/`, `src/screens/DocumentScanScreen.tsx` — Agent 4 (Document Scanner)
- `src/services/sanitization.ts`, `src/services/gemini.ts`, `src/screens/ResourcePlanScreen.tsx`, `src/components/cloud/` — Agent 5 (Cloud & Sanitization)

## Do NOT
- Add analytics, telemetry, or crash reporting
- Write audio to disk for any reason
- Send unsanitized data to any external service
- Use Context API or Redux — Zustand only
- Create new type files — use existing ones in `src/types/`
- Hardcode colors or spacing — use theme
- Add features not in the design spec
