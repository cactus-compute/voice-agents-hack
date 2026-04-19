/**
 * Lightweight flag parser for CLI subcommands.
 *
 * Spec definition: `{ flagName: 'string' | 'boolean' | 'string:<short>' | 'boolean:<short>' }`
 *
 * Returns flags plus `_` = positional args in order.
 */
export type FlagSpec = Record<string, 'string' | 'boolean' | `string:${string}` | `boolean:${string}`>;

export interface ParsedFlags {
  _: string[];
  [flag: string]: string | boolean | string[] | undefined;
}

export function parseFlags(argv: string[], spec: FlagSpec): ParsedFlags {
  const longToType = new Map<string, 'string' | 'boolean'>();
  const shortToLong = new Map<string, string>();
  for (const [name, raw] of Object.entries(spec)) {
    const [type, short] = raw.split(':') as ['string' | 'boolean', string | undefined];
    longToType.set(name, type);
    if (short) shortToLong.set(short, name);
  }

  const out: ParsedFlags = { _: [] };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    let name: string | null = null;
    let inline: string | null = null;

    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      if (eq >= 0) { name = a.slice(2, eq); inline = a.slice(eq + 1); }
      else { name = a.slice(2); }
    } else if (a.startsWith('-') && a.length === 2) {
      name = shortToLong.get(a.slice(1)) ?? null;
    }

    if (!name || !longToType.has(name)) {
      if (!a.startsWith('-')) out._.push(a);
      continue;
    }
    const type = longToType.get(name)!;
    if (type === 'boolean') {
      out[name] = true;
    } else {
      out[name] = inline ?? argv[++i];
    }
  }

  return out;
}

/** `"30s"`, `"10m"`, `"1h"`, or bare number (milliseconds). */
export function parseDuration(s: string): number {
  const m = /^(\d+)(ms|s|m|h)?$/.exec(s.trim());
  if (!m) throw new Error(`Cannot parse duration: ${s}`);
  const n = parseInt(m[1], 10);
  const u = m[2] ?? 'ms';
  switch (u) {
    case 'ms': return n;
    case 's': return n * 1000;
    case 'm': return n * 60_000;
    case 'h': return n * 3_600_000;
    default: throw new Error(`Unknown unit: ${u}`);
  }
}
