# Platform Layout

Masker is organized into three component roots:

```text
platform/
  masker-core/      # Rust runtime and CLI
  masker-admin/     # React/Vite trace UI
  masker-library/   # Python SDK, integration package, tests, and env samples
```

Each component keeps its own README and run instructions so the hackathon team
can work in parallel without mixing runtime, UI, and integration concerns.
