// ── Sessions ──────────────────────────────────────────────────────────────────
export type RiskLevel = "low" | "medium" | "high" | "critical";
export type SessionStatus = "clean" | "masked" | "blocked" | "flagged";
export type Channel = "voice" | "text";

export interface Session {
  id: string;
  timestamp: string;
  channel: Channel;
  useCase: string;
  policyVersion: string;
  status: SessionStatus;
  entitiesDetected: number;
  riskLevel: RiskLevel;
  duration: string;
  rawHash: string;
  redactedTranscript: string;
  entitySpans: EntitySpan[];
}

export interface EntitySpan {
  type: string;
  value: string;
  masked: string;
  action: string;
  timestamp: string;
  start: number;
  end: number;
}

export const SESSIONS: Session[] = [
  {
    id: "ses_01HXKP2M9R",
    timestamp: "2026-04-18T14:32:11Z",
    channel: "voice",
    useCase: "Healthcare Intake",
    policyVersion: "hipaa-base@2.1",
    status: "masked",
    entitiesDetected: 4,
    riskLevel: "high",
    duration: "1m 42s",
    rawHash: "sha256:a3f9c1d2e4b7...",
    redactedTranscript:
      "Patient [NAME] with DOB [DATE] reports [HEALTH_CONTEXT]. Insurance ID [INSURANCE_ID] on file.",
    entitySpans: [
      { type: "name", value: "Maria Gonzalez", masked: "[NAME]", action: "mask", timestamp: "00:04", start: 8, end: 22 },
      { type: "date_of_birth", value: "1984-03-12", masked: "[DATE]", action: "mask", timestamp: "00:09", start: 32, end: 42 },
      { type: "health_context", value: "chest pain and shortness of breath", masked: "[HEALTH_CONTEXT]", action: "allow", timestamp: "00:15", start: 51, end: 85 },
      { type: "insurance_id", value: "INS-8821-X", masked: "[INSURANCE_ID]", action: "tokenize", timestamp: "00:22", start: 99, end: 109 },
    ],
  },
  {
    id: "ses_01HXKP3N4S",
    timestamp: "2026-04-18T14:28:05Z",
    channel: "text",
    useCase: "Financial Advisory",
    policyVersion: "pci-strict@1.0",
    status: "blocked",
    entitiesDetected: 2,
    riskLevel: "critical",
    duration: "0m 18s",
    rawHash: "sha256:b8e2f4a1c9d3...",
    redactedTranscript: "Request blocked. Raw input contained [SSN] and [CARD_NUMBER].",
    entitySpans: [
      { type: "ssn", value: "482-55-1234", masked: "[SSN]", action: "block", timestamp: "00:02", start: 12, end: 23 },
      { type: "card_number", value: "4111 1111 1111 1111", masked: "[CARD_NUMBER]", action: "block", timestamp: "00:05", start: 28, end: 47 },
    ],
  },
  {
    id: "ses_01HXKP4O5T",
    timestamp: "2026-04-18T14:19:44Z",
    channel: "voice",
    useCase: "Healthcare Intake",
    policyVersion: "hipaa-base@2.1",
    status: "clean",
    entitiesDetected: 0,
    riskLevel: "low",
    duration: "0m 52s",
    rawHash: "sha256:c1d4e7f2a8b5...",
    redactedTranscript: "What are the clinic hours on Saturday?",
    entitySpans: [],
  },
  {
    id: "ses_01HXKP5P6U",
    timestamp: "2026-04-18T13:55:22Z",
    channel: "voice",
    useCase: "HR Assistant",
    policyVersion: "gdpr-base@1.3",
    status: "flagged",
    entitiesDetected: 3,
    riskLevel: "high",
    duration: "2m 11s",
    rawHash: "sha256:d5f8a2b1c4e9...",
    redactedTranscript: "Employee [NAME] at [ADDRESS] requests salary review. Email [EMAIL].",
    entitySpans: [
      { type: "name", value: "James Okafor", masked: "[NAME]", action: "mask", timestamp: "00:06", start: 9, end: 21 },
      { type: "address", value: "14 Birch Lane, Austin TX", masked: "[ADDRESS]", action: "mask", timestamp: "00:14", start: 25, end: 49 },
      { type: "email", value: "james.okafor@corp.io", masked: "[EMAIL]", action: "mask", timestamp: "00:31", start: 72, end: 92 },
    ],
  },
  {
    id: "ses_01HXKP6Q7V",
    timestamp: "2026-04-18T13:41:09Z",
    channel: "text",
    useCase: "Customer Support",
    policyVersion: "hipaa-base@2.1",
    status: "masked",
    entitiesDetected: 1,
    riskLevel: "medium",
    duration: "0m 34s",
    rawHash: "sha256:e9a3c6d1f2b8...",
    redactedTranscript: "Please update my phone number to [PHONE].",
    entitySpans: [
      { type: "phone", value: "+1 (512) 555-0192", masked: "[PHONE]", action: "mask", timestamp: "00:08", start: 34, end: 51 },
    ],
  },
  {
    id: "ses_01HXKP7R8W",
    timestamp: "2026-04-18T13:12:33Z",
    channel: "voice",
    useCase: "Healthcare Intake",
    policyVersion: "hipaa-clinical@3.0",
    status: "masked",
    entitiesDetected: 5,
    riskLevel: "critical",
    duration: "3m 04s",
    rawHash: "sha256:f2b5d8e1a4c7...",
    redactedTranscript: "Patient [NAME], SSN [SSN], DOB [DATE], diagnosis [HEALTH_CONTEXT], provider [NAME].",
    entitySpans: [
      { type: "name", value: "Priya Sharma", masked: "[NAME]", action: "mask", timestamp: "00:03", start: 8, end: 20 },
      { type: "ssn", value: "319-44-8821", masked: "[SSN]", action: "redact", timestamp: "00:08", start: 26, end: 37 },
      { type: "date_of_birth", value: "1991-07-29", masked: "[DATE]", action: "mask", timestamp: "00:12", start: 43, end: 53 },
      { type: "health_context", value: "Type 2 diabetes, hypertension", masked: "[HEALTH_CONTEXT]", action: "allow", timestamp: "00:19", start: 66, end: 95 },
      { type: "name", value: "Dr. Anand Mehta", masked: "[NAME]", action: "mask", timestamp: "00:28", start: 106, end: 121 },
    ],
  },
];

