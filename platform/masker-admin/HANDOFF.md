# Ona — Handoff Note

## Status

### What works
- Full trace/debug UI running at `platform/masker-admin/` (Vite + React + TypeScript)
- Three scripted demo scenarios load instantly — no live audio required:
  - **Scenario A** (Personal Info) → `masked-send` — name, address, SSN masked
  - **Scenario B** (Healthcare PHI) → `local-only` — health context + insurance ID + provider name kept on device
  - **Scenario C** (Safe Query) → `safe-to-send` — no entities, forwarded as-is
- Each scenario shows: transcript → detected entities (with risk level + masked value) → policy applied → route decision → masked transcript (when applicable) → plain-English explanation → step-by-step trace log
- Route badges are colour-coded: red = local-only, amber = masked-send, green = safe-to-send
- Zero TypeScript errors, dev server confirmed healthy

### What is blocked
- Nothing blocking demo. Live audio integration is Cursor's responsibility.

### What changed
- Created the `platform/masker-admin/` React app
- `src/types.ts` — shared type contracts (`MaskerTrace`, `DetectedEntity`, `TraceEvent`, `Route`, `Policy`, `EntityType`)
- `src/scenarios.ts` — three scripted demo scenarios matching the backlog spec
- `src/explanation.ts` — label/colour/description maps for routes, policies, entities, risk levels
- `src/components/TracePanel.tsx` — main demo surface
- `src/components/EntityList.tsx` — entity rows with risk colour + masked value
- `src/components/TraceLog.tsx` — step-by-step trace with stage labels
- `src/components/RouteBadge.tsx` — colour-coded route pill

### What the next agent (Cursor / Orchestrator) needs

1. **Live trace injection** — replace the static `SCENARIOS` array with real output from the Masker detection + policy engine. The UI expects a `MaskerTrace` object (see `src/types.ts`). Drop it into `src/scenarios.ts` or pass it as a prop to `<TracePanel>`.

2. **Contract** — detection output must match:
   ```ts
   interface MaskerTrace {
     id: string;
     label: string;
     transcript: string;
     entities: DetectedEntity[];   // { type, value, masked }
     policy: Policy;               // 'hipaa_base' | 'hipaa_clinical' | 'hipaa_logging' | 'none'
     route: Route;                 // 'local-only' | 'masked-send' | 'safe-to-send'
     maskedTranscript: string | null;
     explanation: string;
     traceEvents: TraceEvent[];    // { stage: 'detection'|'policy'|'masking'|'routing', message }
   }
   ```

3. **Run the UI** — `cd platform/masker-admin && npm install && npm run dev`
