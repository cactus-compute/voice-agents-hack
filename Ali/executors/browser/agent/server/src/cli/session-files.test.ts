import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { writeFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { writeSessionStatus, readSessionStatus, deleteSessionFiles, pruneOldSessions, SESSION_TTL_MS } from './session-files.js';

describe('session-files atomic writes', () => {
  const sid = 'test-atomic';
  beforeEach(() => deleteSessionFiles(sid));
  afterEach(() => deleteSessionFiles(sid));

  it('handles 100 concurrent partial writes without corrupting JSON', async () => {
    const writes = Array.from({ length: 100 }, (_, i) =>
      Promise.resolve().then(() => writeSessionStatus(sid, { status: 'running', task: `task ${i}` })),
    );
    await Promise.all(writes);
    const final = readSessionStatus(sid);
    expect(final).not.toBeNull();
    expect(final!.status).toBe('running');
    expect(final!.task).toMatch(/^task \d+$/);
  });
});

describe('session pruning', () => {
  it('removes sessions older than TTL, keeps recent ones', () => {
    const dir = join(homedir(), '.hanzi-browse', 'sessions');
    // Pre-clean so test is deterministic
    try { require('fs').unlinkSync(join(dir, 'old-ttl.json')); } catch {}
    try { require('fs').unlinkSync(join(dir, 'fresh-ttl.json')); } catch {}

    writeFileSync(join(dir, 'old-ttl.json'), JSON.stringify({
      session_id: 'old-ttl', status: 'complete', task: 'x',
      started_at: new Date(Date.now() - 30 * 24 * 3600_000).toISOString(),
      updated_at: new Date(Date.now() - 30 * 24 * 3600_000).toISOString(),
    }));
    writeFileSync(join(dir, 'fresh-ttl.json'), JSON.stringify({
      session_id: 'fresh-ttl', status: 'complete', task: 'x',
      started_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }));

    const pruned = pruneOldSessions();
    expect(pruned).toContain('old-ttl');
    expect(pruned).not.toContain('fresh-ttl');
  });
});