// ── Policies ──────────────────────────────────────────────────────────────────
export type PolicyStatus = "active" | "draft" | "archived";
export type Framework = "HIPAA" | "GDPR" | "PCI" | "Custom";

export interface Policy {
  id: string;
  name: string;
  framework: Framework;
  scope: string;
  version: string;
  status: PolicyStatus;
  updatedAt: string;
  rules: PolicyRule[];
}

export interface PolicyRule {
  entity: string;
  action: "mask" | "redact" | "tokenize" | "allow" | "block";
  rehydration: boolean;
}

export const POLICIES: Policy[] = [
  {
    id: "pol_hipaa_base",
    name: "HIPAA Base",
    framework: "HIPAA",
    scope: "voice, text",
    version: "2.1",
    status: "active",
    updatedAt: "2026-04-15",
    rules: [
      { entity: "name", action: "mask", rehydration: false },
      { entity: "ssn", action: "redact", rehydration: false },
      { entity: "insurance_id", action: "tokenize", rehydration: true },
      { entity: "date_of_birth", action: "mask", rehydration: false },
      { entity: "health_context", action: "allow", rehydration: false },
    ],
  },
  {
    id: "pol_hipaa_clinical",
    name: "HIPAA Clinical",
    framework: "HIPAA",
    scope: "voice",
    version: "3.0",
    status: "active",
    updatedAt: "2026-04-10",
    rules: [
      { entity: "name", action: "mask", rehydration: false },
      { entity: "ssn", action: "redact", rehydration: false },
      { entity: "insurance_id", action: "tokenize", rehydration: true },
      { entity: "health_context", action: "allow", rehydration: false },
      { entity: "provider_name", action: "mask", rehydration: false },
    ],
  },
  {
    id: "pol_gdpr_base",
    name: "GDPR Base",
    framework: "GDPR",
    scope: "text",
    version: "1.3",
    status: "active",
    updatedAt: "2026-04-08",
    rules: [
      { entity: "name", action: "mask", rehydration: false },
      { entity: "email", action: "mask", rehydration: false },
      { entity: "address", action: "mask", rehydration: false },
      { entity: "phone", action: "mask", rehydration: false },
    ],
  },
  {
    id: "pol_pci_strict",
    name: "PCI Strict",
    framework: "PCI",
    scope: "text",
    version: "1.0",
    status: "active",
    updatedAt: "2026-04-01",
    rules: [
      { entity: "card_number", action: "block", rehydration: false },
      { entity: "ssn", action: "block", rehydration: false },
      { entity: "cvv", action: "block", rehydration: false },
    ],
  },
  {
    id: "pol_hr_draft",
    name: "HR Assistant v2",
    framework: "GDPR",
    scope: "voice, text",
    version: "0.2",
    status: "draft",
    updatedAt: "2026-04-18",
    rules: [
      { entity: "name", action: "mask", rehydration: false },
      { entity: "salary", action: "redact", rehydration: false },
      { entity: "email", action: "mask", rehydration: false },
    ],
  },
];

