/**
 * Tool definitions for server-side managed agent loop.
 *
 * These mirror the extension's tool definitions but are used by the server
 * when driving the agent loop via Vertex AI. The extension receives
 * tool execution requests and returns results.
 */

import type { Tool } from "../llm/client.js";

export const AGENT_TOOLS: Tool[] = [
  {
    name: "read_page",
    description: `Get a rich DOM tree of the page via Chrome DevTools Protocol. Returns interactive elements with numeric backendNodeId references (e.g., [42]<button>Submit</button>). IMPORTANT: Only use element IDs from the CURRENT output — IDs change between calls. Pierces shadow DOM and iframes automatically.`,
    input_schema: {
      type: "object",
      properties: {
        max_chars: {
          type: "number",
          description: "Maximum characters for output (default: 50000).",
        },
      },
      required: [],
    },
  },
  {
    name: "find",
    description: `Find elements on the page using natural language. Can search by purpose (e.g., "search bar", "login button") or text content. Returns up to 20 matching elements with references.`,
    input_schema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: 'Natural language description of what to find (e.g., "search bar", "add to cart button")',
        },
      },
      required: ["query"],
    },
  },
  {
    name: "form_input",
    description: `Set values in ANY form element — text inputs, textareas, dropdowns, checkboxes, radio buttons, date pickers. For dropdowns, just pass the desired option text. ALWAYS prefer form_input over computer clicks for form fields.`,
    input_schema: {
      type: "object",
      properties: {
        ref: {
          type: "string",
          description: 'Element reference from read_page (e.g., "42") or find tool (e.g., "ref_1")',
        },
        value: {
          type: "string",
          description: "The value to set.",
        },
      },
      required: ["ref", "value"],
    },
  },
  {
    name: "computer",
    description: `Use a mouse and keyboard to interact with a web browser, and take screenshots.
* Click elements using their ref from read_page or find tools.
* Take screenshots to see the current page state.
* Scroll to see more content.`,
    input_schema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: [
            "left_click", "right_click", "type", "screenshot", "wait",
            "scroll", "key", "left_click_drag", "double_click", "triple_click",
            "zoom", "scroll_to", "hover",
          ],
          description: "The action to perform.",
        },
        coordinate: {
          type: "array",
          items: { type: "number" },
          description: "(x, y) pixel coordinates for click/scroll actions.",
        },
        text: {
          type: "string",
          description: "Text to type or key(s) to press.",
        },
        duration: {
          type: "number",
          description: "Seconds to wait (for wait action). Max 30.",
        },
        scroll_direction: {
          type: "string",
          enum: ["up", "down", "left", "right"],
          description: "Direction to scroll.",
        },
        scroll_amount: {
          type: "number",
          description: "Number of scroll ticks (1-10).",
        },
        ref: {
          type: "string",
          description: "Element reference for click/scroll_to actions.",
        },
        region: {
          type: "array",
          items: { type: "number" },
          description: "(x0, y0, x1, y1) region for zoom action.",
        },
      },
      required: ["action"],
    },
  },
  {
    name: "computer_os",
    description: `Drive the operating system for tasks that go beyond the browser. Use for:
- Native file upload dialogs: click the upload button, wait 1.5s for the OS dialog, then call this with action="drive_file_picker" and the full path to the file.
- Focusing an app before OS interactions: action="focus_app" with the app name (e.g., "Google Chrome").
- Arbitrary macOS automation: action="applescript" with a script string. Only use when the specific actions above don't fit.

Available ONLY on macOS. Prerequisites: user has granted Accessibility and Automation permissions to the browser during hanzi-browse setup.`,
    input_schema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["drive_file_picker", "focus_app", "applescript"],
          description: "Which OS operation to perform.",
        },
        path: { type: "string", description: "Absolute file path (for drive_file_picker)." },
        app: { type: "string", description: "App name or bundle ID (for focus_app)." },
        script: { type: "string", description: "AppleScript source (for applescript)." },
      },
      required: ["action"],
    },
  },
  {
    name: 'await_confirmation',
    description: `Pause the task and request approval from the parent agent / user. Call before ANY irreversible action: form submission, message send, content post, payment, delete, destructive OS command.

The tool does not return immediately. When the parent responds, the tool returns with the response as a string. Responses mean:
- "yes, proceed" / "approved" — user approved; continue with the action.
- "no, cancel" / "denied" — user denied; do not perform the action; call end_turn with a brief explanation.
- anything else — treat as new instructions (e.g., "change subject to 'Quick sync' and confirm again"). Apply the change, then call await_confirmation again.`,
    input_schema: {
      type: 'object',
      properties: {
        summary: {
          type: 'string',
          description: 'One-line description of what will happen if approved. Shown directly to the user.',
        },
        payload: {
          type: 'object',
          description: 'Optional structured data shown alongside the summary (recipient, subject, URL, etc.).',
        },
      },
      required: ['summary'],
    },
  },
  {
    name: "navigate",
    description: `Navigate to a URL, or go forward/back in browser history.`,
    input_schema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description: 'The URL to navigate to. Use "forward"/"back" for history navigation.',
        },
      },
      required: ["url"],
    },
  },
  {
    name: "get_page_text",
    description: `Extract raw text content from the page, prioritizing article content. Ideal for reading text-heavy pages.`,
    input_schema: {
      type: "object",
      properties: {
        max_chars: {
          type: "number",
          description: "Maximum characters for output (default: 50000).",
        },
      },
      required: [],
    },
  },
  {
    name: "javascript_tool",
    description: `Execute JavaScript in the page context. Returns the result of the last expression. Do NOT use 'return' — just write the expression.`,
    input_schema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          description: "Must be 'javascript_exec'.",
        },
        text: {
          type: "string",
          description: "JavaScript code to execute.",
        },
      },
      required: ["action", "text"],
    },
  },
];
