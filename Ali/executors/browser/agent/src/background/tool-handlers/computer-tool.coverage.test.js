/**
 * Code coverage test for computer-tool.js
 * This file imports the ACTUAL source and measures coverage
 *
 * Run with: npx c8 node src/background/tool-handlers/computer-tool.coverage.test.js
 */

// ============================================================================
// MOCK CHROME APIS (must be done before import)
// ============================================================================

const cdpCommands = [];

globalThis.chrome = {
  scripting: {
    executeScript: async ({ target: _target, func }) => {
      const funcStr = func.toString();
      if (funcStr.includes('pageXOffset')) {
        return [{ result: { x: 0, y: 100 } }];
      }
      if (funcStr.includes('innerWidth') && funcStr.includes('innerHeight') && !funcStr.includes('devicePixelRatio')) {
        return [{ result: { width: 1920, height: 1080 } }];
      }
      if (funcStr.includes('viewportWidth') || funcStr.includes('devicePixelRatio')) {
        return [{ result: { viewportWidth: 1920, viewportHeight: 1080, devicePixelRatio: 2 } }];
      }
      return [{ result: {} }];
    },
  },
  tabs: {
    get: async (tabId) => ({ id: tabId, active: true }),
    reload: async (tabId, options) => {
      cdpCommands.push({ type: 'tabs.reload', tabId, options });
    },
  },
};

// ============================================================================
// MOCK MODULE DEPENDENCIES
// ============================================================================

// We need to mock the imports that computer-tool.js uses
// Since ES modules are tricky to mock, we'll create a wrapper

// createRequire unused — kept for potential future dynamic imports
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { readFileSync } from 'fs';
import vm from 'vm';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Read the source file
const sourceCode = readFileSync(join(__dirname, 'computer-tool.js'), 'utf-8');

// Create mock functions for keys.js
const mockGetKeyCode = (key) => {
  const codes = {
    'Enter': { key: 'Enter', code: 'Enter', keyCode: 13 },
    'a': { key: 'a', code: 'KeyA', keyCode: 65, text: 'a' },
    'A': { key: 'A', code: 'KeyA', keyCode: 65, text: 'A' },
    'Backspace': { key: 'Backspace', code: 'Backspace', keyCode: 8 },
    'Tab': { key: 'Tab', code: 'Tab', keyCode: 9 },
  };
  return codes[key];
};

const mockRequiresShift = (char) => char >= 'A' && char <= 'Z';

const mockPressKey = async (tabId, keyDef, modifiers) => {
  cdpCommands.push({ type: 'pressKey', tabId, keyDef, modifiers });
};

const mockPressKeyChord = async (tabId, chord) => {
  cdpCommands.push({ type: 'pressKeyChord', tabId, chord });
};

// Transform ES module imports to use our mocks
const transformedCode = sourceCode
  .replace(/import \{ getKeyCode, requiresShift, pressKey, pressKeyChord \} from '\.\.\/modules\/keys\.js';/,
    `const getKeyCode = globalThis.__mocks.getKeyCode;
const requiresShift = globalThis.__mocks.requiresShift;
const pressKey = globalThis.__mocks.pressKey;
const pressKeyChord = globalThis.__mocks.pressKeyChord;`)
  .replace(/import \{ DELAYS \} from '\.\.\/modules\/constants\.js';/,
    `const DELAYS = { RETRY: 200 };`)
  .replace(/export async function handleComputer/, 'globalThis.__handleComputer = async function handleComputer');

// Set up mocks
globalThis.__mocks = {
  getKeyCode: mockGetKeyCode,
  requiresShift: mockRequiresShift,
  pressKey: mockPressKey,
  pressKeyChord: mockPressKeyChord,
};

// Execute the transformed code
const script = new vm.Script(transformedCode, { filename: 'computer-tool.js' });
script.runInThisContext();

const handleComputer = globalThis.__handleComputer;

// ============================================================================
// TEST HELPERS
// ============================================================================