// ── Audit Reports ─────────────────────────────────────────────────────────────
export type ReportStatus = "ready" | "generating" | "scheduled";

export interface AuditReport {
  id: string;
  name: string;
  useCase: string;
  dateRange: string;
  generatedAt: string;
  generatedBy: string;
  status: ReportStatus;
  sessionCount: number;
  formats: string[];
}

export const AUDIT_REPORTS: AuditReport[] = [
  {
    id: "rpt_01HXKR1A",
    name: "HIPAA Readiness — Q1 2026",
    useCase: "Healthcare Intake",
    dateRange: "Jan 1 – Mar 31, 2026",
    generatedAt: "2026-04-01T09:00:00Z",
    generatedBy: "admin@acme.io",
    status: "ready",
    sessionCount: 1842,
    formats: ["PDF", "JSON", "CSV"],
  },
  {
    id: "rpt_01HXKR2B",
    name: "GDPR Masking Audit — Apr 2026",
    useCase: "HR Assistant",
    dateRange: "Apr 1 – Apr 18, 2026",
    generatedAt: "2026-04-18T08:30:00Z",
    generatedBy: "compliance@acme.io",
    status: "ready",
    sessionCount: 312,
    formats: ["PDF", "CSV"],
  },
  {
    id: "rpt_01HXKR3C",
    name: "Voice Redaction Evidence — Mar 2026",
    useCase: "Healthcare Intake",
    dateRange: "Mar 1 – Mar 31, 2026",
    generatedAt: "2026-04-02T11:15:00Z",
    generatedBy: "admin@acme.io",
    status: "ready",
    sessionCount: 621,
    formats: ["PDF", "JSON"],
  },
  {
    id: "rpt_01HXKR4D",
    name: "Key Access & Rotation Summary",
    useCase: "All",
    dateRange: "Jan 1 – Apr 18, 2026",
    generatedAt: "2026-04-18T07:00:00Z",
    generatedBy: "system",
    status: "generating",
    sessionCount: 0,
    formats: ["PDF", "JSON"],
  },
];

// ── KMS Keys ──────────────────────────────────────────────────────────────────
export type KeyStatus = "active" | "rotating" | "disabled";

export interface KmsKey {
  id: string;
  alias: string;
  scope: string;
  region: string;
  created: string;
  rotationCadence: string;
  lastRotated: string;
  status: KeyStatus;
}

export const KMS_KEYS: KmsKey[] = [
  {
    id: "kek_01HXKS1A",
    alias: "masker/workspace/acme",
    scope: "Workspace KEK",
    region: "us-east-1",
    created: "2026-01-10",
    rotationCadence: "90 days",
    lastRotated: "2026-04-10",
    status: "active",
  },
  {
    id: "kek_01HXKS2B",
    alias: "masker/usecase/healthcare",
    scope: "Healthcare Intake DEK",
    region: "us-east-1",
    created: "2026-01-10",
    rotationCadence: "30 days",
    lastRotated: "2026-04-01",
    status: "active",
  },
  {
    id: "kek_01HXKS3C",
    alias: "masker/usecase/hr",
    scope: "HR Assistant DEK",
    region: "us-east-1",
    created: "2026-02-14",
    rotationCadence: "90 days",
    lastRotated: "2026-02-14",
    status: "rotating",
  },
  {
    id: "kek_01HXKS4D",
    alias: "masker/usecase/finance",
    scope: "Financial Advisory DEK",
    region: "eu-west-1",
    created: "2026-03-01",
    rotationCadence: "30 days",
    lastRotated: "2026-04-01",
    status: "active",
  },
  {
    id: "kek_01HXKS5E",
    alias: "masker/legacy/v1",
    scope: "Legacy Workspace KEK",
    region: "us-east-1",
    created: "2025-09-01",
    rotationCadence: "—",
    lastRotated: "2025-12-01",
    status: "disabled",
  },
];

