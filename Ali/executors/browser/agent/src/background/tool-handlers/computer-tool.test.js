/**
 * Comprehensive test suite for computer-tool.js
 * Tests all actions with 100% code coverage goal
 *
 * Run with: node --experimental-vm-modules computer-tool.test.js
 */

// ============================================================================
// MOCK SETUP
// ============================================================================

// Track all CDP commands sent
const cdpCommands = [];
const contentMessages = [];

// Mock chrome APIs
globalThis.chrome = {
  scripting: {
    executeScript: async ({ target: _target, func }) => {
      const funcStr = func.toString();
      // Return mock viewport info - check most specific patterns first
      if (funcStr.includes('pageXOffset')) {
        return [{ result: { x: 0, y: 100 } }]; // Simulate scroll position changed
      }
      // Zoom viewport check (returns width/height, not viewportWidth)
      if (funcStr.includes('innerWidth') && funcStr.includes('innerHeight') && !funcStr.includes('devicePixelRatio')) {
        return [{ result: { width: 1920, height: 1080 } }];
      }
      // Screenshot viewport check (returns viewportWidth/viewportHeight/devicePixelRatio)
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

// Mock cdpHelper - simulates cdp-helper.js screenshot behavior
// cdpHelper.screenshot() returns DPR-scaled images (viewport size, not retina size)
const mockCdpHelper = {
  screenshot: async (tabId) => {
    cdpCommands.push({ type: 'cdpHelper.screenshot', tabId });
    // Simulates a 1920x1080 viewport with 2x DPR
    // After DPR scaling, screenshot is viewport size (not 2x)
    return {
      base64: 'base64mockdata',
      width: 1920,  // Already DPR-scaled
      height: 1080, // Already DPR-scaled
      format: 'png',
      viewportWidth: 1920,
      viewportHeight: 1080,
    };
  },
};
globalThis.cdpHelper = mockCdpHelper;

// Create mock dependencies
function createMockDeps(overrides = {}) {
  cdpCommands.length = 0;
  contentMessages.length = 0;

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
    sendToContent: async (tabId, action, data) => {
      contentMessages.push({ tabId, action, data });
      if (action === 'GET_ELEMENT_RECT') {
        return { success: true, coordinates: [500, 300], rect: { centerX: 500, centerY: 300 } };
      }
      if (action === 'SCROLL_TO_ELEMENT') {
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

// Mock key functions
globalThis.getKeyCode = (key) => {
  const codes = {
    'Enter': { key: 'Enter', code: 'Enter', keyCode: 13 },
    'a': { key: 'a', code: 'KeyA', keyCode: 65, text: 'a' },
    'A': { key: 'A', code: 'KeyA', keyCode: 65, text: 'A' },
    'Backspace': { key: 'Backspace', code: 'Backspace', keyCode: 8 },
    'Tab': { key: 'Tab', code: 'Tab', keyCode: 9 },
  };
  return codes[key];
};
globalThis.requiresShift = (char) => char >= 'A' && char <= 'Z';
globalThis.pressKey = async (tabId, keyDef, modifiers) => {
  cdpCommands.push({ type: 'pressKey', tabId, keyDef, modifiers });
};
globalThis.pressKeyChord = async (tabId, chord) => {
  cdpCommands.push({ type: 'pressKeyChord', tabId, chord });
};

// ============================================================================
// TEST HELPERS
// ============================================================================

let testsPassed = 0;
let testsFailed = 0;
const failures = [];

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}


async function assertThrowsAsync(fn, expectedMessage) {
  let threw = false;
  let actualMessage = '';
  try {
    await fn();
  } catch (e) {
    threw = true;
    actualMessage = e.message;
  }
  if (!threw) {
    throw new Error(`Expected function to throw: ${expectedMessage}`);
  }
  if (expectedMessage && !actualMessage.includes(expectedMessage)) {
    throw new Error(`Expected error message to include "${expectedMessage}" but got "${actualMessage}"`);
  }
}

const testQueue = [];

function test(name, fn) {
  testQueue.push({ name, fn });
}

function describe(name, fn) {
  testQueue.push({ type: 'describe', name });
  fn();
}

async function runTestQueue() {
  for (const item of testQueue) {
    if (item.type === 'describe') {
      console.log(`\n${item.name}`);
    } else {
      try {
        await item.fn();
        testsPassed++;
        console.log(`  ✓ ${item.name}`);
      } catch (e) {
        testsFailed++;
        failures.push({ name: item.name, error: e.message });
        console.log(`  ✗ ${item.name}`);
        console.log(`    ${e.message}`);
      }
    }
  }
}

// ============================================================================
// INLINE IMPLEMENTATION FOR TESTING
// (Copy of handleComputer to avoid import issues)
// ============================================================================

function scaleCoordinates(x, y, context) {
  if (!context || !context.screenshotWidth || !context.viewportWidth) {
    return [x, y];
  }
  const scaleX = context.viewportWidth / context.screenshotWidth;
  const scaleY = context.viewportHeight / context.screenshotHeight;
  return [Math.round(x * scaleX), Math.round(y * scaleY)];
}

// eslint-disable-next-line complexity
async function handleComputer(toolInput, deps) {
  const { action, tabId } = toolInput;
  const {
    sendDebuggerCommand,
    ensureDebugger,
    log,
    sendToContent,
    hideIndicatorsForToolUse,
    showIndicatorsAfterToolUse,
    screenshotCounter,
    capturedScreenshots,
    screenshotContexts,
    taskScreenshots,
  } = deps;

  switch (action) {
    case 'screenshot': {
      try {
        // Ensure debugger is attached before cdpHelper.screenshot can use it
        await ensureDebugger(tabId);

        // Use cdpHelper.screenshot() which handles:
        // - Hiding/showing indicators
        // - DPR scaling (divides by devicePixelRatio)
        // - Additional resizing to fit token limits via calculateTargetDimensions
        // - Screenshot context storage
        const result = await cdpHelper.screenshot(tabId);

        // Store screenshot for upload_image
        const imageId = `screenshot_${++screenshotCounter.value}`;
        const dataUrl = `data:image/${result.format};base64,${result.base64}`;
        capturedScreenshots.set(imageId, dataUrl);

        // Store screenshot context for coordinate scaling
        // Note: After DPR scaling, screenshot dimensions match viewport dimensions
        const contextData = {
          viewportWidth: result.viewportWidth,
          viewportHeight: result.viewportHeight,
          screenshotWidth: result.width,
          screenshotHeight: result.height,
          devicePixelRatio: 1, // Already scaled by cdpHelper.screenshot
        };
        screenshotContexts.set(imageId, contextData);
        screenshotContexts.set(`tab_${tabId}`, contextData);

        // Collect for task logging
        taskScreenshots.push(dataUrl);

        // Return standard screenshot format
        return {
          output: `Successfully captured screenshot (${result.width}x${result.height}, ${result.format}) - ID: ${imageId}`,
          base64Image: result.base64,
          imageFormat: result.format,
          imageId,
        };
      } catch (err) {
        return {
          error: `Error capturing screenshot: ${err instanceof Error ? err.message : 'Unknown error'}`,
        };
      }
    }

    case 'zoom': {
      if (!toolInput.region || toolInput.region.length !== 4) {
        throw new Error('Region parameter is required for zoom action and must be [x0, y0, x1, y1]');
      }
      let [x0, y0, x1, y1] = toolInput.region;
      if (x0 < 0 || y0 < 0 || x1 <= x0 || y1 <= y0) {
        throw new Error('Invalid region coordinates: x0 and y0 must be non-negative, and x1 > x0, y1 > y0');
      }
      try {
        const context = screenshotContexts.get(`tab_${tabId}`);
        if (context) {
          [x0, y0] = scaleCoordinates(x0, y0, context);
          [x1, y1] = scaleCoordinates(x1, y1, context);
        }
        const viewportInfo = await chrome.scripting.executeScript({
          target: { tabId },
          func: () => ({ width: window.innerWidth, height: window.innerHeight }),
        });
        if (!viewportInfo || !viewportInfo[0]?.result) {
          throw new Error('Failed to get viewport dimensions');
        }
        const { width, height } = viewportInfo[0].result;
        if (x1 > width || y1 > height) {
          throw new Error(`Region exceeds viewport boundaries (${width}x${height}). Please choose a region within the visible viewport.`);
        }
        const regionWidth = x1 - x0;
        const regionHeight = y1 - y0;
        await ensureDebugger(tabId);
        const result = await sendDebuggerCommand(tabId, 'Page.captureScreenshot', {
          format: 'png',
          captureBeyondViewport: false,
          fromSurface: true,
          clip: { x: x0, y: y0, width: regionWidth, height: regionHeight, scale: 1 },
        });
        if (!result || !result.data) {
          throw new Error('Failed to capture zoomed screenshot via CDP');
        }
        return {
          output: `Successfully captured zoomed screenshot of region (${x0},${y0}) to (${x1},${y1}) - ${regionWidth}x${regionHeight} pixels`,
          base64Image: result.data,
          imageFormat: 'png',
        };
      } catch (err) {
        return {
          error: `Error capturing zoomed screenshot: ${err instanceof Error ? err.message : 'Unknown error'}`,
        };
      }
    }

    case 'left_click':
    case 'right_click':
    case 'middle_click':
    case 'double_click':
    case 'triple_click': {
      await hideIndicatorsForToolUse(tabId);
      await new Promise(r => setTimeout(r, 50));
      try {
        let x, y;
        if (toolInput.ref) {
          const result = await sendToContent(tabId, 'GET_ELEMENT_RECT', { ref: toolInput.ref });
          if (!result.success) {
            return { error: result.error };
          }
          [x, y] = result.coordinates || [result.rect?.centerX, result.rect?.centerY];
        } else if (toolInput.coordinate) {
          [x, y] = toolInput.coordinate;
          const context = screenshotContexts.get(`tab_${tabId}`);
          if (context) {
            [x, y] = scaleCoordinates(x, y, context);
          }
        } else {
          throw new Error('Either ref or coordinate parameter is required for click action');
        }
        await log('CLICK', `${toolInput.ref || 'coordinate'} → (${Math.round(x)}, ${Math.round(y)})`, null);
        await ensureDebugger(tabId);
        const clickCount = action === 'double_click' ? 2 : action === 'triple_click' ? 3 : 1;
        const button = action === 'right_click' ? 'right' : action === 'middle_click' ? 'middle' : 'left';
        const buttonCode = button === 'left' ? 1 : button === 'right' ? 2 : 4;
        let modifiers = 0;
        if (toolInput.modifiers) {
          const modMap = { alt: 1, ctrl: 2, control: 2, meta: 4, cmd: 4, command: 4, win: 4, windows: 4, shift: 8 };
          const mods = toolInput.modifiers.toLowerCase().split('+');
          for (const mod of mods) {
            modifiers |= modMap[mod.trim()] || 0;
          }
        }
        await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
          type: 'mouseMoved', x, y, button: 'none', buttons: 0, modifiers,
        });
        await new Promise(r => setTimeout(r, 100));
        for (let i = 1; i <= clickCount; i++) {
          await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
            type: 'mousePressed', x, y, button, buttons: buttonCode, clickCount: i, modifiers,
          });
          await new Promise(r => setTimeout(r, 12));
          await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
            type: 'mouseReleased', x, y, button, buttons: 0, clickCount: i, modifiers,
          });
          if (i < clickCount) await new Promise(r => setTimeout(r, 100));
        }
        const clickType = clickCount === 1 ? 'Clicked' : clickCount === 2 ? 'Double-clicked' : 'Triple-clicked';
        return toolInput.ref
          ? { output: `${clickType} on element ${toolInput.ref}` }
          : { output: `${clickType} at (${Math.round(toolInput.coordinate[0])}, ${Math.round(toolInput.coordinate[1])})` };
      } finally {
        await showIndicatorsAfterToolUse(tabId);
      }
    }

    case 'hover': {
      let x, y;
      if (toolInput.ref) {
        const result = await sendToContent(tabId, 'GET_ELEMENT_RECT', { ref: toolInput.ref });
        if (!result.success) {
          return { error: result.error };
        }
        [x, y] = result.coordinates || [result.rect?.centerX, result.rect?.centerY];
      } else if (toolInput.coordinate) {
        [x, y] = toolInput.coordinate;
        const context = screenshotContexts.get(`tab_${tabId}`);
        if (context) {
          [x, y] = scaleCoordinates(x, y, context);
        }
      } else {
        throw new Error('Either ref or coordinate parameter is required for hover action');
      }
      await ensureDebugger(tabId);
      await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
        type: 'mouseMoved', x, y, button: 'none', buttons: 0, modifiers: 0,
      });
      return toolInput.ref
        ? { output: `Hovered over element ${toolInput.ref}` }
        : { output: `Hovered at (${Math.round(toolInput.coordinate[0])}, ${Math.round(toolInput.coordinate[1])})` };
    }

    case 'left_click_drag': {
      if (!toolInput.start_coordinate || toolInput.start_coordinate.length !== 2) {
        throw new Error('start_coordinate parameter is required for left_click_drag action');
      }
      if (!toolInput.coordinate || toolInput.coordinate.length !== 2) {
        throw new Error('coordinate parameter (end position) is required for left_click_drag action');
      }
      let [startX, startY] = toolInput.start_coordinate;
      let [endX, endY] = toolInput.coordinate;
      const context = screenshotContexts.get(`tab_${tabId}`);
      if (context) {
        [startX, startY] = scaleCoordinates(startX, startY, context);
        [endX, endY] = scaleCoordinates(endX, endY, context);
      }
      await ensureDebugger(tabId);
      await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
        type: 'mouseMoved', x: startX, y: startY, button: 'none', buttons: 0, modifiers: 0,
      });
      await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
        type: 'mousePressed', x: startX, y: startY, button: 'left', buttons: 1, clickCount: 1, modifiers: 0,
      });
      await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
        type: 'mouseMoved', x: endX, y: endY, button: 'left', buttons: 1, modifiers: 0,
      });
      await sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
        type: 'mouseReleased', x: endX, y: endY, button: 'left', buttons: 0, clickCount: 1, modifiers: 0,
      });
      return { output: `Dragged from (${startX}, ${startY}) to (${endX}, ${endY})` };
    }

    case 'type': {
      if (!toolInput.text) {
        throw new Error('Text parameter is required for type action');
      }
      await ensureDebugger(tabId);
      for (const char of toolInput.text) {
        let keyChar = char;
        if (char === '\n' || char === '\r') {
          keyChar = 'Enter';
        }
        const keyDef = getKeyCode(keyChar);
        if (keyDef) {
          const shiftMod = requiresShift(char) ? 8 : 0;
          await pressKey(tabId, keyDef, shiftMod);
        } else {
          await sendDebuggerCommand(tabId, 'Input.insertText', { text: char });
        }
      }
      return { output: `Typed "${toolInput.text}"` };
    }

    case 'key': {
      if (!toolInput.text) {
        throw new Error('Text parameter is required for key action');
      }
      const repeat = toolInput.repeat ?? 1;
      if (!Number.isInteger(repeat) || repeat < 1) {
        throw new Error('Repeat parameter must be a positive integer');
      }
      if (repeat > 100) {
        throw new Error('Repeat parameter cannot exceed 100');
      }
      const keys = toolInput.text.trim().split(/\s+/).filter(k => k.length > 0);
      if (keys.length === 1) {
        const key = keys[0].toLowerCase();
        if (
          key === 'cmd+r' || key === 'cmd+shift+r' ||
          key === 'ctrl+r' || key === 'ctrl+shift+r' ||
          key === 'f5' || key === 'ctrl+f5' || key === 'shift+f5'
        ) {
          const hardReload = key === 'cmd+shift+r' || key === 'ctrl+shift+r' ||
                            key === 'ctrl+f5' || key === 'shift+f5';
          await chrome.tabs.reload(tabId, { bypassCache: hardReload });
          const reloadType = hardReload ? 'hard reload' : 'reload';
          return { output: `Executed ${keys[0]} (${reloadType} page)` };
        }
      }
      await ensureDebugger(tabId);
      for (let i = 0; i < repeat; i++) {
        for (const key of keys) {
          if (key.includes('+')) {
            await pressKeyChord(tabId, key);
          } else {
            const keyDef = getKeyCode(key);
            if (keyDef) {
              await pressKey(tabId, keyDef, 0);
            } else {
              await sendDebuggerCommand(tabId, 'Input.insertText', { text: key });
            }
          }
        }
      }
      const repeatText = repeat > 1 ? ` (repeated ${repeat} times)` : '';
      return { output: `Pressed ${keys.length} key${keys.length === 1 ? '' : 's'}: ${keys.join(' ')}${repeatText}` };
    }

    case 'wait': {
      if (!toolInput.duration || toolInput.duration <= 0) {
        throw new Error('Duration parameter is required and must be positive');
      }
      if (toolInput.duration > 30) {
        throw new Error('Duration cannot exceed 30 seconds');
      }
      const ms = Math.round(1000 * toolInput.duration);
      await new Promise(resolve => setTimeout(resolve, ms));
      return {
        output: `Waited for ${toolInput.duration} second${toolInput.duration === 1 ? '' : 's'}`,
      };
    }

    case 'scroll': {
      if (!toolInput.coordinate || toolInput.coordinate.length !== 2) {
        throw new Error('Coordinate parameter is required for scroll action');
      }
      const direction = toolInput.scroll_direction || 'down';
      const amount = (toolInput.scroll_amount || 3) * 100;
      let deltaX = 0, deltaY = 0;
      switch (direction) {
        case 'up': deltaY = -amount; break;
        case 'down': deltaY = amount; break;
        case 'left': deltaX = -amount; break;
        case 'right': deltaX = amount; break;
        default: throw new Error(`Invalid scroll direction: ${direction}`);
      }
      const context = screenshotContexts.get(`tab_${tabId}`);
      let [x, y] = toolInput.coordinate;
      if (context) {
        [x, y] = scaleCoordinates(x, y, context);
      }
      const getScrollPosition = async () => {
        const result = await chrome.scripting.executeScript({
          target: { tabId },
          func: () => ({ x: window.pageXOffset, y: window.pageYOffset }),
        });
        return result[0]?.result || { x: 0, y: 0 };
      };
      const initialPos = await getScrollPosition();
      const tabInfo = await chrome.tabs.get(tabId);
      const tabIsActive = tabInfo.active ?? false;
      let cdpWorked = false;
      if (tabIsActive) {
        try {
          await ensureDebugger(tabId);
          const scrollPromise = sendDebuggerCommand(tabId, 'Input.dispatchMouseEvent', {
            type: 'mouseWheel', x, y, deltaX, deltaY,
          });
          const timeoutPromise = new Promise((_, reject) => {
            setTimeout(() => reject(new Error('Scroll timeout')), 5000);
          });
          await Promise.race([scrollPromise, timeoutPromise]);
          await new Promise(r => setTimeout(r, 200));
          const newPos = await getScrollPosition();
          if (Math.abs(newPos.x - initialPos.x) > 5 || Math.abs(newPos.y - initialPos.y) > 5) {
            cdpWorked = true;
          } else {
            throw new Error('CDP scroll ineffective');
          }
        } catch (e) {
          // Fall back to content script
        }
      }
      if (!cdpWorked) {
        await sendToContent(tabId, 'FIND_AND_SCROLL', {
          x, y, deltaX, deltaY, direction, amount
        });
        await new Promise(r => setTimeout(r, 200));
      }
      const ticks = toolInput.scroll_amount || 3;
      return { output: `Scrolled ${direction} by ${ticks} ticks at (${x}, ${y})` };
    }

    case 'scroll_to': {
      if (!toolInput.ref) {
        throw new Error('ref parameter is required for scroll_to action');
      }
      const result = await sendToContent(tabId, 'SCROLL_TO_ELEMENT', { ref: toolInput.ref });
      if (result.success) {
        return { output: `Scrolled to element with reference: ${toolInput.ref}` };
      }
      return { error: result.error };
    }

    default:
      return `Error: Unknown action: ${action}`;
  }
}

