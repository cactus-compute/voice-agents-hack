# Upstream pin

Vendored from: https://github.com/cactus-compute/llm-in-chrome (or local copy at /Users/apple/Dev/llm-in-chrome)
Commit SHA: 401364575626c4daa5db3eefbe565374cfecd130
Vendored on: 2026-04-18T22:59:12Z

## Files we modified after copy

- `server/src/llm/client.ts` — replaced multi-provider routing with single Cactus branch
- `server/src/llm/cactus.ts` — NEW; Cactus provider
- `server/src/index.ts` — stripped imports for deleted modules (managed, license, telemetry, credentials)

## Files we deleted from the copy

- `server/src/managed/` (entire dir)
- `server/src/license/` (entire dir)
- `server/src/native-host/` (entire dir)
- `server/src/cli/{managed-client,setup,doctor,detect-credentials}.ts` and detect-credentials.test.ts
- `server/src/relay/api-proxy.ts`
- `server/src/telemetry.ts`
- `server/src/llm/{vertex,credentials}.ts`

## Re-sync

To rebase on a newer upstream, repeat the `cp` commands in
`docs/superpowers/plans/2026-04-18-cactus-browse-swap.md` Task 1 then re-apply
the modifications listed above.