// ── API Keys ──────────────────────────────────────────────────────────────────
export type ApiKeyStatus = "active" | "revoked";

export interface ApiKey {
  id: string;
  label: string;
  prefix: string;
  permissions: string[];
  environment: string;
  lastUsed: string;
  status: ApiKeyStatus;
  createdAt: string;
}

export const API_KEYS: ApiKey[] = [
  {
    id: "key_01HXKT1A",
    label: "Production SDK",
    prefix: "msk_live_k9Xp",
    permissions: ["read:sessions", "write:events", "use:tokenization"],
    environment: "Production",
    lastUsed: "2026-04-18T14:31:00Z",
    status: "active",
    createdAt: "2026-01-15",
  },
  {
    id: "key_01HXKT2B",
    label: "Staging Integration",
    prefix: "msk_test_r2Wq",
    permissions: ["read:sessions", "write:events"],
    environment: "Staging",
    lastUsed: "2026-04-17T10:12:00Z",
    status: "active",
    createdAt: "2026-02-01",
  },
  {
    id: "key_01HXKT3C",
    label: "Audit Service",
    prefix: "msk_live_a7Yz",
    permissions: ["read:sessions", "generate:reports"],
    environment: "Production",
    lastUsed: "2026-04-18T08:00:00Z",
    status: "active",
    createdAt: "2026-02-20",
  },
  {
    id: "key_01HXKT4D",
    label: "Dev Local",
    prefix: "msk_test_d1Lm",
    permissions: ["read:sessions"],
    environment: "Development",
    lastUsed: "2026-04-16T16:44:00Z",
    status: "active",
    createdAt: "2026-03-10",
  },
  {
    id: "key_01HXKT5E",
    label: "Old CI Key",
    prefix: "msk_test_c3Np",
    permissions: ["read:sessions", "write:events"],
    environment: "Staging",
    lastUsed: "2026-03-01T09:00:00Z",
    status: "revoked",
    createdAt: "2025-12-01",
  },
];

// ── Overview metrics ──────────────────────────────────────────────────────────
export const OVERVIEW_METRICS = {
  activePolicies: 4,
  protectedSessionsToday: 284,
  entitiesMaskedToday: 1_203,
  failedRedactions: 2,
  auditReadinessScore: 94,
  kmsHealth: "Healthy",
};

export const SESSION_VOLUME = [
  { date: "Apr 12", sessions: 198 },
  { date: "Apr 13", sessions: 221 },
  { date: "Apr 14", sessions: 175 },
  { date: "Apr 15", sessions: 310 },
  { date: "Apr 16", sessions: 267 },
  { date: "Apr 17", sessions: 244 },
  { date: "Apr 18", sessions: 284 },
];

export const TOP_ENTITY_TYPES = [
  { type: "name", count: 512 },
  { type: "health_context", count: 388 },
  { type: "insurance_id", count: 201 },
  { type: "ssn", count: 88 },
  { type: "email", count: 74 },
  { type: "phone", count: 61 },
];

export const RECENT_INCIDENTS = [
  { id: "ses_01HXKP3N4S", summary: "SSN + card number blocked — Financial Advisory", time: "14:28", risk: "critical" as RiskLevel },
  { id: "ses_01HXKP5P6U", summary: "3 GDPR entities flagged — HR Assistant", time: "13:55", risk: "high" as RiskLevel },
  { id: "ses_01HXKP7R8W", summary: "5 HIPAA entities in clinical session", time: "13:12", risk: "critical" as RiskLevel },
];
