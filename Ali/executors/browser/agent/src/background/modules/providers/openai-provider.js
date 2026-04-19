/**
 * OpenAI API Provider
 * Handles GPT-4, GPT-4o, and compatible APIs
 */

import { BaseProvider } from './base-provider.js';
import { filterClaudeOnlyTools } from '../../../tools/definitions.js';

export class OpenAIProvider extends BaseProvider {
  getName() {
    return 'openai';
  }

  static matchesUrl(baseUrl) {
    return baseUrl.includes('openai.com')
      || baseUrl.includes('/v1/chat/completions')
      || baseUrl.includes('localhost:11434')
      || baseUrl.includes('127.0.0.1:11434');
  }

  getHeaders() {
    const headers = {
      'Content-Type': 'application/json',
    };

    if (this.config.apiKey) {
      headers['Authorization'] = `Bearer ${this.config.apiKey}`;
    }

    return headers;
  }

  buildUrl(_useStreaming) {
    return this.config.apiBaseUrl;
  }

  buildRequestBody(messages, systemPrompt, tools, useStreaming) {
    const convertedMessages = this._convertMessages(messages);

    // Extract text from systemPrompt array (Anthropic format)
    const systemText = Array.isArray(systemPrompt)
      ? systemPrompt.map(p => p.text).join('\n\n')
      : systemPrompt;

    const openaiMessages = [
      { role: 'system', content: systemText },
      ...convertedMessages,
    ];

    return {
      model: this.config.model,
      max_completion_tokens: this.config.maxTokens || 10000,
      messages: openaiMessages,
      tools: this._convertTools(tools),
      stream: useStreaming,
    };
  }

  normalizeResponse(response) {
    const message = response.choices?.[0]?.message;
    if (!message) {
      throw new Error(`Unexpected OpenAI response format: ${JSON.stringify(response).substring(0, 200)}`);
    }

    const content = [];

    // Add text content
    if (message.content) {
      content.push({ type: 'text', text: message.content });
    }

    // Add tool calls
    if (message.tool_calls) {
      for (const toolCall of message.tool_calls) {
        const toolUseBlock = {
          type: 'tool_use',
          id: toolCall.id,
          name: toolCall.function.name,
          input: typeof toolCall.function.arguments === 'string'
            ? JSON.parse(toolCall.function.arguments)
            : toolCall.function.arguments,
        };

        // Preserve reasoning for Kimi K2.5
        if (message.reasoning) {
          toolUseBlock.reasoning = message.reasoning;
        }
        if (message.reasoning_details) {
          toolUseBlock.reasoning_details = message.reasoning_details;
        }

        content.push(toolUseBlock);
      }
    }

    // Ensure content is never empty
    if (content.length === 0) {
      content.push({ type: 'text', text: '' });
    }

    // Map OpenAI finish_reason to Anthropic stop_reason
    let stopReason = 'end_turn';
    const finishReason = response.choices?.[0]?.finish_reason;
    if (finishReason === 'length') {
      stopReason = 'max_tokens';
    } else if (finishReason === 'tool_calls') {
      stopReason = 'tool_use';
    }

    const normalized = {
      content,
      stop_reason: stopReason,
      usage: response.usage,
    };

    // Store reasoning fields at the top level for easier access
    if (message.reasoning) {
      normalized.reasoning = message.reasoning;
    }
    if (message.reasoning_details) {
      normalized.reasoning_details = message.reasoning_details;
    }

    return normalized;
  }