function createMockDeps(overrides = {}) {
  cdpCommands.length = 0;

  return {
    sendDebuggerCommand: async (tabId, method, params) => {
      cdpCommands.push({ tabId, method, params });
      if (method === 'Page.captureScreenshot') {
        return { data: 'base64mockdata' };
      }
      return {};
    },
    ensureDebugger: async (_tabId) => {},
    log: async (_level, _msg, _data) => {},
    sendToContent: async (_tabId, action, _data) => {
      if (action === 'GET_ELEMENT_RECT') {
        if (overrides.elementNotFound) {
          return { success: false, error: 'Element not found' };
        }
        return { success: true, coordinates: [500, 300], rect: { centerX: 500, centerY: 300 } };
      }
      if (action === 'SCROLL_TO_ELEMENT') {
        if (overrides.scrollToFailed) {
          return { success: false, error: 'Element not found' };
        }
        return { success: true };
      }
      if (action === 'FIND_AND_SCROLL') {
        return { success: true, containerType: 'div' };
      }
      return { success: true };
    },
    hideIndicatorsForToolUse: async (_tabId) => {},
    showIndicatorsAfterToolUse: async (_tabId) => {},
    screenshotCounter: { value: 0 },
    capturedScreenshots: new Map(),
    screenshotContexts: new Map(),
    taskScreenshots: [],
    agentOpenedTabs: new Set(),
    ...overrides,
  };
}

let passed = 0, failed = 0;

async function test(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failed++;
    console.log(`  ✗ ${name}`);
    console.log(`    ${e.message}`);
  }
}

// ============================================================================
// COMPREHENSIVE TESTS FOR 100% COVERAGE
// ============================================================================

