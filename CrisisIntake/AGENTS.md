# Crisis Intake — Agent Responsibilities

## Overview
The app is split into 5 sections, each built by one agent. All agents share:
- The Zustand store (`src/store/useAppStore.ts`) — the single source of truth
- Shared types (`src/types/*.ts`) — never duplicate, always import
- Theme constants (`src/theme/index.ts`) — never hardcode colors/spacing

Read `CLAUDE.md` before writing any code.

---

## Agent 1: Audio Pipeline

**Owns:** `src/hooks/useAudioPipeline.ts`, `src/components/audio/`

**Builds:**
- `useAudioPipeline` hook — mic capture, ring buffer, VAD, STT, audio flush
- `RecordingIndicator` component — red dot + waveform when listening
- `TranscriptReviewSheet` component — bottom sheet for transcript review/edit

**Interface contract:**
```typescript
useAudioPipeline(): {
  isListening: boolean;
  speechSeconds: number;
  silenceSeconds: number;
  startListening: () => Promise<void>;
  stopListening: () => void;
  onTranscriptReady: (callback: (transcript: string) => void) => void;
}
```

**Store writes:** `pipelinePhase`, `speechSeconds`, `silenceSeconds`, `currentTranscript`
**Store reads:** `modelsLoaded`

**Critical rules:**
- Audio buffer is in-memory ONLY. Never `fs.writeFile` for audio.
- Flush buffer immediately after STT completes.
- Never run STT while LLM is running. Check `pipelinePhase` before starting STT.
- VAD trigger: `silence >= 2s && speech >= 3s` OR `speech >= 20s`.

---

## Agent 2: Extraction Engine

**Owns:** `src/services/extraction.ts`, `src/services/toolSchema.ts`, `src/services/prompts.ts`, `src/services/parseToolCall.ts`

**Builds:**
- `ExtractionEngine` class — Gemma 4 model lifecycle, tool calling, parsing
- Tool schema definition for `update_intake_fields`
- System prompts (voice + vision)
- JSON fallback parser

**Interface contract:**
```typescript
class ExtractionEngine {
  downloadModels(onProgress: (model: string, progress: number) => void): Promise<void>;
  loadModels(): Promise<void>;
  isReady(): boolean;
  destroy(): Promise<void>;
  extractFromTranscript(transcript: string, currentFields: IntakeSchema): Promise<Partial<Record<keyof IntakeSchema, any>> | null>;
  extractFromImage(imagePath: string, currentFields: IntakeSchema): Promise<Partial<Record<keyof IntakeSchema, any>> | null>;
}
```

**Store writes:** NONE (returns deltas; orchestrator merges)
**Store reads:** NONE (receives current fields as parameter)

**Critical rules:**
- System prompt must be under 120 tokens.
- Tool schema is FLAT — no nested objects. 20 properties, all optional.
- If `functionCalls` is empty, try `JSON.parse(result.response)` as fallback.
- If both fail, return `null`. Never throw — the cycle just gets skipped.
- Include `transcript_summary` in tool schema for UI display.

---

## Agent 3: UI & Form

**Owns:** `src/components/form/`, screen layout in `src/screens/IntakeSessionScreen.tsx`

**Builds:**
- `IntakeForm` — scrollable form grouped by section
- `SectionHeader` — section title with completion count
- `FormField` — single field with grey/amber/green states
- `CompletionBar` — bottom bar with progress + action buttons
- `FieldEditor` — inline editor for confirmed fields

**Interface contract:** React components only. No hooks, no services.

**Props for IntakeSessionScreen composition:**
- `IntakeForm` — reads `intake` from store
- `CompletionBar` — receives `onGeneratePlan` callback prop
- `FormField` — receives `fieldMeta: FieldMeta` and reads field state from store

**Store writes:** `confirmField`, `confirmAllFields`, `editField`, `unlockField`
**Store reads:** `intake`, `pipelinePhase`, `transcriptLog`