  async handleStreaming(response, onTextChunk, _log) {
    const reader = response.body.getReader();
    const decoder = new TextDecoder();

    const state = {
      currentText: '',
      toolCalls: {},
      finishReason: null,
      reasoning: null,
      reasoningDetails: null,
      usage: null,
    };

    let buffer = '';

    // eslint-disable-next-line no-constant-condition
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        const data = line.slice(6);
        if (data === '[DONE]') continue;

        try {
          const chunk = JSON.parse(data);
          this._processStreamChunk(chunk, state, onTextChunk);
        } catch (e) {
          // Ignore JSON parse errors for malformed chunks
        }
      }
    }

    return this._buildStreamResult(state);
  }

  _processStreamChunk(chunk, state, onTextChunk) {
    const choice = chunk.choices?.[0];
    if (!choice) return;

    const delta = choice.delta;

    // Handle text content
    if (delta.content) {
      state.currentText += delta.content;
      if (onTextChunk) onTextChunk(delta.content);
    }

    // Handle tool calls
    if (delta.tool_calls) {
      this._accumulateToolCalls(delta.tool_calls, state.toolCalls);
    }

    // Handle finish reason
    if (choice.finish_reason) {
      state.finishReason = choice.finish_reason;
    }

    // Handle usage (may be in final chunk)
    if (chunk.usage) {
      state.usage = chunk.usage;
    }

    // Handle reasoning for Kimi K2.5 (may be in delta or full message)
    if (delta.reasoning && !state.reasoning) {
      state.reasoning = delta.reasoning;
    }
    if (delta.reasoning_details && !state.reasoningDetails) {
      state.reasoningDetails = delta.reasoning_details;
    }
    // Also check the full message (some providers send it there)
    if (choice.message?.reasoning && !state.reasoning) {
      state.reasoning = choice.message.reasoning;
    }
    if (choice.message?.reasoning_details && !state.reasoningDetails) {
      state.reasoningDetails = choice.message.reasoning_details;
    }
  }

  _accumulateToolCalls(deltaToolCalls, toolCalls) {
    for (const toolCall of deltaToolCalls) {
      const index = toolCall.index;

      if (!toolCalls[index]) {
        toolCalls[index] = {
          id: toolCall.id || `call_${Date.now()}_${index}`,
          name: toolCall.function?.name || '',
          arguments: '',
        };
      }

      if (toolCall.function?.name) {
        toolCalls[index].name = toolCall.function.name;
      }
      if (toolCall.function?.arguments) {
        toolCalls[index].arguments += toolCall.function.arguments;
      }
    }
  }

  _buildStreamResult(state) {
    const result = {
      content: [],
      usage: state.usage,
    };

    // Build content array
    if (state.currentText) {
      result.content.push({ type: 'text', text: state.currentText });
    }

    // Add tool calls
    for (const toolCall of Object.values(state.toolCalls)) {
      let parsedArgs = {};
      try {
        parsedArgs = JSON.parse(toolCall.arguments);
      } catch (e) {
        parsedArgs = {};
      }

      const toolUseBlock = {
        type: 'tool_use',
        id: toolCall.id,
        name: toolCall.name,
        input: parsedArgs,
      };

      // Preserve reasoning for Kimi K2.5
      if (state.reasoning) {
        toolUseBlock.reasoning = state.reasoning;
      }
      if (state.reasoningDetails) {
        toolUseBlock.reasoning_details = state.reasoningDetails;
      }

      result.content.push(toolUseBlock);
    }

    // Ensure content is never empty
    if (result.content.length === 0) {
      result.content.push({ type: 'text', text: '' });
    }

    // Map finish_reason to stop_reason
    let stopReason = 'end_turn';
    if (state.finishReason === 'length') {
      stopReason = 'max_tokens';
    } else if (state.finishReason === 'tool_calls') {
      stopReason = 'tool_use';
    }
    result.stop_reason = stopReason;

    // Store reasoning fields at the top level for easier access (Kimi K2.5)
    if (state.reasoning) {
      result.reasoning = state.reasoning;
    }
    if (state.reasoningDetails) {
      result.reasoning_details = state.reasoningDetails;
    }

    return result;
  }

  /**
   * Convert Anthropic tools to OpenAI format
   * Filters out Claude-only tools that don't work with OpenAI models
   * @private
   */
  _convertTools(anthropicTools) {
    if (!anthropicTools || anthropicTools.length === 0) return [];

    // Filter out Claude-only tools (like turn_answer_start, update_plan)
    const filteredTools = filterClaudeOnlyTools(anthropicTools);

    return filteredTools.map(tool => ({
      type: 'function',
      function: {
        name: tool.name,
        description: tool.description,
        parameters: tool.input_schema,
      },
    }));
  }

  /**
   * Convert Anthropic messages to OpenAI format
   * @private
   */
  _convertMessages(anthropicMessages) {
    const openaiMessages = [];

    for (const msg of anthropicMessages) {
      // Simple string content - keep as is
      if (typeof msg.content === 'string') {
        openaiMessages.push({
          role: msg.role,
          content: msg.content,
        });
        continue;
      }

      // Array content - need to convert blocks
      if (!Array.isArray(msg.content)) continue;

      if (msg.role === 'assistant') {
        openaiMessages.push(this._convertAssistantMessage(msg.content));
      } else if (msg.role === 'user') {
        this._convertUserMessage(msg.content, openaiMessages);
      }
    }

    return openaiMessages;
  }

  _convertAssistantMessage(contentBlocks) {
    let textContent = '';
    const toolCalls = [];
    let reasoning = null;
    let reasoningDetails = null;

    for (const block of contentBlocks) {
      if (block.type === 'text') {
        textContent += block.text;
      } else if (block.type === 'tool_use') {
        toolCalls.push({
          id: block.id,
          type: 'function',
          function: {
            name: block.name,
            arguments: JSON.stringify(block.input),
          },
        });

        // Preserve reasoning fields for Kimi K2.5
        if (block.reasoning && !reasoning) {
          reasoning = block.reasoning;
        }
        if (block.reasoning_details && !reasoningDetails) {
          reasoningDetails = block.reasoning_details;
        }
      }
    }

    const assistantMsg = {
      role: 'assistant',
      content: textContent || null,
    };
    if (toolCalls.length > 0) {
      assistantMsg.tool_calls = toolCalls;
    }

    // Include reasoning fields for Kimi K2.5 if present
    // Kimi RETURNS "reasoning" but EXPECTS "reasoning_content" when sending back
    if (reasoning) {
      assistantMsg.reasoning_content = reasoning;
    }
    if (reasoningDetails) {
      assistantMsg.reasoning_details = reasoningDetails;
    }

    return assistantMsg;
  }

  _convertUserMessage(contentBlocks, openaiMessages) {
    // User message with tool results, text, and images
    // Collect image blocks to attach to a user message after tool results
    const pendingImages = [];

    for (const block of contentBlocks) {
      if (block.type === 'tool_result') {
        const { content, images } = this._convertToolResultContent(block.content);
        pendingImages.push(...images);

        openaiMessages.push({
          role: 'tool',
          tool_call_id: block.tool_use_id,
          content: content,
        });
      } else if (block.type === 'text') {
        openaiMessages.push({
          role: 'user',
          content: block.text,
        });
      } else if (block.type === 'image' && block.source?.data) {
        pendingImages.push(this._makeImageUrl(block.source));
      }
    }

    // Send collected images as a user message with vision content
    if (pendingImages.length > 0) {
      openaiMessages.push({
        role: 'user',
        content: [
          { type: 'text', text: 'Screenshot of the current page:' },
          ...pendingImages,
        ],
      });
    }
  }

  _convertToolResultContent(blockContent) {
    if (typeof blockContent === 'string') {
      return { content: blockContent, images: [] };
    }

    if (!Array.isArray(blockContent)) {
      return { content: '', images: [] };
    }

    // Extract text and collect images from tool result content
    const textParts = [];
    const images = [];
    for (const c of blockContent) {
      if (c.type === 'text') {
        textParts.push(c.text);
      } else if (c.type === 'image' && c.source?.data) {
        // Queue image to send as a user message (OpenAI tool messages can't contain images)
        images.push(this._makeImageUrl(c.source));
      }
    }
    return { content: textParts.join('\n'), images };
  }

  _makeImageUrl(source) {
    return {
      type: 'image_url',
      image_url: {
        url: `data:${source.media_type || 'image/jpeg'};base64,${source.data}`,
      },
    };
  }
}
