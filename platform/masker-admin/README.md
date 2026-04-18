# `Masker-Admin` — Trace UI

`Masker-Admin` is the hackathon demo UI for showing what Masker detected, what
policy fired, which route was chosen, and why.

It is a React + TypeScript + Vite app that renders scripted scenarios today
and can be swapped to live `MaskerTrace` data as soon as the integration path
is ready.

## Run

```bash
cd platform/masker-admin
npm install
npm run dev
```

## What it shows

- transcript
- detected entities
- applied policy
- chosen route
- masked transcript
- explanation copy
- stage-by-stage trace events

## Integration contract

The UI expects a `MaskerTrace`-shaped object defined in
`platform/masker-admin/src/types.ts`. Cursor or the orchestrator can replace
the scripted scenarios with live output without changing the visual shell.
