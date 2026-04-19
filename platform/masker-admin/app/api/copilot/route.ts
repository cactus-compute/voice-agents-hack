import { GoogleGenerativeAI } from "@google/generative-ai";
import { NextRequest, NextResponse } from "next/server";

const SYSTEM_PROMPT = `You are the Masker Compliance Copilot — an expert assistant that helps teams configure privacy and compliance policies for voice and text AI agents.

Masker is a real-time privacy layer that sits between a voice/text agent and an LLM. It detects sensitive entities, applies compliance policies, and routes requests as:
- local-only: request stays on device, nothing forwarded
- masked-send: identifiers masked/tokenized before forwarding
- safe-to-send: no sensitive data, forwarded as-is

Your job is to help users configure a structured compliance policy. As the conversation progresses, you should build toward a complete policy config with these fields:
- useCaseName: short name for the use case
- frameworks: array of applicable frameworks (HIPAA, GDPR, PCI, Custom)
- entityClasses: array of { entity, action, rehydration } where action is one of: mask, redact, tokenize, allow, block
- scope: e.g. "voice · production" or "text · all environments"
- retentionWindow: e.g. "90 days"
- loggingMode: e.g. "masked-only" or "full"
- auditArtifacts: array of evidence artifacts to generate

Rules:
- Be concise and direct. No marketing language.
- Ask clarifying questions when the use case is ambiguous.
- When you have enough information, output a JSON block at the END of your message (after your explanation) in this exact format:

\`\`\`json
{
  "useCaseName": "...",
  "frameworks": [...],
  "entityClasses": [{ "entity": "...", "action": "...", "rehydration": false }],
  "scope": "...",
  "retentionWindow": "...",
  "loggingMode": "...",
  "auditArtifacts": [...],
  "status": "draft" | "ready"
}
\`\`\`

Only output the JSON block when you have enough information to populate at least useCaseName, frameworks, and entityClasses. Set status to "ready" only when scope, retention, and logging mode are also confirmed.`;

export async function POST(req: NextRequest) {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) {
    return NextResponse.json({ error: "GEMINI_API_KEY not configured" }, { status: 500 });
  }

  const { messages } = await req.json() as {
    messages: { role: "user" | "model"; parts: { text: string }[] }[];
  };

  try {
    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash",
      systemInstruction: SYSTEM_PROMPT,
    });

    const chat = model.startChat({ history: messages.slice(0, -1) });
    const lastMessage = messages[messages.length - 1];
    const result = await chat.sendMessage(lastMessage.parts[0].text);
    const text = result.response.text();

    // Extract JSON config block if present
    const jsonMatch = text.match(/```json\s*([\s\S]*?)```/);
    let config = null;
    if (jsonMatch) {
      try { config = JSON.parse(jsonMatch[1]); } catch { /* malformed JSON, ignore */ }
    }

    // Strip the JSON block from the display text
    const displayText = text.replace(/```json[\s\S]*?```/g, "").trim();

    return NextResponse.json({ text: displayText, config });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Unknown error";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
