/**
 * Google Gemini API Provider
 * Handles Gemini 2.0, 2.5, 3.0 models via Google AI Studio and Vertex AI
 * Supports thought signatures for thinking models
 */

import { BaseProvider } from './base-provider.js';
import { filterClaudeOnlyTools } from '../../../tools/definitions.js';
import { getAccessToken } from '../vertex-auth.js';

export class GoogleProvider extends BaseProvider {
  getName() {
    return 'google';
  }

  static matchesUrl(baseUrl) {
    return baseUrl.includes('generativelanguage.googleapis.com')
      || baseUrl.includes('aiplatform.googleapis.com');
  }

  _isVertexAI() {
    return this.config.apiBaseUrl?.includes('aiplatform.googleapis.com');
  }

  async getHeaders() {
    if (this._isVertexAI()) {
      // Vertex AI uses OAuth2 Bearer token from service account
      const token = await getAccessToken(this.config.apiKey);
      return {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      };
    }

    // Google AI Studio uses API key in query parameter, not header
    return {
      'Content-Type': 'application/json',
    };
  }

  buildUrl(useStreaming) {
    const baseUrl = this.config.apiBaseUrl;
    const endpoint = useStreaming ? 'streamGenerateContent' : 'generateContent';

    if (this._isVertexAI()) {
      // Vertex AI URL: {baseUrl}/publishers/google/models/{model}:{endpoint}?alt=sse
      const streamParam = useStreaming ? '?alt=sse' : '';
      const url = `${baseUrl}/publishers/google/models/${this.config.model}:${endpoint}${streamParam}`;
      console.log('[GoogleProvider] Vertex AI URL:', { model: this.config.model });
      return url;
    }

    // Google AI Studio URL
    const streamParam = useStreaming ? '&alt=sse' : '';
    const url = `${baseUrl}/${this.config.model}:${endpoint}?key=${this.config.apiKey}${streamParam}`;
    console.log('[GoogleProvider] Building URL:', {
      baseUrl,
      model: this.config.model,
      hasApiKey: !!this.config.apiKey,
      apiKeyLength: this.config.apiKey?.length,
    });
    return url;
  }

  buildRequestBody(messages, systemPrompt, tools, _useStreaming) {
    // Extract text from systemPrompt array
    const systemText = Array.isArray(systemPrompt)
      ? systemPrompt.map(p => p.text).join('\n\n')
      : systemPrompt;

    const googleTools = this._convertTools(tools);
    const googleMessages = this._convertMessages(messages);

    return {
      contents: googleMessages,
      tools: googleTools,
      tool_config: {
        function_calling_config: {
          mode: 'AUTO', // Let Gemini decide when to use functions vs return text
        },
      },
      generationConfig: {
        maxOutputTokens: this.config.maxTokens || 10000,
      },
      systemInstruction: { parts: [{ text: systemText }] },
    };
  }

  normalizeResponse(response) {
    const candidate = response.candidates?.[0];
    if (!candidate) {
      throw new Error(`Unexpected Google response format: ${JSON.stringify(response).substring(0, 200)}`);
    }

    const content = [];
    const parts = candidate.content?.parts || [];

    for (const part of parts) {
      if (part.text) {
        content.push({ type: 'text', text: part.text });
      } else if (part.functionCall) {
        // Note: We intentionally don't preserve thoughtSignature here
        // to keep responses in canonical format compatible with all providers
        content.push({
          type: 'tool_use',
          id: part.functionCall.id || `call_${Date.now()}`,
          name: part.functionCall.name,
          input: part.functionCall.args || {},
        });
      }
    }

    // Ensure content is never empty
    if (content.length === 0) {
      content.push({ type: 'text', text: '' });
    }

    return {
      content,
      stop_reason: this._mapFinishReason(candidate.finishReason),
      usage: response.usageMetadata,
    };
  }

