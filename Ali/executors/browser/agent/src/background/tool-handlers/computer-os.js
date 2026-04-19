/**
 * Tool handler for `computer_os` — routes OS-level actions to the native host.
 *
 * Supported actions: drive_file_picker, focus_app, applescript.
 */

const NATIVE_HOST_ID = 'com.hanzi_browse.oauth_host';

/**
 * Handle computer_os tool — send OS-level actions to the native messaging host.
 * @param {Object} toolInput - Tool input parameters
 * @param {string} toolInput.action - Action to perform: drive_file_picker | focus_app | applescript
 * @param {string} [toolInput.path] - Required for drive_file_picker
 * @param {string} [toolInput.app] - Required for focus_app
 * @param {string} [toolInput.script] - Required for applescript
 * @returns {Promise<string>} Success message or error string
 */
export async function handleComputerOs(toolInput) {
  const { action } = toolInput || {};

  if (!action) {
    return 'Error: missing action';
  }

  let message;
  switch (action) {
    case 'drive_file_picker':
      if (!toolInput.path) return 'Error: missing path';
      message = { type: 'drive_file_picker', path: toolInput.path };
      break;
    case 'focus_app':
      if (!toolInput.app) return 'Error: missing app';
      message = { type: 'focus_app', app: toolInput.app };
      break;
    case 'applescript':
      if (!toolInput.script) return 'Error: missing script';
      message = { type: 'applescript', script: toolInput.script };
      break;
    default:
      return `Error: unknown action: ${action}`;
  }

  try {
    const response = await new Promise((resolve, reject) => {
      chrome.runtime.sendNativeMessage(NATIVE_HOST_ID, message, (res) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          resolve(res);
        }
      });
    });

    if (!response || response.ok === false) {
      return `Error: ${response?.error || 'native host error'}`;
    }
    return response.stdout ?? 'ok';
  } catch (err) {
    return `Error: native messaging failed: ${err.message}`;
  }
}
