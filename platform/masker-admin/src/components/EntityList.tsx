import type { DetectedEntity } from '../types';
import { ENTITY_LABELS, ENTITY_RISK, RISK_COLORS } from '../explanation';

interface Props {
  entities: DetectedEntity[];
}

export function EntityList({ entities }: Props) {
  if (entities.length === 0) {
    return (
      <div style={{ color: '#22c55e', fontSize: '0.85rem', fontStyle: 'italic' }}>
        No sensitive entities detected
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      {entities.map((e, i) => {
        const risk = ENTITY_RISK[e.type];
        const color = RISK_COLORS[risk];
        return (
          <div
            key={i}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              background: '#1e1e2e',
              borderRadius: 6,
              padding: '6px 10px',
              borderLeft: `3px solid ${color}`,
            }}
          >
            <span
              style={{
                fontSize: '0.7rem',
                fontWeight: 700,
                color,
                textTransform: 'uppercase',
                letterSpacing: '0.06em',
                minWidth: 90,
              }}
            >
              {risk} risk
            </span>
            <span style={{ fontSize: '0.8rem', color: '#94a3b8', minWidth: 130 }}>
              {ENTITY_LABELS[e.type]}
            </span>
            <span
              style={{
                fontFamily: 'monospace',
                fontSize: '0.85rem',
                color: '#e2e8f0',
                flex: 1,
              }}
            >
              <span style={{ color: '#f87171' }}>{e.value}</span>
              <span style={{ color: '#475569', margin: '0 8px' }}>→</span>
              <span style={{ color: '#86efac' }}>{e.masked}</span>
            </span>
          </div>
        );
      })}
    </div>
  );
}