  async handleStreaming(response, onTextChunk, _log) {
    const reader = response.body.getReader();
    const decoder = new TextDecoder();

    let currentText = '';
    let toolCalls = [];
    let finishReason = null;
    let buffer = '';

    // eslint-disable-next-line no-constant-condition
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        const parsed = this._parseSSELine(line);
        if (!parsed) continue;

        const { candidate, parts } = parsed;
        ({ currentText, toolCalls } = this._accumulateStreamParts(parts, currentText, toolCalls, onTextChunk));

        if (candidate.finishReason) {
          finishReason = candidate.finishReason;
        }
      }
    }

    return this._buildStreamResult(currentText, toolCalls, finishReason);
  }

  /** @private */
  _parseSSELine(line) {
    if (!line.startsWith('data: ')) return null;
    try {
      const chunk = JSON.parse(line.slice(6));
      const candidate = chunk.candidates?.[0];
      if (!candidate) return null;
      return { candidate, parts: candidate.content?.parts || [] };
    } catch (e) {
      return null;
    }
  }

  /** @private */
  _accumulateStreamParts(parts, currentText, toolCalls, onTextChunk) {
    for (const part of parts) {
      if (part.text) {
        currentText += part.text;
        if (onTextChunk) onTextChunk(part.text);
      }
      if (part.functionCall) {
        // Note: We intentionally don't preserve thoughtSignature
        // to keep responses in canonical format compatible with all providers
        toolCalls.push({
          id: part.functionCall.id || `call_${Date.now()}_${toolCalls.length}`,
          name: part.functionCall.name,
          input: part.functionCall.args || {},
        });
      }
    }
    return { currentText, toolCalls };
  }

  /** @private */
  _buildStreamResult(currentText, toolCalls, finishReason) {
    const content = [];

    if (currentText) {
      content.push({ type: 'text', text: currentText });
    }

    for (const toolCall of toolCalls) {
      content.push({
        type: 'tool_use',
        id: toolCall.id,
        name: toolCall.name,
        input: toolCall.input,
      });
    }

    if (content.length === 0) {
      content.push({ type: 'text', text: '' });
    }

    return {
      content,
      stop_reason: this._mapFinishReason(finishReason),
    };
  }

  /** @private */
  _mapFinishReason(finishReason) {
    if (finishReason === 'MAX_TOKENS') return 'max_tokens';
    return 'end_turn';
  }

  /**
   * Convert Anthropic tools to Google format
   * Google uses a subset of JSON Schema - need to sanitize
   * Filters out Claude-only tools that don't work with non-Claude models
   * @private
   */
  _convertTools(anthropicTools) {
    if (!anthropicTools || anthropicTools.length === 0) return [];

    // Filter out Claude-only tools (like turn_answer_start)
    const filteredTools = filterClaudeOnlyTools(anthropicTools);

    return [{
      functionDeclarations: filteredTools.map(tool => {
        // Clean the schema for Google - remove unsupported fields
        const cleanSchema = this._sanitizeSchema(tool.input_schema);

        return {
          name: tool.name,
          description: tool.description,
          parameters: cleanSchema,
        };
      }),
    }];
  }

  /**
   * Convert Anthropic messages to Google format
   * @private
   */
  _convertMessages(anthropicMessages) {
    const googleMessages = [];
    const toolUseIdToName = {};

    for (const msg of anthropicMessages) {
      const role = msg.role === 'assistant' ? 'model' : msg.role;
      const parts = [];

      if (typeof msg.content === 'string') {
        parts.push({ text: msg.content });
      } else if (Array.isArray(msg.content)) {
        for (const block of msg.content) {
          this._convertContentBlock(block, parts, toolUseIdToName);
        }
      }

      if (parts.length > 0) {
        googleMessages.push({ role, parts });
      }
    }

    return googleMessages;
  }

  /** @private */
  _convertContentBlock(block, parts, toolUseIdToName) {
    if (block.type === 'text') {
      parts.push({ text: block.text });
      return;
    }

    if (block.type === 'tool_use') {
      toolUseIdToName[block.id] = block.name;
      parts.push({
        functionCall: {
          name: block.name,
          args: block.input,
        },
      });
      return;
    }

    if (block.type === 'tool_result') {
      this._convertToolResult(block, parts, toolUseIdToName);
      return;
    }

    if (block.type === 'image' && block.source?.data) {
      parts.push({
        inlineData: {
          mimeType: block.source.media_type || 'image/jpeg',
          data: block.source.data,
        },
      });
    }
  }

  /** @private */
  _convertToolResult(block, parts, toolUseIdToName) {
    let responseContent = block.content;

    if (Array.isArray(block.content)) {
      responseContent = this._extractToolResultContent(block.content, parts);
    }

    const functionName = toolUseIdToName[block.tool_use_id] || 'unknown';

    parts.push({
      functionResponse: {
        name: functionName,
        response: { result: responseContent },
      },
    });
  }

  /** @private */
  _extractToolResultContent(contentArray, parts) {
    const textParts = [];
    for (const c of contentArray) {
      if (c.type === 'text') {
        textParts.push(c.text);
      } else if (c.type === 'image' && c.source?.data) {
        parts.push({
          inlineData: {
            mimeType: c.source.media_type || 'image/jpeg',
            data: c.source.data,
          },
        });
      }
    }
    return textParts.join('\n');
  }

  /**
   * Sanitize JSON Schema for Google Gemini
   * Google's API is stricter and uses Protocol Buffers, so remove certain fields
   * @private
   */
  _sanitizeSchema(schema) {
    if (!schema || typeof schema !== 'object') return schema;

    const cleaned = {};

    // Handle type field - Google doesn't support array types like ["string", "number"]
    if (schema.type) {
      if (Array.isArray(schema.type)) {
        // Use first type, or default to 'string'
        cleaned.type = schema.type[0] || 'string';
      } else {
        cleaned.type = schema.type;
      }
    }

    // Copy other basic fields
    if (schema.description) cleaned.description = schema.description;
    if (schema.enum) cleaned.enum = schema.enum;
    if (schema.required) cleaned.required = schema.required;

    // Handle properties (recursively clean each property)
    if (schema.properties) {
      cleaned.properties = {};
      for (const [key, value] of Object.entries(schema.properties)) {
        cleaned.properties[key] = this._sanitizeSchema(value);
      }
    }

    // Handle items for arrays (recursively clean)
    if (schema.items) {
      cleaned.items = this._sanitizeSchema(schema.items);
    }

    // Handle oneOf/anyOf - convert to simplified format
    if (schema.oneOf || schema.anyOf) {
      // Google doesn't support oneOf/anyOf well, just use first option
      const options = schema.oneOf || schema.anyOf;
      if (Array.isArray(options) && options.length > 0) {
        return this._sanitizeSchema(options[0]);
      }
    }

    return cleaned;
  }
}
