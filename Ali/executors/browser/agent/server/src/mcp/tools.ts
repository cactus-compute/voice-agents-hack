/**
 * MCP tool definitions and prompt templates.
 *
 * Pure data — no runtime dependencies. Loaded by the MCP server (index.ts).
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

// --- Tool definitions ---

export const TOOLS: Tool[] = [
  {
    name: "browser_start",
    description: `Delegates a browsing task to a sub-agent running in the USER'S REAL Chrome — the browser they have open right now, already signed into everything (Gmail, LinkedIn, GitHub, their bank, admin panels, internal tools, paid subscriptions, localhost, staging). Not a headless Chromium, not a sandboxed test profile, not a fresh instance — the user's literal browser, with every cookie, session, 2FA trust, and saved state already in place.

THIS IS NOT a low-level click/type primitive. It's a full browsing agent you delegate to. You give it a task in natural language ("find my 5 most recent LinkedIn DMs and summarize them", "post this reply on the tweet at /status/123", "test whether signup works on localhost:3000 with my real Google account"), and the sub-agent figures out the steps, interacts with the pages, handles async state, takes screenshots, and returns the answer.

You don't tell it which buttons to click. You tell it what you want done.

While the sub-agent runs you can:
- Watch progress with browser_status
- Course-correct mid-flight with browser_message (e.g. "actually, only the ones from Engineering roles")
- Stop it with browser_stop
- Start multiple tasks in parallel — each opens its own browser window

USE THIS whenever the task needs the user's actual identity or state on the web:
- Reading the user's own account data (inbox, DMs, dashboards, orders, tickets, analytics)
- Posting, commenting, replying, or submitting on the user's behalf (X, LinkedIn, Reddit, HN, forums, forms)
- Any site that would hit a login wall or bot detection for a clean browser
- Testing localhost or staging with the user's real sessions, OAuth, cookies, and localStorage
- Continuing from whatever state the user left their browser in (shopping carts, filters, partial forms)
- Anything you can describe as "the user would normally do this in their own Chrome"

Disambiguation from other tools the agent may have:
- web_search / Tavily / Exa → public content search. No login, no interaction. Use for "find info about X" questions AND for public news aggregators (Hacker News, Reddit front pages, blog indexes) where you just want to read what's there.
- Chrome DevTools MCP / Playwright MCP → a FRESH headless Chromium for automated testing. Starts with ZERO user state. Can test unauthenticated UI but cannot BE the user.
- WebFetch / curl → raw static HTML. No JS, no auth, no interaction. Use for fully-public static pages and news/aggregator URLs you just need to read.

Fallback rule: if WebFetch / Tavily / Exa / web_search returned empty, garbage, a login wall, or failed bot detection → hand the task to browser_start and let the sub-agent handle it. If the task needs the user's real identity on a site, skip the alternatives entirely and go here first.

Return statuses:
- "complete" — sub-agent finished, result in "answer"
- "error" — sub-agent failed. Call browser_screenshot to see the page, then browser_message to retry or browser_stop to clean up.
- "timeout" — 5-minute window elapsed but the sub-agent is still working. Normal for long tasks. Call browser_screenshot to check progress, then browser_message to continue or browser_stop to end.`,
    inputSchema: {
      type: "object",
      properties: {
        task: {
          type: "string",
          description: "What you want done in the browser. Be specific: include the website, the goal, and any details that matter.",
        },
        url: {
          type: "string",
          description: "Starting URL to navigate to before the task begins.",
        },
        context: {
          type: "string",
          description: "All the information the agent might need: form field values, text to paste, tone/style preferences, credentials, choices to make.",
        },
      },
      required: ["task"],
    },
  },
  {
    name: "browser_message",
    description: `Course-correct or extend a browsing sub-agent started by browser_start. Blocks until the sub-agent acts on the message.

Use this to steer the sub-agent in natural language instead of starting a new session:
- Refine: "actually change the quantity to 3", "only the ones from Engineering roles"
- Continue: "now click Download", "go to the next page and do the same thing"
- Retry after error: "try again using the second address"
- Answer a question the sub-agent asks: "yes, proceed with the 2026 plan"

The browser window and session state are preserved — the sub-agent resumes exactly where it left off, not from scratch.`,
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", description: "Session ID from browser_start." },
        message: { type: "string", description: "Follow-up instructions or answer to the agent's question." },
      },
      required: ["session_id", "message"],
    },
  },
  {
    name: "browser_status",
    description: `Monitor a running browsing sub-agent. Returns session ID, status, task description, and the last 5 steps the sub-agent took.

Useful for: watching progress on long-running tasks, deciding whether to course-correct with browser_message, or confirming which window to stop.`,
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", description: "Check a specific session. If omitted, returns all running sessions." },
      },
    },
  },
  {
    name: "browser_stop",
    description: `Stop a browsing sub-agent. The sub-agent halts but the browser window stays open so the user can review the final page state.

Without "remove", the session can still be resumed with browser_message. With "remove: true", the browser window closes and the session history is permanently deleted.`,
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", description: "Session to stop." },
        remove: { type: "boolean", description: "If true, also close the browser window and delete session history." },
      },
      required: ["session_id"],
    },
  },
  {
    name: "browser_screenshot",
    description: `Capture a screenshot of the current page in the user's Chrome. Returns a PNG image.

Call this when browser_start returns "error" or "timeout" — see what the sub-agent was looking at before deciding whether to retry, course-correct, or give up.`,
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", description: "Session to screenshot. If omitted, captures the currently active tab." },
      },
    },
  },
];

// --- Prompt definitions ---

export const PROMPTS = [
  {
    name: "linkedin-prospector",
    description: "Find people on LinkedIn and send personalized connection requests. Uses your real signed-in browser — LinkedIn has no API for this. Supports networking, sales, partnerships, and hiring strategies. Each connection note is unique.",
    arguments: [
      { name: "goal", description: "What you're trying to achieve: networking, sales, partnerships, hiring, or market-research", required: true },
      { name: "topic", description: "Topic, industry, or product area (e.g., 'browser automation', 'AI DevTools')", required: true },
      { name: "count", description: "How many people to find (default: 15)", required: false },
      { name: "context", description: "Extra context: your product, company, what you offer, who your ideal target is", required: false },
    ],
  },
  {
    name: "e2e-tester",
    description: "Test a web app in your real browser — click through flows and report what's broken with screenshots and code references. Gathers context from the codebase first, then uses the browser only for UI interaction and visual verification. Works on localhost, staging, and preview URLs.",
    arguments: [
      { name: "url", description: "App URL to test (e.g., 'localhost:3000', 'staging.myapp.com')", required: true },
      { name: "what", description: "What to test: 'signup flow', 'checkout', 'everything', or 'what I just changed'", required: false },
      { name: "credentials", description: "Test login credentials if needed (e.g., 'test@test.com / password123')", required: false },
    ],
  },
  {
    name: "social-poster",
    description: "Post content across social platforms from your real signed-in browser. Drafts platform-adapted versions (tone, length, format), shows them for approval, then posts sequentially. Works with LinkedIn, Twitter/X, Reddit, Hacker News, and Product Hunt.",
    arguments: [
      { name: "content", description: "What to post about: a topic, announcement, 'our latest release', or the exact text", required: true },
      { name: "platforms", description: "Where to post: 'linkedin', 'twitter', 'reddit', 'hackernews', 'producthunt', or 'all' (default: linkedin + twitter)", required: false },
      { name: "context", description: "Extra context: link to include, images, tone preference, target audience", required: false },
    ],
  },
  {
    name: "x-marketer",
    description: "Find conversations on X/Twitter where people discuss problems your product solves, research each author, draft voice-matched replies, and post from your real signed-in account. Supports three modes: conversations (find pain points), influencers (warm up large accounts), brand (monitor mentions). Loads your voice profile for natural-sounding replies.",
    arguments: [
      { name: "product", description: "Product name, URL, and one-line description", required: true },
      { name: "keywords", description: "Search terms to find relevant conversations (comma-separated)", required: true },
      { name: "mode", description: "conversations (default), influencers, or brand", required: false },
      { name: "count", description: "How many engagements per session (default: 10, max: 15)", required: false },
      { name: "context", description: "Extra context: pain points, competitors to avoid, tone preference", required: false },
    ],
  },
];

// --- Skill file loader + prompt templates ---

const __skillDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "skills");

function loadSkillContent(skillName: string): string {
  const skillPath = join(__skillDir, skillName, "SKILL.md");
  try {
    const raw = readFileSync(skillPath, "utf-8");
    return raw.replace(/^---[\s\S]*?---\n*/, ""); // Strip YAML frontmatter
  } catch {
    return `Error: Could not read ${skillName}/SKILL.md. Make sure the file exists at server/skills/${skillName}/SKILL.md`;
  }
}

