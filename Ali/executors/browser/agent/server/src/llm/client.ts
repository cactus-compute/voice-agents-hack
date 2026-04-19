/**
 * LLM Client for MCP Server
 *
 * Single provider: Cactus (on-device only).
 * Anthropic and Vertex paths have been removed — see UPSTREAM.md for diff notes.
 */

import { callCactusLLM, CactusHandoffError } from "./cactus.js";

export interface ContentBlockText {
  type: "text";
  text: string;
}

export interface ContentBlockImage {
  type: "image";
  source: {
    type: "base64";
    media_type: string;
    data: string;
  };
}

export interface ContentBlockToolUse {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, any>;
}

export interface ContentBlockToolResult {
  type: "tool_result";
  tool_use_id: string;
  content: string | Array<ContentBlockText | ContentBlockImage>;
}

export type ContentBlock = ContentBlockText | ContentBlockImage | ContentBlockToolUse | ContentBlockToolResult;

export interface Message {
  role: "user" | "assistant";
  content: string | ContentBlock[];
}

export interface Tool {
  name: string;
  description: string;
  input_schema: Record<string, any>;
}

export interface LLMResponse {
  content: ContentBlock[];
  stop_reason: string;
  usage: { input_tokens: number; output_tokens: number };
  /** The model that produced this response (for billing attribution) */
  model?: string;
  /** Raw Gemini response parts — preserves thought signatures for Gemini 3+ */
  _rawGeminiParts?: any[];
}

export interface CallLLMParams {
  messages: Message[];
  system: ContentBlockText[];
  tools: Tool[];
  model?: string;
  maxTokens?: number;
  signal?: AbortSignal;
  onText?: (chunk: string) => void;
}

/**
 * Call the LLM. This codebase is on-device-only — Cactus is the sole provider.
 */
export async function callLLM(params: CallLLMParams): Promise<LLMResponse> {
  if ((process.env.LLM_PROVIDER ?? "cactus") !== "cactus") {
    throw new Error(
      `LLM_PROVIDER=${process.env.LLM_PROVIDER} unsupported; only 'cactus' is wired in this build`
    );
  }
  try {
    return await callCactusLLM(params);
  } catch (err) {
    if (err instanceof CactusHandoffError) {
      // Phase 1: no Vertex fallback wired yet. Rethrow with a clearer message
      // so the side-channel handler in index.ts can surface it.
      throw new Error(
        "Cactus signaled cloud_handoff but no fallback provider is configured " +
        "(Phase 2 will wire Vertex). Original: " + err.message
      );
    }
    throw err;
  }
}

/** No-op kept for API compatibility with upstream callers. */
export function resetCredentialCache(): void {}
