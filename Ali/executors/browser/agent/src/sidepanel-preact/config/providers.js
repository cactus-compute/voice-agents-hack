// Provider configurations
export const PROVIDERS = {
  anthropic: {
    name: 'Anthropic',
    baseUrl: 'https://api.anthropic.com/v1/messages',
    models: [
      { id: 'claude-opus-4-5-20251101', name: 'Opus 4.5' },
      { id: 'claude-opus-4-20250514', name: 'Opus 4' },
      { id: 'claude-sonnet-4-20250514', name: 'Sonnet 4' },
      { id: 'claude-haiku-4-5-20251001', name: 'Haiku 4.5' },
    ],
  },
  openai: {
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1/chat/completions',
    models: [
      { id: 'gpt-4o', name: 'GPT-4o' },
      { id: 'gpt-5', name: 'GPT-5' },
      { id: 'gpt-5-mini', name: 'GPT-5 Mini' },
      { id: 'gpt-4.1', name: 'GPT-4.1' },
      { id: 'o3', name: 'o3' },
      { id: 'o4-mini', name: 'o4-mini' },
    ],
  },
  google: {
    name: 'Google',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/models',
    models: [
      { id: 'gemini-3-pro-preview', name: 'Gemini 3 Pro (Preview)' },
      { id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash' },
      { id: 'gemini-2.5-pro', name: 'Gemini 2.5 Pro' },
    ],
  },
  vertex: {
    name: 'Google Vertex AI',
    // baseUrl is built dynamically from the service account's project_id
    baseUrl: 'vertex-ai',
    models: [
      { id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash' },
      { id: 'gemini-2.5-pro', name: 'Gemini 2.5 Pro' },
      { id: 'gemini-2.5-flash-lite', name: 'Gemini 2.5 Flash Lite' },
    ],
  },
  openrouter: {
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
    models: [
      { id: 'qwen/qwen3-vl-8b-instruct', name: 'Qwen3 VL 8B (Self-hostable)' },
      { id: 'qwen/qwen3-vl-32b-instruct', name: 'Qwen3 VL 32B' },
      { id: 'qwen/qwen3-vl-235b-a22b-thinking', name: 'Qwen3 VL 235B (Reasoning)' },
      { id: 'qwen/qwen3-vl-30b-a3b-instruct', name: 'Qwen3 VL 30B MoE (Self-hostable)' },
      { id: 'google/gemini-2.5-flash', name: 'Gemini 2.5 Flash' },
      { id: 'moonshotai/kimi-k2.5', name: 'Kimi K2.5 (Reasoning)' },
    ],
  },
};

export const CODEX_MODELS = [
  { id: 'gpt-5.1-codex-max', name: 'GPT-5.1 Codex Max' },
  { id: 'gpt-5.2-codex', name: 'GPT-5.2 Codex' },
  { id: 'gpt-5.1-codex-mini', name: 'GPT-5.1 Codex Mini' },
  { id: 'gpt-5.1-codex', name: 'GPT-5.1 Codex' },
  { id: 'gpt-5-codex', name: 'GPT-5 Codex' },
];
