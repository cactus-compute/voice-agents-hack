import type { MaskerTrace } from '../types';
import { POLICY_LABELS, ROUTE_DESCRIPTIONS } from '../explanation';
import { RouteBadge } from './RouteBadge';
import { EntityList } from './EntityList';
import { TraceLog } from './TraceLog';

interface Props {
  trace: MaskerTrace;
}

const SECTION_STYLE: React.CSSProperties = {
  background: '#0f172a',
  border: '1px solid #1e293b',
  borderRadius: 8,
  padding: '14px 16px',
};

const LABEL_STYLE: React.CSSProperties = {
  fontSize: '0.7rem',
  fontWeight: 700,
  textTransform: 'uppercase',
  letterSpacing: '0.08em',
  color: '#475569',
  marginBottom: 8,
};

export function TracePanel({ trace }: Props) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>

      {/* Route — most prominent */}
      <div
        style={{
          ...SECTION_STYLE,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 16,
        }}
      >
        <div>
          <div style={LABEL_STYLE}>Decision</div>
          <RouteBadge route={trace.route} size="lg" />
        </div>
        <div style={{ flex: 1, fontSize: '0.88rem', color: '#94a3b8', lineHeight: 1.5 }}>
          {ROUTE_DESCRIPTIONS[trace.route]}
        </div>
      </div>

      {/* Transcript */}
      <div style={SECTION_STYLE}>
        <div style={LABEL_STYLE}>Transcript</div>
        <div
          style={{
            fontFamily: 'monospace',
            fontSize: '0.95rem',
            color: '#e2e8f0',
            lineHeight: 1.6,
          }}
        >
          "{trace.transcript}"
        </div>
      </div>

      {/* Detected entities */}
      <div style={SECTION_STYLE}>
        <div style={LABEL_STYLE}>
          Detected Entities ({trace.entities.length})
        </div>
        <EntityList entities={trace.entities} />
      </div>

      {/* Policy */}
      <div style={SECTION_STYLE}>
        <div style={LABEL_STYLE}>Policy Applied</div>
        <div style={{ fontSize: '0.88rem', color: '#f59e0b', fontWeight: 600 }}>
          {POLICY_LABELS[trace.policy]}
        </div>
      </div>

      {/* Masked transcript — only when applicable */}
      {trace.maskedTranscript && (
        <div style={SECTION_STYLE}>
          <div style={LABEL_STYLE}>Masked Transcript (sent to Gemma)</div>
          <div
            style={{
              fontFamily: 'monospace',
              fontSize: '0.95rem',
              color: '#86efac',
              lineHeight: 1.6,
            }}
          >
            "{trace.maskedTranscript}"
          </div>
        </div>
      )}

      {/* Explanation */}
      <div
        style={{
          ...SECTION_STYLE,
          borderColor: '#1e3a5f',
          background: '#0c1a2e',
        }}
      >
        <div style={LABEL_STYLE}>Explanation</div>
        <div style={{ fontSize: '0.9rem', color: '#93c5fd', lineHeight: 1.65 }}>
          {trace.explanation}
        </div>
      </div>

      {/* Trace log */}
      <div style={SECTION_STYLE}>
        <div style={LABEL_STYLE}>Trace Log</div>
        <TraceLog events={trace.traceEvents} />
      </div>

    </div>
  );
}
