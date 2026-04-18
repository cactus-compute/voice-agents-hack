import type { Route } from '../types';
import { ROUTE_LABELS, ROUTE_COLORS } from '../explanation';

interface Props {
  route: Route;
  size?: 'sm' | 'lg';
}

export function RouteBadge({ route, size = 'sm' }: Props) {
  const color = ROUTE_COLORS[route];
  const fontSize = size === 'lg' ? '1rem' : '0.75rem';
  const padding = size === 'lg' ? '6px 14px' : '3px 10px';

  return (
    <span
      style={{
        display: 'inline-block',
        background: color + '22',
        color,
        border: `1px solid ${color}55`,
        borderRadius: 4,
        fontFamily: 'monospace',
        fontWeight: 700,
        fontSize,
        padding,
        letterSpacing: '0.04em',
        textTransform: 'uppercase',
      }}
    >
      {ROUTE_LABELS[route]}
    </span>
  );
}