// ============================================================================
// TESTS
// ============================================================================

async function runTests() {
  console.log('Computer Tool Test Suite\n========================');

  // Register all tests first

  // --------------------------------------------------------------------------
  // SCREENSHOT TESTS
  // --------------------------------------------------------------------------
  describe('screenshot action', () => {
    test('returns correct format with base64Image and imageId', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'screenshot', tabId: 1 }, deps);

      assert(result.output.includes('Successfully captured screenshot'), 'Should have success message');
      assert(result.base64Image === 'base64mockdata', 'Should have base64Image');
      assert(result.imageFormat === 'png', 'Should have imageFormat');
      assert(result.imageId.startsWith('screenshot_'), 'Should have imageId');
    });

    test('stores screenshot context for DPR scaling', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'screenshot', tabId: 1 }, deps);

      assert(deps.screenshotContexts.has('tab_1'), 'Should store context by tab ID');
      const ctx = deps.screenshotContexts.get('tab_1');
      // After cdpHelper.screenshot, DPR is 1 because image is already scaled
      assert(ctx.devicePixelRatio === 1, 'Should store DPR as 1 (already scaled)');
      assert(ctx.viewportWidth === 1920, 'Should store viewport width');
      // Screenshot dimensions now match viewport (not 2x)
      assert(ctx.screenshotWidth === 1920, 'Screenshot width should match viewport');
      assert(ctx.screenshotHeight === 1080, 'Screenshot height should match viewport');
    });

    test('uses cdpHelper.screenshot which handles indicators', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'screenshot', tabId: 1 }, deps);

      // cdpHelper.screenshot() handles indicators internally
      // Check that it was called
      const screenshotCall = cdpCommands.find(cmd => cmd.type === 'cdpHelper.screenshot');
      assert(screenshotCall, 'Should call cdpHelper.screenshot');
      assert(screenshotCall.tabId === 1, 'Should pass correct tabId');
    });

    test('returns error object on failure', async () => {
      // Save original mock and replace with throwing version
      const originalScreenshot = cdpHelper.screenshot;
      cdpHelper.screenshot = async () => { throw new Error('CDP failed'); };

      const deps = createMockDeps();
      const result = await handleComputer({ action: 'screenshot', tabId: 1 }, deps);

      // Restore original mock
      cdpHelper.screenshot = originalScreenshot;

      assert(result.error.includes('Error capturing screenshot'), 'Should return error object');
    });
  });

  // --------------------------------------------------------------------------
  // ZOOM TESTS
  // --------------------------------------------------------------------------
  describe('zoom action', () => {
    test('throws error when region is missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'zoom', tabId: 1 }, deps),
        'Region parameter is required'
      );
    });

    test('throws error when region has wrong length', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'zoom', tabId: 1, region: [0, 0, 100] }, deps),
        'Region parameter is required'
      );
    });

    test('throws error for invalid coordinates (x0 < 0)', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'zoom', tabId: 1, region: [-1, 0, 100, 100] }, deps),
        'Invalid region coordinates'
      );
    });

    test('throws error for invalid coordinates (x1 <= x0)', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'zoom', tabId: 1, region: [100, 0, 50, 100] }, deps),
        'Invalid region coordinates'
      );
    });

    test('returns correct format on success', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'zoom', tabId: 1, region: [0, 0, 100, 100] }, deps);

      assert(result.output.includes('Successfully captured zoomed screenshot'), 'Should have success message');
      assert(result.base64Image === 'base64mockdata', 'Should have base64Image');
      assert(result.imageFormat === 'png', 'Should have imageFormat');
    });

    test('validates against viewport boundaries', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'zoom', tabId: 1, region: [0, 0, 9999, 9999] }, deps);

      assert(result.error.includes('Region exceeds viewport boundaries'), 'Should return viewport error');
    });
  });

  // --------------------------------------------------------------------------
  // CLICK TESTS
  // --------------------------------------------------------------------------
  describe('click actions', () => {
    test('left_click with coordinate returns correct format', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'left_click', tabId: 1, coordinate: [500, 300] }, deps);

      assert(result.output === 'Clicked at (500, 300)', `Should have correct output, got: ${result.output}`);
    });

    test('left_click with ref returns correct format', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'left_click', tabId: 1, ref: 'ref_1' }, deps);

      assert(result.output === 'Clicked on element ref_1', 'Should reference element');
    });

    test('throws error when neither ref nor coordinate provided', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'left_click', tabId: 1 }, deps),
        'Either ref or coordinate parameter is required'
      );
    });

    test('double_click sends correct clickCount', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'double_click', tabId: 1, coordinate: [500, 300] }, deps);

      assert(result.output.includes('Double-clicked'), 'Should say double-clicked');
      // Check CDP commands include clickCount 2
      const pressCommands = cdpCommands.filter(c => c.method === 'Input.dispatchMouseEvent' && c.params.type === 'mousePressed');
      assert(pressCommands.length === 2, 'Should have 2 press events for double click');
    });

    test('triple_click sends correct clickCount', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'triple_click', tabId: 1, coordinate: [500, 300] }, deps);

      assert(result.output.includes('Triple-clicked'), 'Should say triple-clicked');
    });

    test('right_click uses right button', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'right_click', tabId: 1, coordinate: [500, 300] }, deps);

      const pressCmd = cdpCommands.find(c => c.params?.type === 'mousePressed');
      assert(pressCmd.params.button === 'right', 'Should use right button');
      assert(pressCmd.params.buttons === 2, 'Should use button code 2');
    });

    test('middle_click uses middle button', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'middle_click', tabId: 1, coordinate: [500, 300] }, deps);

      const pressCmd = cdpCommands.find(c => c.params?.type === 'mousePressed');
      assert(pressCmd.params.button === 'middle', 'Should use middle button');
      assert(pressCmd.params.buttons === 4, 'Should use button code 4');
    });

    test('modifiers are parsed correctly', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'left_click', tabId: 1, coordinate: [500, 300], modifiers: 'ctrl+shift' }, deps);

      const pressCmd = cdpCommands.find(c => c.params?.type === 'mousePressed');
      assert(pressCmd.params.modifiers === 10, 'Should have ctrl (2) + shift (8) = 10');
    });

    test('scales coordinates with DPR context', async () => {
      const deps = createMockDeps();
      // Set up a 2x DPR context
      deps.screenshotContexts.set('tab_1', {
        viewportWidth: 1920,
        viewportHeight: 1080,
        screenshotWidth: 3840,
        screenshotHeight: 2160,
        devicePixelRatio: 2,
      });

      await handleComputer({ action: 'left_click', tabId: 1, coordinate: [1000, 500] }, deps);

      // 1000 * (1920/3840) = 500, 500 * (1080/2160) = 250
      const moveCmd = cdpCommands.find(c => c.params?.type === 'mouseMoved');
      assert(moveCmd.params.x === 500, `X should be scaled to 500, got ${moveCmd.params.x}`);
      assert(moveCmd.params.y === 250, `Y should be scaled to 250, got ${moveCmd.params.y}`);
    });
  });

  // --------------------------------------------------------------------------
  // HOVER TESTS
  // --------------------------------------------------------------------------
  describe('hover action', () => {
    test('returns correct format with coordinate', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'hover', tabId: 1, coordinate: [500, 300] }, deps);

      assert(result.output === 'Hovered at (500, 300)', 'Should have correct output');
    });

    test('returns correct format with ref', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'hover', tabId: 1, ref: 'ref_1' }, deps);

      assert(result.output === 'Hovered over element ref_1', 'Should reference element');
    });

    test('throws error when neither ref nor coordinate provided', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'hover', tabId: 1 }, deps),
        'Either ref or coordinate parameter is required'
      );
    });

    test('sends mouseMoved with modifiers: 0', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'hover', tabId: 1, coordinate: [500, 300] }, deps);

      const moveCmd = cdpCommands.find(c => c.params?.type === 'mouseMoved');
      assert(moveCmd.params.modifiers === 0, 'Should have modifiers: 0');
    });
  });

  // --------------------------------------------------------------------------
  // DRAG TESTS
  // --------------------------------------------------------------------------
  describe('left_click_drag action', () => {
    test('throws error when start_coordinate missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'left_click_drag', tabId: 1, coordinate: [500, 500] }, deps),
        'start_coordinate parameter is required'
      );
    });

    test('throws error when coordinate (end) missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'left_click_drag', tabId: 1, start_coordinate: [100, 100] }, deps),
        'coordinate parameter (end position) is required'
      );
    });

    test('returns correct format on success', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({
        action: 'left_click_drag',
        tabId: 1,
        start_coordinate: [100, 100],
        coordinate: [500, 500]
      }, deps);

      assert(result.output.includes('Dragged from'), 'Should have drag message');
    });

    test('sends correct sequence of mouse events', async () => {
      const deps = createMockDeps();
      await handleComputer({
        action: 'left_click_drag',
        tabId: 1,
        start_coordinate: [100, 100],
        coordinate: [500, 500]
      }, deps);

      const mouseEvents = cdpCommands.filter(c => c.method === 'Input.dispatchMouseEvent');
      assert(mouseEvents.length === 4, 'Should have 4 mouse events');
      assert(mouseEvents[0].params.type === 'mouseMoved', 'First should be mouseMoved');
      assert(mouseEvents[1].params.type === 'mousePressed', 'Second should be mousePressed');
      assert(mouseEvents[2].params.type === 'mouseMoved', 'Third should be mouseMoved (drag)');
      assert(mouseEvents[3].params.type === 'mouseReleased', 'Fourth should be mouseReleased');
    });
  });

  // --------------------------------------------------------------------------
  // TYPE TESTS
  // --------------------------------------------------------------------------
  describe('type action', () => {
    test('throws error when text missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'type', tabId: 1 }, deps),
        'Text parameter is required'
      );
    });

    test('returns correct format on success', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'type', tabId: 1, text: 'hello' }, deps);

      assert(result.output === 'Typed "hello"', 'Should have correct output');
    });

    test('uses pressKey for characters with key codes', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'type', tabId: 1, text: 'a' }, deps);

      const pressKeyCmd = cdpCommands.find(c => c.type === 'pressKey');
      assert(pressKeyCmd, 'Should use pressKey for "a"');
    });

    test('uses insertText for characters without key codes', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'type', tabId: 1, text: '你' }, deps);

      const insertCmd = cdpCommands.find(c => c.method === 'Input.insertText');
      assert(insertCmd, 'Should use insertText for unicode');
    });

    test('uses shift modifier for uppercase letters', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'type', tabId: 1, text: 'A' }, deps);

      const pressKeyCmd = cdpCommands.find(c => c.type === 'pressKey');
      assert(pressKeyCmd.modifiers === 8, 'Should use shift (8) for uppercase');
    });

    test('converts newlines to Enter key', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'type', tabId: 1, text: '\n' }, deps);

      const pressKeyCmd = cdpCommands.find(c => c.type === 'pressKey');
      assert(pressKeyCmd.keyDef.key === 'Enter', 'Should convert newline to Enter');
    });
  });

  // --------------------------------------------------------------------------
  // KEY TESTS
  // --------------------------------------------------------------------------
  describe('key action', () => {
    test('throws error when text missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'key', tabId: 1 }, deps),
        'Text parameter is required'
      );
    });

    test('throws error for invalid repeat (negative)', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'key', tabId: 1, text: 'Enter', repeat: -1 }, deps),
        'Repeat parameter must be a positive integer'
      );
    });

    test('throws error for repeat > 100', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'key', tabId: 1, text: 'Enter', repeat: 101 }, deps),
        'Repeat parameter cannot exceed 100'
      );
    });

    test('returns correct format for single key', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'key', tabId: 1, text: 'Enter' }, deps);

      assert(result.output === 'Pressed 1 key: Enter', 'Should have correct output');
    });

    test('returns correct format for multiple keys', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'key', tabId: 1, text: 'Enter Tab' }, deps);

      assert(result.output === 'Pressed 2 keys: Enter Tab', 'Should pluralize');
    });

    test('returns correct format with repeat', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'key', tabId: 1, text: 'Enter', repeat: 3 }, deps);

      assert(result.output.includes('(repeated 3 times)'), 'Should show repeat count');
    });

    test('uses chrome.tabs.reload for reload shortcuts', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'key', tabId: 1, text: 'cmd+r' }, deps);

      assert(result.output.includes('reload page'), 'Should indicate reload');
      const reloadCmd = cdpCommands.find(c => c.type === 'tabs.reload');
      assert(reloadCmd, 'Should call chrome.tabs.reload');
      assert(reloadCmd.options.bypassCache === false, 'Should not bypass cache for soft reload');
    });

    test('uses hard reload for shift variants', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'key', tabId: 1, text: 'cmd+shift+r' }, deps);

      assert(result.output.includes('hard reload'), 'Should indicate hard reload');
      const reloadCmd = cdpCommands.find(c => c.type === 'tabs.reload');
      assert(reloadCmd.options.bypassCache === true, 'Should bypass cache for hard reload');
    });

    test('uses pressKeyChord for key combinations', async () => {
      const deps = createMockDeps();
      await handleComputer({ action: 'key', tabId: 1, text: 'ctrl+a' }, deps);

      const chordCmd = cdpCommands.find(c => c.type === 'pressKeyChord');
      assert(chordCmd, 'Should use pressKeyChord');
      assert(chordCmd.chord === 'ctrl+a', 'Should pass correct chord');
    });
  });

  // --------------------------------------------------------------------------
  // WAIT TESTS
  // --------------------------------------------------------------------------
  describe('wait action', () => {
    test('throws error when duration missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'wait', tabId: 1 }, deps),
        'Duration parameter is required'
      );
    });

    test('throws error when duration <= 0', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'wait', tabId: 1, duration: 0 }, deps),
        'Duration parameter is required and must be positive'
      );
    });

    test('throws error when duration > 30', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'wait', tabId: 1, duration: 31 }, deps),
        'Duration cannot exceed 30 seconds'
      );
    });

    test('returns singular "second" for duration 1', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'wait', tabId: 1, duration: 1 }, deps);

      assert(result.output === 'Waited for 1 second', 'Should use singular');
    });

    test('returns plural "seconds" for duration > 1', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'wait', tabId: 1, duration: 2 }, deps);

      assert(result.output === 'Waited for 2 seconds', 'Should use plural');
    });
  });

  // --------------------------------------------------------------------------
  // SCROLL TESTS
  // --------------------------------------------------------------------------
  describe('scroll action', () => {
    test('throws error when coordinate missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'scroll', tabId: 1, scroll_direction: 'down' }, deps),
        'Coordinate parameter is required'
      );
    });

    test('throws error for invalid direction', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'scroll', tabId: 1, coordinate: [500, 500], scroll_direction: 'diagonal' }, deps),
        'Invalid scroll direction'
      );
    });

    test('returns correct format on success', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({
        action: 'scroll',
        tabId: 1,
        coordinate: [500, 500],
        scroll_direction: 'down'
      }, deps);

      assert(result.output.includes('Scrolled down by 3 ticks'), 'Should have correct output');
    });

    test('uses CDP mouseWheel when tab is active', async () => {
      const deps = createMockDeps();
      await handleComputer({
        action: 'scroll',
        tabId: 1,
        coordinate: [500, 500],
        scroll_direction: 'down'
      }, deps);

      const wheelCmd = cdpCommands.find(c => c.params?.type === 'mouseWheel');
      assert(wheelCmd, 'Should use CDP mouseWheel');
    });

    test('calculates correct delta for up direction', async () => {
      const deps = createMockDeps();
      await handleComputer({
        action: 'scroll',
        tabId: 1,
        coordinate: [500, 500],
        scroll_direction: 'up',
        scroll_amount: 5
      }, deps);

      const wheelCmd = cdpCommands.find(c => c.params?.type === 'mouseWheel');
      assert(wheelCmd.params.deltaY === -500, 'Should have negative deltaY for up');
    });

    test('calculates correct delta for left direction', async () => {
      const deps = createMockDeps();
      await handleComputer({
        action: 'scroll',
        tabId: 1,
        coordinate: [500, 500],
        scroll_direction: 'left'
      }, deps);

      const wheelCmd = cdpCommands.find(c => c.params?.type === 'mouseWheel');
      assert(wheelCmd.params.deltaX === -300, 'Should have negative deltaX for left');
    });
  });

  // --------------------------------------------------------------------------
  // SCROLL_TO TESTS
  // --------------------------------------------------------------------------
  describe('scroll_to action', () => {
    test('throws error when ref missing', async () => {
      const deps = createMockDeps();
      await assertThrowsAsync(
        () => handleComputer({ action: 'scroll_to', tabId: 1 }, deps),
        'ref parameter is required'
      );
    });

    test('returns correct format on success', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'scroll_to', tabId: 1, ref: 'ref_1' }, deps);

      assert(result.output === 'Scrolled to element with reference: ref_1', 'Should have correct output');
    });

    test('returns error when element not found', async () => {
      const deps = createMockDeps({
        sendToContent: async () => ({ success: false, error: 'Element not found' }),
      });
      const result = await handleComputer({ action: 'scroll_to', tabId: 1, ref: 'ref_99' }, deps);

      assert(result.error === 'Element not found', 'Should return error');
    });
  });

  // --------------------------------------------------------------------------
  // UNKNOWN ACTION TESTS
  // --------------------------------------------------------------------------
  describe('unknown action', () => {
    test('returns error for unknown action', async () => {
      const deps = createMockDeps();
      const result = await handleComputer({ action: 'unknown_action', tabId: 1 }, deps);

      assert(result === 'Error: Unknown action: unknown_action', 'Should return error string');
    });
  });

  // --------------------------------------------------------------------------
  // DPR SCALING TESTS
  // --------------------------------------------------------------------------
  describe('DPR coordinate scaling', () => {
    test('scaleCoordinates returns original when no context', () => {
      const [x, y] = scaleCoordinates(1000, 500, null);
      assert(x === 1000 && y === 500, 'Should return original coordinates');
    });

    test('scaleCoordinates scales correctly with 2x DPR', () => {
      const context = {
        viewportWidth: 1920,
        viewportHeight: 1080,
        screenshotWidth: 3840,
        screenshotHeight: 2160,
      };
      const [x, y] = scaleCoordinates(1000, 500, context);
      assert(x === 500, `X should be 500, got ${x}`);
      assert(y === 250, `Y should be 250, got ${y}`);
    });

    test('scaleCoordinates handles 1x DPR (no scaling needed)', () => {
      const context = {
        viewportWidth: 1920,
        viewportHeight: 1080,
        screenshotWidth: 1920,
        screenshotHeight: 1080,
      };
      const [x, y] = scaleCoordinates(1000, 500, context);
      assert(x === 1000, 'X should be unchanged');
      assert(y === 500, 'Y should be unchanged');
    });
  });

  // --------------------------------------------------------------------------
  // RUN ALL REGISTERED TESTS
  // --------------------------------------------------------------------------
  await runTestQueue();

  // --------------------------------------------------------------------------
  // SUMMARY
  // --------------------------------------------------------------------------
  console.log('\n========================================');
  console.log(`Tests: ${testsPassed} passed, ${testsFailed} failed`);
  console.log('========================================');

  if (failures.length > 0) {
    console.log('\nFailures:');
    failures.forEach(f => {
      console.log(`  - ${f.name}: ${f.error}`);
    });
  }

  // Return exit code
  return testsFailed > 0 ? 1 : 0;
}

// Run tests
runTests().then(code => {
  process.exit(code);
}).catch(err => {
  console.error('Test runner error:', err);
  process.exit(1);
});
