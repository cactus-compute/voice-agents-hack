/**
 * Cactus on-device provider — talks to scripts/cactus_server.py over HTTP.
 *
 * Wire format mirrors Cactus's native ctypes API (sentinel-token tool calls,
 * file-path images that the sidecar materialises from images_b64). See
 * /Users/apple/Downloads/cactus-hanzi-browse-integration.md §3.4, §3.5, §4.5
 * and docs/superpowers/specs/2026-04-18-cactus-browse-swap-design.md.
 */

import { BaseProvider } from './base-provider.js';

const TOOL_CALL_START = '<|tool_call_start|>';
const TOOL_CALL_END = '<|tool_call_end|>';

// Tools we strip when running on a small on-device model. Saves ~1.5K prompt
// tokens (= ~8s prefill at 190 tok/s) without affecting any of the demo
// flows: example.com, gmail reply, linkedin DM, YC apply.
//   - tabs_*: single-tab demos
//   - read_console_messages, read_network_requests: debug-only
//   - resize_window: never needed
//   - javascript_tool: escape hatch we'd rather the model not reach for
//   - escalate: redundant with the model just emitting "I'm stuck" as text
// Re-add file_upload to this set if you're not running YC Apply (~200 tok).
const CACTUS_DROP_TOOLS = new Set([
  'tabs_create',
  'tabs_context',
  'tabs_close',
  'read_console_messages',
  'read_network_requests',
  'resize_window',
  'javascript_tool',
  'escalate',
  'solve_captcha',  // small model can't do captcha-solving; let it error out instead
]);

export class CactusProvider extends BaseProvider {
  getName() {
    return 'cactus';
  }

  static matchesUrl(baseUrl) {
    if (!baseUrl) return false;
    return (
      baseUrl.includes(':8765')
      || baseUrl.includes('/v1/complete')
      || baseUrl.includes('cactus')
    );
  }

  async getHeaders() {
    return { 'Content-Type': 'application/json' };
  }

  buildUrl(_useStreaming) {
    // Sidecar only has one endpoint; ignore the streaming flag.
    return this.config.apiBaseUrl;
  }

  buildRequestBody(messages, systemPrompt, tools, _useStreaming) {
    const sysText = Array.isArray(systemPrompt)
      ? systemPrompt.map(p => p.text || '').join('\n\n')
      : (systemPrompt || '');

    const cactusMessages = [];
    if (sysText) {
      cactusMessages.push({ role: 'system', content: sysText });
    }

    for (const msg of messages) {
      this._convertMessage(msg, cactusMessages);
    }

    return {
      messages: cactusMessages,
      tools: this._convertTools(tools),
      max_tokens: this.config.maxTokens || 2048,
    };
  }

  normalizeResponse(response) {
    if (response?.success === false) {
      throw new Error(`Cactus error: ${response?.error || 'unknown'}`);
    }

    const content = [];
    const text = response?.response;
    if (typeof text === 'string' && text.trim()) {
      content.push({ type: 'text', text });
    }

    const calls = Array.isArray(response?.function_calls) ? response.function_calls : [];
    for (const call of calls) {
      content.push({
        type: 'tool_use',
        id: `tu_${Math.random().toString(36).slice(2, 11)}`,
        name: call.name,
        input: call.arguments || {},
      });
    }

    if (content.length === 0) {
      content.push({ type: 'text', text: '' });
    }

    return {
      content,
      stop_reason: calls.length > 0 ? 'tool_use' : 'end_turn',
      usage: {
        input_tokens: response?.prefill_tokens || 0,
        output_tokens: response?.decode_tokens || 0,
      },
    };
  }

  async handleStreaming(response, onTextChunk, _log) {
    // Sidecar doesn't actually stream — it returns one JSON blob. Parse it as
    // if it were the non-streaming path, then synthesise a single text chunk
    // so any UI that depends on onTextChunk still gets called.
    const json = await response.json();
    const result = this.normalizeResponse(json);
    if (onTextChunk) {
      const text = result.content
        .filter(b => b.type === 'text')
        .map(b => b.text)
        .join('');
      if (text) onTextChunk(text);
    }
    return result;
  }

  /** @private */
  _convertMessage(msg, out) {
    const role = msg.role;
    const content = msg.content;

    if (typeof content === 'string') {
      out.push({ role, content });
      return;
    }
    if (!Array.isArray(content)) return;

    // Tool results emit one role=tool message per block, *before* any text/image
    // so the assistant→tool→assistant ordering stays intact.
    for (const block of content) {
      if (block.type === 'tool_result') {
        const c = typeof block.content === 'string'
          ? block.content
          : JSON.stringify(block.content);
        out.push({ role: 'tool', content: c });
      }
    }

    const toolUses = content.filter(b => b.type === 'tool_use');
    const textBlocks = content.filter(b => b.type === 'text');
    const imageBlocks = content.filter(b => b.type === 'image' && b.source?.data);

    // Assistant message with tool_use: encode tool calls inline using sentinel
    // tokens. Cactus's tokenizer recognises these on input replay.
    if (role === 'assistant' && toolUses.length > 0) {
      const textPart = textBlocks.map(b => b.text).join('\n').trim();
      const calls = toolUses.map(tu => ({ name: tu.name, arguments: tu.input || {} }));
      const sentinel = `${TOOL_CALL_START}${JSON.stringify(calls)}${TOOL_CALL_END}`;
      const merged = textPart ? `${textPart}\n${sentinel}` : sentinel;
      out.push({ role: 'assistant', content: merged });
      return;
    }

    // User/assistant message with text and/or images.
    if (textBlocks.length === 0 && imageBlocks.length === 0) return;

    const textPart = textBlocks.map(b => b.text).join('\n');
    const message = { role, content: textPart };
    if (imageBlocks.length > 0) {
      message.images_b64 = imageBlocks.map(b => b.source.data);
    }
    out.push(message);
  }

  /** @private */
  _convertTools(anthropicTools) {
    if (!anthropicTools || anthropicTools.length === 0) return [];
    return anthropicTools
      .filter(t => !CACTUS_DROP_TOOLS.has(t.name))
      .map(t => ({
        name: t.name,
        description: t.description,
        parameters: t.input_schema,
      }));
  }
}