export const PROMPT_TEMPLATES: Record<string, (args: Record<string, string>) => { description: string; messages: any[] }> = {
  "linkedin-prospector": (args) => {
    const count = args.count || "15";
    const goal = (args.goal || "networking").toLowerCase();
    const topic = args.topic || "";
    const context = args.context || "";

    return {
      description: "Find LinkedIn prospects and send personalized connections",
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: `Find ${count} people on LinkedIn related to "${topic}" and send personalized connection requests.

My goal: **${goal}**
${context ? `\nContext about me/my product: ${context}` : ""}

${loadSkillContent("linkedin-prospector")}`,
          },
        },
      ],
    };
  },

  "e2e-tester": (args) => {
    const url = args.url || "localhost:3000";
    const what = args.what || "";
    const credentials = args.credentials || "";

    return {
      description: "Test a web app in a real browser and report findings",
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: `Test my web app at ${url} in a real browser and report what's working and what's broken.
${what ? `\nFocus on: ${what}` : ""}
${credentials ? `\nTest credentials: ${credentials}` : ""}

${loadSkillContent("e2e-tester")}`,
          },
        },
      ],
    };
  },

  "social-poster": (args) => {
    const content = args.content || "";
    const platforms = args.platforms || "linkedin, twitter";
    const context = args.context || "";

    return {
      description: "Draft and post content across social platforms",
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: `Post about this across social platforms: "${content}"

Platforms: ${platforms}
${context ? `\nExtra context: ${context}` : ""}

${loadSkillContent("social-poster")}`,
          },
        },
      ],
    };
  },

  "x-marketer": (args) => {
    const product = args.product || "";
    const keywords = args.keywords || "";
    const mode = args.mode || "conversations";
    const count = args.count || "10";
    const context = args.context || "";

    return {
      description: "Find X/Twitter conversations and draft voice-matched replies",
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: `Run the x-marketer skill.

Product: ${product}
Mode: ${mode}
Keywords: ${keywords}
Count: ${count}
${context ? `Extra context: ${context}` : ""}

${loadSkillContent("x-marketer")}`,
          },
        },
      ],
    };
  },
};
