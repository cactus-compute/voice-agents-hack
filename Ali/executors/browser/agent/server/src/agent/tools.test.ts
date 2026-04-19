import { describe, it, expect } from 'vitest';
import { AGENT_TOOLS } from './tools.js';

describe('computer_os tool', () => {
  it('is registered in AGENT_TOOLS', () => {
    const tool = AGENT_TOOLS.find(t => t.name === 'computer_os');
    expect(tool).toBeDefined();
  });

  it('has an action enum including the three v1 actions', () => {
    const tool = AGENT_TOOLS.find(t => t.name === 'computer_os')!;
    const actionEnum = (tool.input_schema as any).properties.action.enum;
    expect(actionEnum).toContain('drive_file_picker');
    expect(actionEnum).toContain('focus_app');
    expect(actionEnum).toContain('applescript');
  });

  it('declares path, app, and script as optional string inputs', () => {
    const tool = AGENT_TOOLS.find(t => t.name === 'computer_os')!;
    const props = (tool.input_schema as any).properties;
    expect(props.path.type).toBe('string');
    expect(props.app.type).toBe('string');
    expect(props.script.type).toBe('string');
  });
});

describe('await_confirmation tool', () => {
  it('is registered in AGENT_TOOLS', () => {
    const tool = AGENT_TOOLS.find(t => t.name === 'await_confirmation');
    expect(tool).toBeDefined();
  });

  it('requires a summary string', () => {
    const tool = AGENT_TOOLS.find(t => t.name === 'await_confirmation')!;
    const schema = tool.input_schema as any;
    expect(schema.required).toContain('summary');
    expect(schema.properties.summary.type).toBe('string');
  });

  it('accepts an optional payload object', () => {
    const tool = AGENT_TOOLS.find(t => t.name === 'await_confirmation')!;
    const schema = tool.input_schema as any;
    expect(schema.properties.payload.type).toBe('object');
    expect(schema.required).not.toContain('payload');
  });
});
