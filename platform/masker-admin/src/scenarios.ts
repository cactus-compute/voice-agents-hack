import type { MaskerTrace } from './types';

export const SCENARIOS: MaskerTrace[] = [
  {
    id: 'scenario-a',
    label: 'Scenario A — Personal Info',
    transcript: "Text Sarah my address is 4821 Maple Drive and my SSN is 482-55-1234.",
    entities: [
      { type: 'name',    value: 'Sarah',        masked: '[NAME]' },
      { type: 'address', value: '4821 Maple Drive', masked: '[ADDRESS]' },
      { type: 'ssn',     value: '482-55-1234',  masked: '[SSN]' },
    ],
    policy: 'hipaa_base',
    route: 'masked-send',
    maskedTranscript: "Text [NAME] my address is [ADDRESS] and my SSN is [SSN].",
    explanation:
      "Detected a name, home address, and Social Security Number. Applied HIPAA base policy. Masked all identifiers before forwarding — the request can be answered without exposing raw PII.",
    traceEvents: [
      { stage: 'detection', message: 'Detected: name, address, SSN' },
      { stage: 'policy',    message: 'Applied HIPAA base policy' },
      { stage: 'masking',   message: 'Masked name → [NAME], address → [ADDRESS], SSN → [SSN]' },
      { stage: 'routing',   message: 'Route: masked-send — identifiers removed, safe to forward' },
    ],
  },
  {
    id: 'scenario-b',
    label: 'Scenario B — Healthcare PHI',
    transcript: "I have chest pain and my insurance ID is INS-8821-X. My doctor is Dr. Patel.",
    entities: [
      { type: 'health_context', value: 'chest pain',    masked: '[HEALTH_CONTEXT]' },
      { type: 'insurance_id',   value: 'INS-8821-X',   masked: '[INSURANCE_ID]' },
      { type: 'name',           value: 'Dr. Patel',    masked: '[NAME]' },
    ],
    policy: 'hipaa_clinical',
    route: 'local-only',
    maskedTranscript: null,
    explanation:
      "Detected health context combined with an insurance ID and provider name — a high-risk PHI combination. Applied HIPAA clinical policy. Request kept fully local; no data leaves the device.",
    traceEvents: [
      { stage: 'detection', message: 'Detected: health context, insurance ID, provider name' },
      { stage: 'policy',    message: 'Applied HIPAA clinical policy — high-risk PHI combination' },
      { stage: 'masking',   message: 'Masking skipped — request will not leave device' },
      { stage: 'routing',   message: 'Route: local-only — sensitive health data stays on device' },
    ],
  },
  {
    id: 'scenario-c',
    label: 'Scenario C — Safe Query',
    transcript: "What's the weather in San Francisco tomorrow?",
    entities: [],
    policy: 'none',
    route: 'safe-to-send',
    maskedTranscript: null,
    explanation:
      "No sensitive entities detected. No policy applied. Request is safe to forward as-is.",
    traceEvents: [
      { stage: 'detection', message: 'No sensitive entities detected' },
      { stage: 'policy',    message: 'No policy required' },
      { stage: 'routing',   message: 'Route: safe-to-send — request forwarded unmodified' },
    ],
  },
];
