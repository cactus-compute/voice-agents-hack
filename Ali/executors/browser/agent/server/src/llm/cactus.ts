/**
 * Cactus LLM provider — translates between Anthropic content blocks and the
 * Cactus native wire format, then POSTs to the Python sidecar at /v1/complete.
 *
 * Key translation decisions (per cactus-hanzi-browse-integration.md §4.3/4.5):
 *  - Assistant tool_use → sentinel string <|tool_call_start|>...<|tool_call_end|>
 *  - User tool_result   → {role:"tool", content:<stringified>} messages
 *  - User images        → images_b64 array on the same message (sidecar decodes)
 *  - Response function_calls → ContentBlockToolUse with generated tu_ IDs
 *  - cloud_handoff:true → throw CactusHandoffError (caller decides fallback)
 */

import { randomUUID } from "crypto";
import type { CallLLMParams, ContentBlock, LLMResponse, Message } from "./client.js";

const DEFAULT_SIDECAR_URL = "http://127.0.0.1:8765";

// ── Sentinel error ────────────────────────────────────────────────────────────

export class CactusHandoffError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CactusHandoffError";
  }
}

// ── Configuration ─────────────────────────────────────────────────────────────

/** Returns true if Cactus should be used as the LLM provider. */
export function isCactusConfigured(): boolean {
  // Always try Cactus — it's the sole provider in this build.
  // Set CACTUS_SIDECAR_URL to override the default 127.0.0.1:8765 address.
  return true;
}

// ── Anthropic → Cactus message translation ────────────────────────────────────

interface CactusMessage {
  role: string;
  content: string;
  images_b64?: string[];
}

/**
 * Build the Cactus-format content string for an assistant turn that may
 * contain text and/or tool_use blocks.
 * Per §4.5: text parts join first, then sentinel-wrapped JSON array of calls.
 */
function formatAssistantContent(blocks: ContentBlock[]): string {
  const parts: string[] = [];
  const calls: Array<{ name: string; arguments: Record<string, unknown> }> = [];

  for (const b of blocks) {
    if (b.type === "text") {
      parts.push(b.text);
    } else if (b.type === "tool_use") {
      calls.push({ name: b.name, arguments: b.input });
    }
  }

  if (calls.length > 0) {
    parts.push(`<|tool_call_start|>${JSON.stringify(calls)}<|tool_call_end|>`);
  }

  return parts.join("\n");
}

/**
 * Convert the Anthropic message list (+ system blocks) to Cactus messages.
 * Returns the list ready to POST to /v1/complete.
 */
function convertMessages(
  system: CallLLMParams["system"],
  messages: Message[],
): CactusMessage[] {
  const out: CactusMessage[] = [];

  // System prompt: flatten text blocks into a single system message.
  if (system && system.length > 0) {
    const systemText = system.map((b) => b.text).join("\n");
    if (systemText.trim()) {
      out.push({ role: "system", content: systemText });
    }
  }

  for (const msg of messages) {
    const { role, content } = msg;

    // Plain string content — emit as-is.
    if (typeof content === "string") {
      out.push({ role, content });
      continue;
    }

    if (role === "assistant") {
      // Flatten text + tool_use into a single sentinel-format string.
      out.push({ role: "assistant", content: formatAssistantContent(content) });
      continue;
    }

    // User message — handle tool_result, text, and image blocks.
    // tool_result blocks → individual role:tool messages.
    const toolResultBlocks = content.filter((b) => b.type === "tool_result");
    const otherBlocks = content.filter((b) => b.type !== "tool_result");

    for (const b of toolResultBlocks) {
      if (b.type !== "tool_result") continue; // narrow type
      let resultContent: string;
      if (typeof b.content === "string") {
        resultContent = b.content;
      } else {
        resultContent = JSON.stringify(b.content);
      }
      out.push({ role: "tool", content: resultContent });
    }

    if (otherBlocks.length > 0) {
      // Collect text and image blocks into a single user message.
      const textParts: string[] = [];
      const images_b64: string[] = [];

      for (const b of otherBlocks) {
        if (b.type === "text") {
          textParts.push(b.text);
        } else if (b.type === "image") {
          images_b64.push(b.source.data);
        }
      }

      const userMsg: CactusMessage = {
        role: "user",
        content: textParts.join("\n"),
      };
      if (images_b64.length > 0) {
        userMsg.images_b64 = images_b64;
      }
      out.push(userMsg);
    }
  }

  return out;
}

/** Convert Anthropic Tool list to bare Cactus tool format (sidecar wraps). */
function convertTools(
  tools: CallLLMParams["tools"],
): Array<{ name: string; description: string; parameters: Record<string, unknown> }> | null {
  if (!tools || tools.length === 0) return null;
  return tools.map((t) => ({
    name: t.name,
    description: t.description,
    parameters: t.input_schema,
  }));
}

// ── Cactus response → Anthropic LLMResponse ───────────────────────────────────

interface CactusResponse {
  response: string;
  function_calls?: Array<{ name: string; arguments?: Record<string, unknown> }>;
  confidence?: number;
  cloud_handoff?: boolean;
  cactus_tokens_in?: number;
  cactus_tokens_out?: number;
  model?: string;
}

function convertResponse(raw: CactusResponse): LLMResponse {
  if (raw.cloud_handoff === true) {
    throw new CactusHandoffError(
      `Cactus signaled cloud_handoff (confidence=${raw.confidence ?? "?"})`,
    );
  }

  const content: ContentBlock[] = [];

  if (raw.response && raw.response.trim().length > 0) {
    content.push({ type: "text", text: raw.response });
  }

  const functionCalls = raw.function_calls ?? [];
  for (const call of functionCalls) {
    content.push({
      type: "tool_use",
      id: `tu_${randomUUID()}`,
      name: call.name,
      input: call.arguments ?? {},
    });
  }

  return {
    content,
    stop_reason: functionCalls.length > 0 ? "tool_use" : "end_turn",
    usage: {
      input_tokens: raw.cactus_tokens_in ?? 0,
      output_tokens: raw.cactus_tokens_out ?? 0,
    },
    model: raw.model,
  };
}

// ── Public provider function ──────────────────────────────────────────────────

export async function callCactusLLM(params: CallLLMParams): Promise<LLMResponse> {
  const sidecarUrl = (
    process.env.CACTUS_SIDECAR_URL ?? DEFAULT_SIDECAR_URL
  ).replace(/\/$/, "");

  const cactusMessages = convertMessages(params.system, params.messages);
  const tools = convertTools(params.tools);

  const body = JSON.stringify({
    messages: cactusMessages,
    tools,
    max_tokens: params.maxTokens ?? 2048,
    confidence_threshold: 0.7,
    auto_handoff: false,
  });

  let response: Response;
  try {
    response = await fetch(`${sidecarUrl}/v1/complete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      signal: params.signal,
    });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    throw new Error(
      `Cactus sidecar unreachable at ${sidecarUrl} — is \`python scripts/cactus_server.py\` running? (${msg})`,
    );
  }

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`Cactus sidecar error ${response.status}: ${text.slice(0, 300)}`);
  }

  const raw = (await response.json()) as CactusResponse;
  return convertResponse(raw);
}
