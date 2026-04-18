# Ali Tauri + React UI

This app is the modern desktop UI shell for the Python voice agent backend.

## Run dev UI

```bash
npm install
npm run tauri dev
```

The frontend listens for agent state over:

- `ws://127.0.0.1:8765`

## Backend

Run the Python backend in a separate terminal:

```bash
cd ..
python3 main.py
```

By default, `main.py` uses the WebSocket bridge (`ALI_UI_BACKEND=web`).
