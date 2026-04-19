"use client";

import { useState, useRef, useEffect, useCallback } from "react";
import { Send, CheckCircle, FlaskConical, BookOpen, AlertCircle, Check } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { StatusChip } from "@/components/ui/StatusChip";
import { cn } from "@/lib/utils";

interface GeminiMessage {
  role: "user" | "model";
  parts: { text: string }[];
}

interface DisplayMessage {
  role: "user" | "assistant";
  content: string;
}

interface PolicyConfig {
  useCaseName: string;
  frameworks: string[];
  entityClasses: { entity: string; action: string; rehydration: boolean }[];
  retentionWindow: string;
  loggingMode: string;
  auditArtifacts: string[];
  scope: string;
  status: "draft" | "ready";
}

const QUICK_PROMPTS = [
  "I'm building a healthcare voice agent for appointment booking.",
  "Mask HIPAA identifiers, keep ZIP at first-3, redact SSNs fully.",
  "Store reversible tokens for patient IDs using managed keys.",
  "Apply to voice sessions only in production.",
];

const INITIAL_CONFIG: PolicyConfig = {
  useCaseName: "—",
  frameworks: [],
  entityClasses: [],
  retentionWindow: "—",
  loggingMode: "—",
  auditArtifacts: [],
  scope: "—",
  status: "draft",
};

const ACTION_COLORS: Record<string, string> = {
  mask:                 "bg-blue-50 text-blue-700 border-blue-200",
  redact:               "bg-red-50 text-red-700 border-red-200",
  tokenize:             "bg-purple-50 text-purple-700 border-purple-200",
  allow:                "bg-emerald-50 text-emerald-700 border-emerald-200",
  "truncate (first-3)": "bg-amber-50 text-amber-700 border-amber-200",
  block:                "bg-red-50 text-red-700 border-red-200",
};

