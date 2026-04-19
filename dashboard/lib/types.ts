export type RiskLevel = "low" | "medium" | "high" | "critical";
export type SessionStatus = "clean" | "masked" | "blocked" | "flagged";
export type Channel = "voice" | "text";
export type PolicyStatus = "active" | "draft" | "archived";
export type Framework = "HIPAA" | "GDPR" | "PCI" | "Custom";
export type ReportStatus = "ready" | "generating" | "scheduled";
export type KeyStatus = "active" | "rotating" | "disabled";
export type ApiKeyStatus = "active" | "revoked";

export interface EntitySpan {
  type: string;
  value: string;
  masked: string;
  action: string;
  timestamp: string;
  start: number;
  end: number;
}

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

export interface PolicyRule {
  entity: string;
  action: "mask" | "redact" | "tokenize" | "allow" | "block";
  rehydration: boolean;
}

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

export interface OverviewMetrics {
  activePolicies: number;
  protectedSessionsToday: number;
  entitiesMaskedToday: number;
  failedRedactions: number;
  auditReadinessScore: number;
  kmsHealth: string;
}

export interface OverviewResponse {
  metrics: OverviewMetrics;
  sessionVolume: { date: string; sessions: number }[];
  topEntityTypes: { type: string; count: number }[];
  recentIncidents: { id: string; summary: string; time: string; risk: RiskLevel }[];
}
