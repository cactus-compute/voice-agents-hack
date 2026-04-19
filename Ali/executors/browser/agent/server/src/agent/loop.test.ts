import { describe, it, expect, vi, beforeEach } from "vitest";
import { runAgentLoop } from "./loop.js";
import { callLLM } from "../llm/client.js";

// Mock callLLM so the test doesn't need an LLM or relay. It always tells the
// agent to navigate to the same dead URL — simulating the x.com trap seen in
// the wild (see docs/superpowers/plans/2026-04-16-domain-skills-eval-implementation.md).
const deadUrl = "https://x.com/sama/status/1871729391595520213";

vi.mock("../llm/client.js", () => ({
  callLLM: vi.fn(async () => ({
    content: [
      {
        type: "tool_use",
        id: `t-${Math.random().toString(36).slice(2, 8)}`,
        name: "navigate",
        input: { url: deadUrl },
      },
    ],
    stop_reason: "tool_use",
    usage: { input_tokens: 10, output_tokens: 5 },
  })),
}));

// ---------------------------------------------------------------------------
// Helper: minimal async queue used by the await_confirmation test
// ---------------------------------------------------------------------------
class TestQueue {
  private items: string[];
  private waiters: ((s: string) => void)[] = [];
  constructor(items: string[]) { this.items = [...items]; }
  async next(): Promise<string> {
    if (this.items.length) return this.items.shift()!;
    return new Promise(r => this.waiters.push(r));
  }
  push(s: string) {
    if (this.waiters.length) this.waiters.shift()!(s);
    else this.items.push(s);
  }
}

describe("runAgentLoop stuck-loop detection", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("aborts early when the agent navigates to the same URL 3+ times", async () => {
    const executeTool = vi.fn(async () => ({
      success: true,
      output: "Navigated (fake)",
    }));

    const result = await runAgentLoop({
      task: "test dead-url loop",
      url: deadUrl,
      executeTool,
      maxSteps: 50,
    });

    expect(result.status).toBe("error");
    expect(result.answer).toMatch(/Stuck-loop/);
    expect(result.answer).toContain(deadUrl);
    // Must abort well before maxSteps — the whole point.
    expect(result.steps).toBeLessThanOrEqual(5);
    // The 3rd navigate triggers the abort BEFORE executing, so the tool runs
    // exactly twice (for navigates 1 and 2) and never for the 3rd repeat.
    expect(executeTool.mock.calls.length).toBe(2);
  });
});

// ---------------------------------------------------------------------------
// await_confirmation pause/resume tests
// ---------------------------------------------------------------------------

describe('await_confirmation handling', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('emits task_awaiting_confirmation and pauses until message arrives', async () => {
    const relayMessages: any[] = [];
    const fakeRelay = {
      send: (m: any) => { relayMessages.push(m); },
    };

    let llmCallCount = 0;
    vi.mocked(callLLM).mockImplementation(async () => {
      llmCallCount++;
      if (llmCallCount === 1) {
        return {
          content: [{
            type: 'tool_use',
            id: 't-confirm-1',
            name: 'await_confirmation',
            input: { summary: 'About to submit application', payload: { site: 'yc' } },
          }],
          stop_reason: 'tool_use',
          usage: { input_tokens: 10, output_tokens: 5 },
        };
      }
      // On resume: the loop feeds the user's response back as a tool result,
      // then asks LLM again — this time it signals completion.
      return {
        content: [{ type: 'text', text: 'Submitted successfully.' }],
        stop_reason: 'end_turn',
        usage: { input_tokens: 10, output_tokens: 5 },
      };
    });

    // No-op executeTool — await_confirmation is intercepted before it reaches executeTool,
    // and the second LLM turn returns end_turn so no other tool is ever dispatched.
    const executeTool = vi.fn(async () => ({ success: true, output: 'done' }));

    const loopPromise = runAgentLoop({
      task: 'apply to YC',
      sessionId: 'sess_test',
      executeTool,
      relay: fakeRelay,
      userMessageQueue: new TestQueue(['yes, proceed']),
    });

    // Give the loop a tick to reach the await_confirmation pause and emit the relay event
    await new Promise(r => setTimeout(r, 10));
    const confirmEvent = relayMessages.find(m => m.type === 'task_awaiting_confirmation');
    expect(confirmEvent).toBeDefined();
    expect(confirmEvent.summary).toBe('About to submit application');
    expect(confirmEvent.payload).toEqual({ site: 'yc' });

    const result = await loopPromise;
    expect(result.status).toBe('complete');
    expect(llmCallCount).toBe(2);
    // await_confirmation is handled in-loop; executeTool should never be called
    expect(executeTool).not.toHaveBeenCalled();
  });
});
