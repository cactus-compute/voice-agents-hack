import { describe, it, expect, vi, beforeEach } from "vitest";
import { callCactusLLM, CactusHandoffError } from "./cactus.js";

describe("callCactusLLM", () => {
  beforeEach(() => {
    process.env.CACTUS_SIDECAR_URL = "http://127.0.0.1:8765";
    vi.restoreAllMocks();
  });

  it("posts to /v1/complete with sentinel-token assistant message when tool_use is in history", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        response: "done",
        function_calls: [],
        confidence: 0.9,
        cloud_handoff: false,
        cactus_tokens_in: 10,
        cactus_tokens_out: 3,
      }),
    });
    vi.stubGlobal("fetch", fetchMock);

    await callCactusLLM({
      messages: [
        {
          role: "assistant",
          content: [
            { type: "text", text: "thinking..." },
            { type: "tool_use", id: "x", name: "click", input: { ref: "42" } },
          ],
        },
      ],
      system: [],
      tools: [],
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:8765/v1/complete",
      expect.objectContaining({ method: "POST" }),
    );

    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    const assistantMsg = body.messages.find((m: any) => m.role === "assistant");
    expect(assistantMsg).toBeDefined();
    expect(assistantMsg.content).toContain(
      `<|tool_call_start|>[{"name":"click","arguments":{"ref":"42"}}]<|tool_call_end|>`,
    );
  });

  it("splits user tool_result blocks into role:tool messages", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        response: "done",
        function_calls: [],
        confidence: 0.9,
        cloud_handoff: false,
        cactus_tokens_in: 5,
        cactus_tokens_out: 2,
      }),
    });
    vi.stubGlobal("fetch", fetchMock);

    await callCactusLLM({
      messages: [
        {
          role: "user",
          content: [
            { type: "tool_result", tool_use_id: "x", content: "ok" },
          ],
        },
      ],
      system: [],
      tools: [],
    });

    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    const toolMsg = body.messages.find((m: any) => m.role === "tool");
    expect(toolMsg).toBeDefined();
    expect(toolMsg.content).toBe("ok");
  });

  it("parses function_calls into tool_use blocks with generated IDs", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        response: "",
        function_calls: [{ name: "click", arguments: { ref: "42" } }],
        confidence: 0.9,
        cloud_handoff: false,
        cactus_tokens_in: 5,
        cactus_tokens_out: 3,
      }),
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await callCactusLLM({
      messages: [{ role: "user", content: "go" }],
      system: [],
      tools: [],
    });

    expect(result.content[0]).toMatchObject({
      type: "tool_use",
      name: "click",
      input: { ref: "42" },
    });
    expect((result.content[0] as any).id).toMatch(/^tu_/);
    expect(result.stop_reason).toBe("tool_use");
  });

  it("throws CactusHandoffError when cloud_handoff is true", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        response: "",
        function_calls: [],
        confidence: 0.4,
        cloud_handoff: true,
      }),
    });
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      callCactusLLM({ messages: [], system: [], tools: [] }),
    ).rejects.toThrow(CactusHandoffError);
  });

  it("throws clear error when sidecar unreachable", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("ECONNREFUSED")));

    await expect(
      callCactusLLM({ messages: [], system: [], tools: [] }),
    ).rejects.toThrow(/Cactus sidecar unreachable at http:\/\/127\.0\.0\.1:8765/);
  });
});
