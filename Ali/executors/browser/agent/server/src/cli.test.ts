import { describe, it, expect } from 'vitest';
import { handleRelayMessage } from './cli.js';

describe('CLI: task_awaiting_confirmation handling', () => {
  it('prints the summary and reads stdin for a response', async () => {
    const stderrLines: string[] = [];
    const sentMessages: any[] = [];
    const fakeStderr = { write: (s: string) => { stderrLines.push(s); } };
    const fakeStdin = createFakeStdin('yes\n');
    const fakeRelay = { send: (m: any) => sentMessages.push(m) };

    await handleRelayMessage(
      {
        type: 'task_awaiting_confirmation',
        sessionId: 'sess_1',
        summary: 'About to submit YC application',
        payload: { resume: '/tmp/resume.pdf' },
      },
      { stderr: fakeStderr, stdin: fakeStdin, relay: fakeRelay }
    );

    const printed = stderrLines.join('');
    expect(printed).toMatch(/About to submit YC application/);
    expect(printed).toMatch(/\[y\]es/);

    expect(sentMessages[0]).toMatchObject({
      type: 'mcp_send_message',
      sessionId: 'sess_1',
      message: 'yes, proceed',
    });
  });
});

function createFakeStdin(data: string) {
  let offset = 0;
  return {
    async readLine(): Promise<string> {
      const nl = data.indexOf('\n', offset);
      if (nl < 0) throw new Error('no more input');
      const line = data.slice(offset, nl);
      offset = nl + 1;
      return line;
    },
  };
}
