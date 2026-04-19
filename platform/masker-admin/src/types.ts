export type Route = 'local-only' | 'masked-send' | 'safe-to-send';
export type Policy = 'hipaa_base' | 'hipaa_logging' | 'hipaa_clinical' | 'none';
export type EntityType =
  | 'ssn'
  | 'phone'
  | 'email'
  | 'name'
  | 'insurance_id'
  | 'address'
  | 'health_context'
  | 'work_context';

export interface DetectedEntity {
  type: EntityType;
  value: string;
  masked: string;
}

export interface TraceEvent {
  stage: 'detection' | 'policy' | 'masking' | 'routing';
  message: string;
}

export interface MaskerTrace {
  id: string;
  label: string;
  transcript: string;
  entities: DetectedEntity[];
  policy: Policy;
  route: Route;
  maskedTranscript: string | null;
  explanation: string;
  traceEvents: TraceEvent[];
}
