import type { Route, Policy, EntityType } from './types';

export const ROUTE_LABELS: Record<Route, string> = {
  'local-only':    'Local Only',
  'masked-send':   'Masked Send',
  'safe-to-send':  'Safe to Send',
};

export const ROUTE_COLORS: Record<Route, string> = {
  'local-only':   '#ef4444',   // red
  'masked-send':  '#f59e0b',   // amber
  'safe-to-send': '#22c55e',   // green
};

export const ROUTE_DESCRIPTIONS: Record<Route, string> = {
  'local-only':
    'Sensitive health data detected. Request handled entirely on-device — nothing leaves.',
  'masked-send':
    'Identifiers masked before forwarding. The model receives context without raw PII.',
  'safe-to-send':
    'No sensitive data found. Request forwarded as-is.',
};

export const POLICY_LABELS: Record<Policy, string> = {
  hipaa_base:     'HIPAA Base',
  hipaa_logging:  'HIPAA Logging (Strict)',
  hipaa_clinical: 'HIPAA Clinical',
  none:           'No Policy',
};

export const ENTITY_LABELS: Record<EntityType, string> = {
  ssn:            'Social Security Number',
  phone:          'Phone Number',
  email:          'Email Address',
  name:           'Name',
  insurance_id:   'Insurance ID',
  address:        'Address',
  health_context: 'Health Context',
  work_context:   'Work Context',
};

export const ENTITY_RISK: Record<EntityType, 'high' | 'medium' | 'low'> = {
  ssn:            'high',
  insurance_id:   'high',
  health_context: 'high',
  name:           'medium',
  phone:          'medium',
  email:          'medium',
  address:        'medium',
  work_context:   'low',
};

export const RISK_COLORS: Record<'high' | 'medium' | 'low', string> = {
  high:   '#ef4444',
  medium: '#f59e0b',
  low:    '#3b82f6',
};
