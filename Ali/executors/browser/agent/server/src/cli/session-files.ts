/**
 * Session Files Module
 *
 * Manages file-based session storage for the CLI.
 * Sessions are stored as JSON files in ~/.hanzi-browse/sessions/
 */

import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync, appendFileSync, unlinkSync, renameSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

// Session directory
const SESSION_DIR = join(homedir(), '.hanzi-browse', 'sessions');

export interface SessionFileStatus {
  session_id: string;
  status: 'starting' | 'running' | 'complete' | 'error' | 'stopped' | 'awaiting_confirmation';
  task: string;
  url?: string;
  context?: string;
  started_at: string;
  updated_at: string;
  result?: string;
  error?: string;
}

export function ensureSessionDir(): void {
  mkdirSync(SESSION_DIR, { recursive: true });
}

export function getSessionFilePath(sessionId: string): string {
  return join(SESSION_DIR, `${sessionId}.json`);
}

export function getSessionLogPath(sessionId: string): string {
  return join(SESSION_DIR, `${sessionId}.log`);
}

export function getSessionScreenshotPath(sessionId: string): string {
  return join(SESSION_DIR, `${sessionId}.png`);
}

export function writeSessionStatus(sessionId: string, status: Partial<SessionFileStatus>): void {
  ensureSessionDir();

  const filePath = getSessionFilePath(sessionId);
  let current: SessionFileStatus;

  if (existsSync(filePath)) {
    try {
      current = JSON.parse(readFileSync(filePath, 'utf-8'));
    } catch {
      current = createInitialStatus(sessionId);
    }
  } else {
    current = createInitialStatus(sessionId);
  }

  const updated: SessionFileStatus = {
    ...current,
    ...status,
    updated_at: new Date().toISOString(),
  };

  // Atomic write: write to .tmp + rename. rename(2) on the same filesystem is atomic;
  // readers see either the old file or the new one — never a torn partial write.
  const tmpPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(tmpPath, JSON.stringify(updated, null, 2));
  renameSync(tmpPath, filePath);
}

function createInitialStatus(sessionId: string): SessionFileStatus {
  const now = new Date().toISOString();
  return {
    session_id: sessionId,
    status: 'starting',
    task: '',
    started_at: now,
    updated_at: now,
  };
}

export function readSessionStatus(sessionId: string): SessionFileStatus | null {
  const filePath = getSessionFilePath(sessionId);

  if (!existsSync(filePath)) {
    return null;
  }

  try {
    return JSON.parse(readFileSync(filePath, 'utf-8'));
  } catch (err: any) {
    console.error(`[Session] Failed to parse ${sessionId}.json:`, err.message);
    return null;
  }
}

export function appendSessionLog(sessionId: string, message: string): void {
  ensureSessionDir();
  const logPath = getSessionLogPath(sessionId);
  const timestamp = new Date().toISOString();
  appendFileSync(logPath, `[${timestamp}] ${message}\n`);
}

export function readSessionLog(sessionId: string, lines?: number): string {
  const logPath = getSessionLogPath(sessionId);

  if (!existsSync(logPath)) {
    return '';
  }

  const content = readFileSync(logPath, 'utf-8');

  if (lines) {
    const allLines = content.split('\n');
    return allLines.slice(-lines).join('\n');
  }

  return content;
}

export function listSessions(): SessionFileStatus[] {
  ensureSessionDir();

  const files = readdirSync(SESSION_DIR).filter(f => f.endsWith('.json'));
  const sessions: SessionFileStatus[] = [];

  for (const file of files) {
    const sessionId = file.replace('.json', '');
    const status = readSessionStatus(sessionId);
    if (status) {
      sessions.push(status);
    }
  }

  sessions.sort((a, b) => new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime());

  return sessions;
}

export function listActiveSessions(): SessionFileStatus[] {
  return listSessions().filter(s =>
    s.status === 'starting' ||
    s.status === 'running'
  );
}

export const SESSION_TTL_MS = Number(process.env.HANZI_SESSION_TTL_MS) || 7 * 24 * 3600_000; // 7 days

export function pruneOldSessions(): string[] {
  ensureSessionDir();
  const cutoff = Date.now() - SESSION_TTL_MS;
  const removed: string[] = [];
  for (const f of readdirSync(SESSION_DIR)) {
    if (!f.endsWith('.json')) continue;
    const sessionId = f.replace(/\.json$/, '');
    const s = readSessionStatus(sessionId);
    if (!s) continue;
    // Only prune terminal states
    if (s.status !== 'complete' && s.status !== 'error' && s.status !== 'stopped') continue;
    if (new Date(s.updated_at).getTime() < cutoff) {
      deleteSessionFiles(sessionId);
      removed.push(sessionId);
    }
  }
  return removed;
}

export function deleteSessionFiles(sessionId: string): boolean {
  const statusPath = getSessionFilePath(sessionId);
  const logPath = getSessionLogPath(sessionId);

  let deleted = false;

  if (existsSync(statusPath)) {
    unlinkSync(statusPath);
    deleted = true;
  }

  if (existsSync(logPath)) {
    unlinkSync(logPath);
    deleted = true;
  }

  return deleted;
}