export function CopilotClient() {
  const [display, setDisplay] = useState<DisplayMessage[]>([
    {
      role: "assistant",
      content:
        "Hi — I'm the Masker Compliance Copilot, powered by Gemini. Tell me what you're building and I'll propose a compliance configuration. For example: \"I'm building a healthcare voice agent for appointment booking.\"",
    },
  ]);
  const [history, setHistory] = useState<GeminiMessage[]>([]);
  const [input, setInput] = useState("");
  const [config, setConfig] = useState<PolicyConfig>(INITIAL_CONFIG);
  const [typing, setTyping] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [published, setPublished] = useState(false);
  const bottomRef = useRef<HTMLDivElement>(null);
  const abortRef = useRef<AbortController | null>(null);

  function showToast(msg: string) {
    setToast(msg);
    setTimeout(() => setToast(null), 3000);
  }

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [display, typing]);

  const send = useCallback(async (text: string) => {
    if (!text.trim() || typing) return;
    setInput("");
    setError(null);

    setDisplay((d) => [...d, { role: "user", content: text }]);
    setTyping(true);

    // Cancel any in-flight request
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;

    // 30-second timeout
    const timeout = setTimeout(() => controller.abort(), 30_000);

    const newHistory: GeminiMessage[] = [
      ...history,
      { role: "user", parts: [{ text }] },
    ];

    try {
      const res = await fetch("/api/copilot", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages: newHistory }),
        signal: controller.signal,
      });

      const data = await res.json();
      if (!res.ok) throw new Error(data.error ?? "Request failed");

      const replyText: string = data.text;
      const replyConfig: Partial<PolicyConfig> | null = data.config;

      setDisplay((d) => [...d, { role: "assistant", content: replyText }]);
      setHistory([...newHistory, { role: "model", parts: [{ text: replyText }] }]);
      if (replyConfig) setConfig((c) => ({ ...c, ...replyConfig }));
    } catch (err: unknown) {
      if ((err as Error).name === "AbortError") return;
      const msg = err instanceof Error ? err.message : "Something went wrong";
      setError(msg);
      setDisplay((d) => [...d, { role: "assistant", content: `Sorry, I ran into an error: ${msg}` }]);
    } finally {
      clearTimeout(timeout);
      setTyping(false);
    }
  }, [history, typing]);

  return (
    <div className="flex gap-4 h-[calc(100vh-200px)] min-h-[500px]">
      {/* Chat */}
      <div className="flex flex-col flex-1 rounded-lg border border-[#e5e7eb] bg-white overflow-hidden">
        <div className="flex-1 overflow-y-auto p-5 flex flex-col gap-4">
          {display.map((m, i) => (
            <div key={`${m.role}-${i}`} className={cn("flex", m.role === "user" ? "justify-end" : "justify-start")}>
              {m.role === "assistant" && (
                <div className="w-6 h-6 rounded-full bg-[#0d0f12] flex items-center justify-center text-white text-[10px] font-bold mr-2 mt-0.5 shrink-0">M</div>
              )}
              <div className={cn(
                "max-w-[80%] rounded-lg px-4 py-2.5 text-[13px] leading-relaxed whitespace-pre-wrap",
                m.role === "user"
                  ? "bg-[#0d0f12] text-white rounded-br-sm"
                  : "bg-[#f9fafb] text-[#0d0f12] border border-[#e5e7eb] rounded-bl-sm"
              )}>
                {m.content}
              </div>
            </div>
          ))}

          {typing && (
            <div className="flex items-center gap-2">
              <div className="w-6 h-6 rounded-full bg-[#0d0f12] flex items-center justify-center text-white text-[10px] font-bold shrink-0">M</div>
              <div className="bg-[#f9fafb] border border-[#e5e7eb] rounded-lg px-4 py-2.5 flex gap-1 items-center">
                {["dot-0", "dot-1", "dot-2"].map((key, i) => (
                  <span key={key} className="w-1.5 h-1.5 rounded-full bg-[#9ca3af] animate-bounce" style={{ animationDelay: `${i * 0.15}s` }} />
                ))}
              </div>
            </div>
          )}

          {error && (
            <div className="flex items-center gap-2 text-[12px] text-red-600 bg-red-50 border border-red-200 rounded-lg px-3 py-2">
              <AlertCircle className="w-3.5 h-3.5 shrink-0" /> {error}
            </div>
          )}

          <div ref={bottomRef} />
        </div>

        {/* Quick prompts */}
        <div className="px-4 py-2 border-t border-[#f3f4f6] flex gap-2 flex-wrap">
          {QUICK_PROMPTS.map((p) => (
            <button key={p} onClick={() => send(p)} disabled={typing}
              className="text-[11px] px-2.5 py-1 rounded-full border border-[#e5e7eb] text-[#6b7280] hover:border-[#0d0f12] hover:text-[#0d0f12] transition-colors bg-white disabled:opacity-40">
              {p.length > 42 ? p.slice(0, 42) + "…" : p}
            </button>
          ))}
        </div>

        {/* Input */}
        <div className="flex items-center gap-2 px-4 py-3 border-t border-[#e5e7eb]">
          <input
            className="flex-1 text-[13px] outline-none placeholder:text-[#9ca3af] text-[#0d0f12]"
            placeholder="Describe your use case or compliance requirement…"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && !e.shiftKey && send(input)}
            disabled={typing}
          />
          <button onClick={() => send(input)} disabled={!input.trim() || typing}
            className="flex items-center justify-center w-8 h-8 rounded-md bg-[#0d0f12] text-white disabled:opacity-30 hover:bg-[#1f2937] transition-colors">
            <Send className="w-3.5 h-3.5" />
          </button>
        </div>
      </div>

      {/* Config preview */}
      <div className="w-[340px] shrink-0 flex flex-col gap-3 overflow-y-auto">
        <div className="rounded-lg border border-[#e5e7eb] bg-white p-5">
          <div className="flex items-center justify-between mb-4">
            <div className="text-[13px] font-semibold text-[#0d0f12]">Policy Preview</div>
            <StatusChip status={config.status} />
          </div>

          <div className="flex flex-col gap-4 text-[12px]">
            <Field label="Use Case" value={config.useCaseName} />

            <div>
              <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide mb-1.5">Frameworks</div>
              {config.frameworks.length === 0 ? <span className="text-[#d1d5db]">—</span> : (
                <div className="flex gap-1.5 flex-wrap">
                  {config.frameworks.map((f) => (
                    <span key={f} className="px-2 py-0.5 rounded border border-[#e5e7eb] text-[#374151] font-medium">{f}</span>
                  ))}
                </div>
              )}
            </div>

            <div>
              <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide mb-1.5">Entity Rules</div>
              {config.entityClasses.length === 0 ? <span className="text-[#d1d5db]">—</span> : (
                <div className="flex flex-col gap-1.5">
                  {config.entityClasses.map((e, i) => (
                    <div key={i} className="flex items-center justify-between">
                      <span className="text-[#374151] font-mono">{e.entity}</span>
                      <div className="flex items-center gap-1.5">
                        <span className={cn("px-1.5 py-0.5 rounded border text-[10px] font-medium", ACTION_COLORS[e.action] ?? "bg-gray-50 text-gray-600 border-gray-200")}>
                          {e.action}
                        </span>
                        {e.rehydration && <span className="text-[10px] text-purple-600 font-medium">reversible</span>}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            <Field label="Scope" value={config.scope} />
            <Field label="Retention" value={config.retentionWindow} />
            <Field label="Logging Mode" value={config.loggingMode} />

            <div>
              <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide mb-1.5">Audit Artifacts</div>
              {config.auditArtifacts.length === 0 ? <span className="text-[#d1d5db]">—</span> : (
                <ul className="flex flex-col gap-1">
                  {config.auditArtifacts.map((a) => (
                    <li key={a} className="flex items-center gap-1.5 text-[#374151]">
                      <CheckCircle className="w-3 h-3 text-emerald-500 shrink-0" /> {a}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </div>
        </div>

        <div className="flex flex-col gap-2">
          <Button
            variant="primary"
            className="w-full justify-center"
            disabled={config.status !== "ready" || published}
            onClick={() => {
              setPublished(true);
              showToast("Policy published successfully");
            }}
          >
            {published
              ? <><Check className="w-3.5 h-3.5" /> Published</>
              : <><CheckCircle className="w-3.5 h-3.5" /> Publish Policy</>
            }
          </Button>
          <Button
            variant="secondary"
            className="w-full justify-center"
            disabled={config.entityClasses.length === 0}
            onClick={() => {
              send(`Test this policy against a sample transcript: "Patient John Smith, SSN 482-55-1234, insurance ID INS-8821-X, reports chest pain."`);
            }}
          >
            <FlaskConical className="w-3.5 h-3.5" aria-hidden="true" /> Test on Sample
          </Button>
          <Button
            variant="ghost"
            className="w-full justify-center"
            disabled={config.useCaseName === "—"}
            onClick={() => showToast("Draft saved")}
          >
            <BookOpen className="w-3.5 h-3.5" aria-hidden="true" /> Save Draft
          </Button>
        </div>

        <div className="text-center text-[11px] text-[#9ca3af]">Powered by Gemini 2.5 Flash</div>

        {/* Toast */}
        {toast && (
          <div className="fixed bottom-6 right-6 flex items-center gap-2 bg-[#0d0f12] text-white text-[12px] font-medium px-4 py-2.5 rounded-lg shadow-lg z-50 animate-in fade-in slide-in-from-bottom-2">
            <Check className="w-3.5 h-3.5 text-emerald-400" aria-hidden="true" />
            {toast}
          </div>
        )}
      
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[11px] font-medium text-[#9ca3af] uppercase tracking-wide mb-0.5">{label}</div>
      <div className={cn("text-[12px]", value === "—" ? "text-[#d1d5db]" : "text-[#0d0f12] font-medium")}>{value}</div>
    </div>
  );
}
