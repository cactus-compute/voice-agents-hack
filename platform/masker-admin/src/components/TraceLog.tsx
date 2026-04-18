import type { TraceEvent } from '../types';

const STAGE_COLORS: Record<TraceEvent['stage'], string> = {
  detection: '#818cf8',
  policy:    '#f59e0b',
  masking:   '#f87171',
  routing:   '#22c55e',
};

const STAGE_ICONS: Record<TraceEvent['stage'], string> = {
  detection: '🔍',
  policy:    '📋',
  masking:   '🔒',
  routing:   '→',
};

interface Props {
  events: TraceEvent[];
}

export function TraceLog({ events }: Props) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      {events.map((ev, i) => {
        const color = STAGE_COLORS[ev.stage];
        return (
          <div
            key={i}
            style={{
              display: 'flex',
              alignItems: 'flex-start',
              gap: 10,
              fontFamily: 'monospace',
              fontSize: '0.82rem',
              lineHeight: 1.5,
            }}
          >
            <span style={{ color: '#475569', userSelect: 'none' }}>
              {String(i + 1).padStart(2, '0')}
            </span>
            <span style={{ minWidth: 20, textAlign: 'center' }}>
              {STAGE_ICONS[ev.stage]}
            </span>
            <span
              style={{
                color,
                textTransform: 'uppercase',
                fontSize: '0.7rem',
                fontWeight: 700,
                letterSpacing: '0.06em',
                minWidth: 72,
                paddingTop: 2,
              }}
            >
              {ev.stage}
            </span>
            <span style={{ color: '#cbd5e1' }}>{ev.message}</span>
          </div>
        );
      })}
    </div>
  );
}
