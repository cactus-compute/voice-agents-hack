/**
 * Lightweight safety net. Runs locally on transcript text before / alongside
 * the model. The model has its own crisis instructions (see systemPrompt.ts);
 * this is a belt-and-suspenders layer so the disclaimer surfaces even if the
 * model misses it or the audio path bypasses text entirely.
 */

const CRISIS_PATTERNS: RegExp[] = [
  /\b(kill|hurt|harm)\s+(myself|me)\b/i,
  /\bsuicid(e|al)\b/i,
  /\bend\s+(my|it\s+all|everything)\b/i,
  /\bdon'?t\s+want\s+to\s+(live|be\s+here|exist)\b/i,
  /\boverdose\b/i,
  /\bself[-\s]?harm\b/i,
];

export function detectCrisis(text: string): boolean {
  if (!text) return false;
  return CRISIS_PATTERNS.some((p) => p.test(text));
}

export const CRISIS_RESOURCES = {
  us: {
    label: '988 — Suicide & Crisis Lifeline',
    number: '988',
    url: 'https://988lifeline.org',
  },
  intl: {
    label: 'Find a helpline (findahelpline.com)',
    url: 'https://findahelpline.com',
  },
} as const;

export const DISCLAIMER = `Aurora is a research demo, not a medical service. It runs entirely on your device — nothing you say leaves this phone. It is not a substitute for a therapist, doctor, or crisis line. If you are in danger, please contact 988 (US) or your local emergency number.`;
