import { describe, it, expect } from 'vitest';
import { parseFlags, parseDuration } from './arg-parser.js';

describe('parseFlags', () => {
  it('parses string flags with --key value and --key=value', () => {
    const f = parseFlags(['--url', 'https://a.com', '--context=hi'], { url: 'string', context: 'string' });
    expect(f.url).toBe('https://a.com');
    expect(f.context).toBe('hi');
  });

  it('parses boolean flags', () => {
    const f = parseFlags(['--json', '--quiet'], { json: 'boolean', quiet: 'boolean' });
    expect(f.json).toBe(true);
    expect(f.quiet).toBe(true);
  });

  it('short aliases', () => {
    const f = parseFlags(['-u', 'https://a.com', '-f'], { url: 'string:u', follow: 'boolean:f' });
    expect(f.url).toBe('https://a.com');
    expect(f.follow).toBe(true);
  });

  it('unknown flags are ignored, positionals returned', () => {
    const f = parseFlags(['start', 'task text', '--url', 'https://a.com'], { url: 'string' });
    expect(f._).toEqual(['start', 'task text']);
    expect(f.url).toBe('https://a.com');
  });
});

describe('parseDuration', () => {
  it('parses s/m/h suffixes to milliseconds', () => {
    expect(parseDuration('30s')).toBe(30_000);
    expect(parseDuration('10m')).toBe(600_000);
    expect(parseDuration('1h')).toBe(3_600_000);
    expect(parseDuration('500')).toBe(500); // bare ms
  });

  it('throws on unparseable input', () => {
    expect(() => parseDuration('ten seconds')).toThrow();
  });
});