**Critical rules:**
- ALL visual styling uses theme tokens. No hardcoded hex values.
- Field state colors: `theme.colors.fieldEmpty`, `theme.colors.fieldInferred`, `theme.colors.fieldConfirmed`.
- Modern iOS design: 12-16px radii, subtle shadows, generous spacing.
- Amber fields have a subtle pulse animation (opacity 0.8 <-> 1.0, 2s loop).
- Tap inferred -> confirm (green). Tap confirmed -> unlock + show editor (amber).
- "Confirm All" sets all inferred -> confirmed. "Generate Plan" is disabled until >= 60% fields non-empty.

---

## Agent 4: Document Scanner

**Owns:** `src/components/scanner/`, `src/screens/DocumentScanScreen.tsx`

**Builds:**
- `DocumentScanScreen` — camera view, capture, preview, accept/retake
- `CaptureButton` — large circular camera button
- `ExtractionPreview` — shows extracted fields as chips before accepting

**Interface contract:**
- Navigated to via `navigation.navigate("DocumentScan")`
- Calls `ExtractionEngine.extractFromImage()` (Agent 2's class)
- On accept: calls `store.mergeFields(delta, "vision")` then navigates back
- On cancel/retake: deletes image, stays on screen or navigates back

**Store writes:** `mergeFields` (via accept), `pipelinePhase` (set to "scanning")
**Store reads:** `intake` (passes to extraction engine)

**Critical rules:**
- Image saved to temp directory ONLY. `fs.unlink()` immediately after extraction or cancel.
- NO image caching, thumbnails, or photo library access.
- Disabled during active audio pipeline (check `pipelinePhase !== "listening"`).

---

## Agent 5: Cloud & Sanitization

**Owns:** `src/services/sanitization.ts`, `src/services/gemini.ts`, `src/screens/ResourcePlanScreen.tsx`, `src/components/cloud/`

**Builds:**
- `sanitizeIntake()` function — strips PII, buckets income
- `generateResourcePlan()` function — Gemini API call
- `ResourcePlanScreen` — displays risk score, timeline, program matches
- `RiskScoreBadge`, `TimelineView`, `ProgramMatchCard` components

**Interface contract:**
```typescript
sanitizeIntake(intake: IntakeSchema): SanitizedPayload;
generateResourcePlan(sanitized: SanitizedPayload, apiKey: string): Promise<CloudAnalysis>;
```

**Store writes:** `cloudStatus`, `cloudResult`
**Store reads:** `intake`, `cloudStatus`, `cloudResult`

**Sanitization rules (MUST follow exactly):**
| Field | Action |
|---|---|
| client_first_name, client_last_name | REDACT (do not include) |
| date_of_birth | Keep year only |
| phone_number | REDACT |
| current_address | REDACT |
| income_amount | Bucket into $500 ranges (e.g., "$1,000-$1,500") |
| All other fields | Keep as-is |

**Critical rules:**
- `sanitizeIntake()` is the ONLY function that prepares data for external APIs.
- If offline, set `cloudStatus` to `"queued"` and save payload to AsyncStorage.
- Gemini prompt must request structured JSON output matching `CloudAnalysis` type.
- Parse Gemini response with try/catch. On failure, show raw text.

---

## Integration Points

All agents connect through 3 shared layers:

1. **Zustand store** — every agent reads/writes state here
2. **Shared types** — `src/types/intake.ts` is the schema contract
3. **Theme** — `src/theme/index.ts` is the visual contract

The orchestrator in `IntakeSessionScreen.tsx` wires:
- Agent 1's `useAudioPipeline` hook
- Agent 2's `ExtractionEngine` class
- Agent 3's form components
- Agent 5's `sanitizeIntake` + `generateResourcePlan`

Agent 4's `DocumentScanScreen` is a separate navigation route that calls Agent 2's extraction engine directly.