async function runCoverageTests() {
  console.log('Coverage Tests for computer-tool.js\n====================================\n');

  // --- SCREENSHOT ---
  console.log('screenshot:');
  await test('happy path', async () => {
    const deps = createMockDeps();
    const result = await handleComputer({ action: 'screenshot', tabId: 1 }, deps);
    if (!result.output?.includes('Successfully captured')) throw new Error('Wrong output');
  });

  await test('error path', async () => {
    const deps = createMockDeps({
      sendDebuggerCommand: async () => { throw new Error('CDP error'); }
    });
    const result = await handleComputer({ action: 'screenshot', tabId: 1 }, deps);
    if (!result.error) throw new Error('Should have error');
  });

  // --- ZOOM ---
  console.log('\nzoom:');
  await test('missing region', async () => {
    try {
      await handleComputer({ action: 'zoom', tabId: 1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Region parameter')) throw e;
    }
  });

  await test('region wrong length', async () => {
    try {
      await handleComputer({ action: 'zoom', tabId: 1, region: [0, 0] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Region parameter')) throw e;
    }
  });

  await test('invalid x0 < 0', async () => {
    try {
      await handleComputer({ action: 'zoom', tabId: 1, region: [-1, 0, 100, 100] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Invalid region')) throw e;
    }
  });

  await test('invalid y0 < 0', async () => {
    try {
      await handleComputer({ action: 'zoom', tabId: 1, region: [0, -1, 100, 100] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Invalid region')) throw e;
    }
  });

  await test('invalid x1 <= x0', async () => {
    try {
      await handleComputer({ action: 'zoom', tabId: 1, region: [100, 0, 50, 100] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Invalid region')) throw e;
    }
  });

  await test('invalid y1 <= y0', async () => {
    try {
      await handleComputer({ action: 'zoom', tabId: 1, region: [0, 100, 100, 50] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Invalid region')) throw e;
    }
  });

  await test('with DPR context scaling', async () => {
    const deps = createMockDeps();
    deps.screenshotContexts.set('tab_1', {
      viewportWidth: 1920, viewportHeight: 1080,
      screenshotWidth: 3840, screenshotHeight: 2160
    });
    const result = await handleComputer({ action: 'zoom', tabId: 1, region: [0, 0, 100, 100] }, deps);
    if (!result.output?.includes('Successfully')) throw new Error('Wrong output');
  });

  await test('exceeds viewport', async () => {
    const result = await handleComputer({ action: 'zoom', tabId: 1, region: [0, 0, 9999, 9999] }, createMockDeps());
    if (!result.error?.includes('viewport boundaries')) throw new Error('Should have viewport error');
  });

  await test('CDP failure', async () => {
    const deps = createMockDeps({
      sendDebuggerCommand: async (t, m) => {
        if (m === 'Page.captureScreenshot') return null;
        return {};
      }
    });
    const result = await handleComputer({ action: 'zoom', tabId: 1, region: [0, 0, 100, 100] }, deps);
    if (!result.error) throw new Error('Should have error');
  });

  // --- CLICKS ---
  console.log('\nclicks:');
  await test('left_click with coordinate', async () => {
    const result = await handleComputer({ action: 'left_click', tabId: 1, coordinate: [500, 300] }, createMockDeps());
    if (!result.output?.includes('Clicked at')) throw new Error('Wrong output');
  });

  await test('left_click with ref', async () => {
    const result = await handleComputer({ action: 'left_click', tabId: 1, ref: 'ref_1' }, createMockDeps());
    if (!result.output?.includes('Clicked on element')) throw new Error('Wrong output');
  });

  await test('left_click ref not found', async () => {
    const deps = createMockDeps({ elementNotFound: true });
    const result = await handleComputer({ action: 'left_click', tabId: 1, ref: 'ref_1' }, deps);
    if (!result.error) throw new Error('Should have error');
  });

  await test('left_click with DPR scaling', async () => {
    const deps = createMockDeps();
    deps.screenshotContexts.set('tab_1', {
      viewportWidth: 1920, viewportHeight: 1080,
      screenshotWidth: 3840, screenshotHeight: 2160
    });
    await handleComputer({ action: 'left_click', tabId: 1, coordinate: [1000, 500] }, deps);
  });

  await test('left_click missing coordinate and ref', async () => {
    try {
      await handleComputer({ action: 'left_click', tabId: 1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Either ref or coordinate')) throw e;
    }
  });

  await test('right_click', async () => {
    const result = await handleComputer({ action: 'right_click', tabId: 1, coordinate: [500, 300] }, createMockDeps());
    if (!result.output) throw new Error('Wrong output');
  });

  await test('middle_click', async () => {
    const result = await handleComputer({ action: 'middle_click', tabId: 1, coordinate: [500, 300] }, createMockDeps());
    if (!result.output) throw new Error('Wrong output');
  });

  await test('double_click', async () => {
    const result = await handleComputer({ action: 'double_click', tabId: 1, coordinate: [500, 300] }, createMockDeps());
    if (!result.output?.includes('Double-clicked')) throw new Error('Wrong output');
  });

  await test('triple_click', async () => {
    const result = await handleComputer({ action: 'triple_click', tabId: 1, coordinate: [500, 300] }, createMockDeps());
    if (!result.output?.includes('Triple-clicked')) throw new Error('Wrong output');
  });

  await test('click with modifiers (all types)', async () => {
    // Test all modifier combinations
    for (const mods of ['alt', 'ctrl', 'control', 'meta', 'cmd', 'command', 'win', 'windows', 'shift', 'ctrl+shift']) {
      await handleComputer({ action: 'left_click', tabId: 1, coordinate: [500, 300], modifiers: mods }, createMockDeps());
    }
  });

  // --- HOVER ---
  console.log('\nhover:');
  await test('with coordinate', async () => {
    const result = await handleComputer({ action: 'hover', tabId: 1, coordinate: [500, 300] }, createMockDeps());
    if (!result.output?.includes('Hovered at')) throw new Error('Wrong output');
  });

  await test('with ref', async () => {
    const result = await handleComputer({ action: 'hover', tabId: 1, ref: 'ref_1' }, createMockDeps());
    if (!result.output?.includes('Hovered over element')) throw new Error('Wrong output');
  });

  await test('ref not found', async () => {
    const deps = createMockDeps({ elementNotFound: true });
    const result = await handleComputer({ action: 'hover', tabId: 1, ref: 'ref_1' }, deps);
    if (!result.error) throw new Error('Should have error');
  });

  await test('with DPR scaling', async () => {
    const deps = createMockDeps();
    deps.screenshotContexts.set('tab_1', {
      viewportWidth: 1920, viewportHeight: 1080,
      screenshotWidth: 3840, screenshotHeight: 2160
    });
    await handleComputer({ action: 'hover', tabId: 1, coordinate: [1000, 500] }, deps);
  });

  await test('missing coordinate and ref', async () => {
    try {
      await handleComputer({ action: 'hover', tabId: 1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Either ref or coordinate')) throw e;
    }
  });

  // --- DRAG ---
  console.log('\nleft_click_drag:');
  await test('happy path', async () => {
    const result = await handleComputer({
      action: 'left_click_drag', tabId: 1,
      start_coordinate: [100, 100], coordinate: [500, 500]
    }, createMockDeps());
    if (!result.output?.includes('Dragged from')) throw new Error('Wrong output');
  });

  await test('with DPR scaling', async () => {
    const deps = createMockDeps();
    deps.screenshotContexts.set('tab_1', {
      viewportWidth: 1920, viewportHeight: 1080,
      screenshotWidth: 3840, screenshotHeight: 2160
    });
    await handleComputer({
      action: 'left_click_drag', tabId: 1,
      start_coordinate: [200, 200], coordinate: [1000, 1000]
    }, deps);
  });

  await test('missing start_coordinate', async () => {
    try {
      await handleComputer({ action: 'left_click_drag', tabId: 1, coordinate: [500, 500] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('start_coordinate')) throw e;
    }
  });

  await test('start_coordinate wrong length', async () => {
    try {
      await handleComputer({ action: 'left_click_drag', tabId: 1, start_coordinate: [100], coordinate: [500, 500] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('start_coordinate')) throw e;
    }
  });

  await test('missing coordinate', async () => {
    try {
      await handleComputer({ action: 'left_click_drag', tabId: 1, start_coordinate: [100, 100] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('coordinate parameter (end position)')) throw e;
    }
  });

  await test('coordinate wrong length', async () => {
    try {
      await handleComputer({ action: 'left_click_drag', tabId: 1, start_coordinate: [100, 100], coordinate: [500] }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('coordinate parameter (end position)')) throw e;
    }
  });

  // --- TYPE ---
  console.log('\ntype:');
  await test('happy path', async () => {
    const result = await handleComputer({ action: 'type', tabId: 1, text: 'hello' }, createMockDeps());
    if (!result.output?.includes('Typed')) throw new Error('Wrong output');
  });

  await test('missing text', async () => {
    try {
      await handleComputer({ action: 'type', tabId: 1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Text parameter')) throw e;
    }
  });

  await test('with known key codes (a)', async () => {
    await handleComputer({ action: 'type', tabId: 1, text: 'a' }, createMockDeps());
  });

  await test('with uppercase (shift)', async () => {
    await handleComputer({ action: 'type', tabId: 1, text: 'A' }, createMockDeps());
  });

  await test('with newline', async () => {
    await handleComputer({ action: 'type', tabId: 1, text: '\n' }, createMockDeps());
  });

  await test('with carriage return', async () => {
    await handleComputer({ action: 'type', tabId: 1, text: '\r' }, createMockDeps());
  });

  await test('with unknown char (insertText)', async () => {
    await handleComputer({ action: 'type', tabId: 1, text: '你' }, createMockDeps());
  });

  // --- KEY ---
  console.log('\nkey:');
  await test('single key', async () => {
    const result = await handleComputer({ action: 'key', tabId: 1, text: 'Enter' }, createMockDeps());
    if (!result.output?.includes('Pressed 1 key')) throw new Error('Wrong output');
  });

  await test('multiple keys', async () => {
    const result = await handleComputer({ action: 'key', tabId: 1, text: 'Enter Tab' }, createMockDeps());
    if (!result.output?.includes('Pressed 2 keys')) throw new Error('Wrong output');
  });

  await test('with repeat', async () => {
    const result = await handleComputer({ action: 'key', tabId: 1, text: 'Enter', repeat: 3 }, createMockDeps());
    if (!result.output?.includes('repeated 3 times')) throw new Error('Wrong output');
  });

  await test('missing text', async () => {
    try {
      await handleComputer({ action: 'key', tabId: 1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Text parameter')) throw e;
    }
  });

  await test('repeat not integer', async () => {
    try {
      await handleComputer({ action: 'key', tabId: 1, text: 'Enter', repeat: 1.5 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('positive integer')) throw e;
    }
  });

  await test('repeat < 1', async () => {
    try {
      await handleComputer({ action: 'key', tabId: 1, text: 'Enter', repeat: 0 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('positive integer')) throw e;
    }
  });

  await test('repeat > 100', async () => {
    try {
      await handleComputer({ action: 'key', tabId: 1, text: 'Enter', repeat: 101 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('cannot exceed 100')) throw e;
    }
  });

  await test('key chord', async () => {
    await handleComputer({ action: 'key', tabId: 1, text: 'ctrl+a' }, createMockDeps());
  });

  await test('unknown key (insertText)', async () => {
    await handleComputer({ action: 'key', tabId: 1, text: 'unknownkey' }, createMockDeps());
  });

  // Reload shortcuts
  for (const shortcut of ['cmd+r', 'cmd+shift+r', 'ctrl+r', 'ctrl+shift+r', 'f5', 'ctrl+f5', 'shift+f5']) {
    await test(`reload shortcut: ${shortcut}`, async () => {
      const result = await handleComputer({ action: 'key', tabId: 1, text: shortcut }, createMockDeps());
      if (!result.output?.includes('reload')) throw new Error('Should be reload');
    });
  }

  // --- WAIT ---
  console.log('\nwait:');
  await test('1 second (singular)', async () => {
    await handleComputer({ action: 'wait', tabId: 1, duration: 0.01 }, createMockDeps());
    // Use very short duration for testing
  });

  await test('missing duration', async () => {
    try {
      await handleComputer({ action: 'wait', tabId: 1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Duration parameter')) throw e;
    }
  });

  await test('duration <= 0', async () => {
    try {
      await handleComputer({ action: 'wait', tabId: 1, duration: 0 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('must be positive')) throw e;
    }
  });

  await test('duration < 0', async () => {
    try {
      await handleComputer({ action: 'wait', tabId: 1, duration: -1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('must be positive')) throw e;
    }
  });

  await test('duration > 30', async () => {
    try {
      await handleComputer({ action: 'wait', tabId: 1, duration: 31 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('cannot exceed 30')) throw e;
    }
  });

  // --- SCROLL ---
  console.log('\nscroll:');
  await test('down', async () => {
    const result = await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'down' }, createMockDeps());
    if (!result.output?.includes('Scrolled down')) throw new Error('Wrong output');
  });

  await test('up', async () => {
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'up' }, createMockDeps());
  });

  await test('left', async () => {
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'left' }, createMockDeps());
  });

  await test('right', async () => {
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'right' }, createMockDeps());
  });

  await test('with scroll_amount', async () => {
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'down', scroll_amount: 5 }, createMockDeps());
  });

  await test('with DPR scaling', async () => {
    const deps = createMockDeps();
    deps.screenshotContexts.set('tab_1', {
      viewportWidth: 1920, viewportHeight: 1080,
      screenshotWidth: 3840, screenshotHeight: 2160
    });
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [1000, 500], scroll_direction: 'down' }, deps);
  });

  await test('default direction (down)', async () => {
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500] }, createMockDeps());
  });

  await test('missing coordinate', async () => {
    try {
      await handleComputer({ action: 'scroll', tabId: 1, scroll_direction: 'down' }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Coordinate parameter')) throw e;
    }
  });

  await test('coordinate wrong length', async () => {
    try {
      await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500], scroll_direction: 'down' }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Coordinate parameter')) throw e;
    }
  });

  await test('invalid direction', async () => {
    try {
      await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'diagonal' }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('Invalid scroll direction')) throw e;
    }
  });

  await test('tab not active (content script fallback)', async () => {
    const origGet = chrome.tabs.get;
    chrome.tabs.get = async (tabId) => ({ id: tabId, active: false });
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'down' }, createMockDeps());
    chrome.tabs.get = origGet;
  });

  await test('CDP scroll fails (content script fallback)', async () => {
    const deps = createMockDeps({
      sendDebuggerCommand: async () => { throw new Error('CDP error'); }
    });
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'down' }, deps);
  });

  await test('CDP scroll ineffective (content script fallback)', async () => {
    const origExec = chrome.scripting.executeScript;
    chrome.scripting.executeScript = async ({ func }) => {
      // Return same position to simulate ineffective scroll
      if (func.toString().includes('pageXOffset')) {
        return [{ result: { x: 0, y: 0 } }];
      }
      return origExec({ func });
    };
    await handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'down' }, createMockDeps());
    chrome.scripting.executeScript = origExec;
  });

  // --- SCROLL_TO ---
  console.log('\nscroll_to:');
  await test('happy path', async () => {
    const result = await handleComputer({ action: 'scroll_to', tabId: 1, ref: 'ref_1' }, createMockDeps());
    if (!result.output?.includes('Scrolled to element')) throw new Error('Wrong output');
  });

  await test('missing ref', async () => {
    try {
      await handleComputer({ action: 'scroll_to', tabId: 1 }, createMockDeps());
      throw new Error('Should have thrown');
    } catch (e) {
      if (!e.message.includes('ref parameter')) throw e;
    }
  });

  await test('element not found', async () => {
    const deps = createMockDeps({ scrollToFailed: true });
    const result = await handleComputer({ action: 'scroll_to', tabId: 1, ref: 'ref_99' }, deps);
    if (!result.error) throw new Error('Should have error');
  });

  // --- UNKNOWN ACTION ---
  console.log('\nunknown action:');
  await test('returns error string', async () => {
    const result = await handleComputer({ action: 'unknown_action', tabId: 1 }, createMockDeps());
    if (!result.includes('Error: Unknown action')) throw new Error('Wrong output');
  });

  // --- SUMMARY ---
  console.log('\n========================================');
  console.log(`Tests: ${passed} passed, ${failed} failed`);
  console.log('========================================');

  return failed > 0 ? 1 : 0;
}

runCoverageTests().then(code => process.exit(code));
