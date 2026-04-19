import { useEffect, useMemo, useState } from "react";

type OverlayState =
  | "prompt_ready"
  | "recording"
  | "transcribing"
  | "transcript"
  | "intent"
  | "action"
  | "done"
  | "error"
  | "hidden"
  | "system";

type OverlayEvent = {
  state: OverlayState;
  text: string;
};

type BubbleKind = "user" | "assistant" | "status" | "error";

type Bubble = {
  text: string;
  kind: BubbleKind;
};

const MAX_BUBBLES = 6;

function bubbleFromEvent(evt: OverlayEvent): Bubble | null {
  if (evt.state === "hidden") return null;
  if (evt.state === "prompt_ready")
    return { text: "Speak after the tone…", kind: "status" };
  if (evt.state === "transcript") return { text: evt.text, kind: "user" };
  if (evt.state === "action" || evt.state === "done") return { text: evt.text, kind: "assistant" };
  if (evt.state === "error") return { text: evt.text || "Error", kind: "error" };
  if (evt.state === "transcribing" || evt.state === "intent") return { text: evt.text, kind: "status" };
  if (evt.state === "system") return { text: evt.text, kind: "status" };
  return null;
}

function App() {
  const [connected, setConnected] = useState(false);
  const [state, setState] = useState<OverlayState>("recording");
  const [bubbles, setBubbles] = useState<Bubble[]>([
    { text: "Hold Right Shift to record", kind: "status" }
  ]);

  useEffect(() => {
    let ws: WebSocket | null = null;
    let timer: number | null = null;

    const connect = () => {
      ws = new WebSocket("ws://127.0.0.1:8765");

      ws.onopen = () => {
        setConnected(true);
      };

      ws.onclose = () => {
        setConnected(false);
        timer = window.setTimeout(connect, 1200);
      };

      ws.onmessage = (msg) => {
        try {
          const evt = JSON.parse(msg.data) as OverlayEvent;
          setState(evt.state);

          if (evt.state === "hidden") {
            setBubbles([]);
            return;
          }

          const bubble = bubbleFromEvent(evt);
          if (!bubble) return;

          setBubbles((prev) => [...prev, bubble].slice(-MAX_BUBBLES));
        } catch {
          // Ignore malformed payloads.
        }
      };
    };

    connect();
    return () => {
      if (timer) window.clearTimeout(timer);
      ws?.close();
    };
  }, []);

  const statusChip = useMemo(() => {
    if (!connected) return "Offline";
    if (state === "prompt_ready") return "Get ready";
    if (state === "recording") return "Listening";
    if (state === "transcribing") return "Thinking";
    if (state === "error") return "Error";
    return "Live";
  }, [connected, state]);

  return (
    <div className="viewport">
      <section className="shell">
        <button className="close-btn" aria-label="Close">
          ×
        </button>

        <header className="header">
          <h1>Ask ali / Collapse ⌘ O</h1>
          <div className="subtitle-row">
            <h2>Push to talk</h2>
            <span className="chip">{statusChip}</span>
          </div>
        </header>

        <main className="panel">
          <div className="panel-top">
            <span className="panel-title">ali says</span>
            <span className="esc">esc</span>
          </div>

          <div className="bubbles">
            {bubbles.length === 0 ? (
              <div className="bubble status">Ready for voice input...</div>
            ) : (
              bubbles.map((b, i) => (
                <div key={`${b.kind}-${i}-${b.text.slice(0, 10)}`} className={`bubble ${b.kind}`}>
                  {b.text}
                </div>
              ))
            )}
          </div>

          <footer className="composer">
            <input readOnly value="Ask follow up..." />
            <button className="send-btn" aria-label="Send">
              ↑
            </button>
          </footer>
        </main>
      </section>
    </div>
  );
}

export default App;
