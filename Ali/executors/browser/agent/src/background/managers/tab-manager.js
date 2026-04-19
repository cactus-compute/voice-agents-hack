/**
 * Tab Manager
 * Handles tab group management and tab tracking
 */

import { clearPosition } from '../modules/mouse-movement.js';
import { RETRIES, DELAYS } from '../modules/constants.js';
import { retryWithBackoff, isTabDraggingError } from '../utils/retry.js';

// Tab state - shared references from service worker
let agentOpenedTabs = null;
let logFn = null;

/**
 * @typedef {Object} TabManagerDeps
 * @property {Set<number>} agentOpenedTabs - Set of tab IDs opened by agent
 * @property {Function} log - Logging function
 */

/**
 * Initialize tab manager with shared state
 * @param {TabManagerDeps} deps - Dependency injection object
 */
export function initTabManager(deps) {
  agentOpenedTabs = deps.agentOpenedTabs;
  logFn = deps.log;
}

/**
 * Check if a tab is managed by the agent (in group or opened by agent)
 * @param {number} tabId - Tab ID to check
 * @param {number|null} [currentGroupId] - Current session group ID
 * @param {Set<number>|null} [openedTabs] - Session-specific opened tab set
 * @returns {Promise<boolean>} True if tab is managed by agent
 */
export async function isTabManagedByAgent(tabId, currentGroupId = null, openedTabs = null) {
  // Check if it's in our tab group
  if (currentGroupId !== null) {
    try {
      const tab = await chrome.tabs.get(tabId);
      if (tab.groupId === currentGroupId) return true;
    } catch (e) {
      // Tab doesn't exist
    }
  }

  // Check if it was opened by an agent action
  const openedTabsToCheck = openedTabs || agentOpenedTabs;
  return openedTabsToCheck && openedTabsToCheck.has(tabId);
}

/**
 * Get or create a tab group for this session
 * @param {number} tabId - Tab ID to add to group (used if creating new group)
 * @param {number|null} [existingGroupId] - Optional existing group ID from client
 * @returns {Promise<number|null>} Tab group ID, or null if creation failed
 */
export async function ensureTabGroup(tabId, existingGroupId = null) {
  // If client provided a group ID, validate it still exists
  if (existingGroupId !== null) {
    try {
      const group = await chrome.tabGroups.get(existingGroupId);
      if (group) {
        return existingGroupId;
      }
    } catch (e) {
      // Group was deleted, continue to create new one
    }
  }

  // Check if the tab is already in a group - if so, adopt it
  try {
    const tab = await chrome.tabs.get(tabId);
    if (tab.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE) {
      // Tab is already in a group - adopt that group as our session group
      return tab.groupId;
    }
  } catch (e) {
    // Tab doesn't exist or error getting tab info
  }

  // Create new group with the initial tab (with retry logic for "dragging" errors)
  try {
    return await retryWithBackoff(
      async () => {
        const groupId = await chrome.tabs.group({ tabIds: [tabId] });
        await chrome.tabGroups.update(groupId, {
          title: 'Agent',
          color: 'cyan',
          collapsed: false,
        });
        return groupId;
      },
      {
        maxRetries: RETRIES.MAX_TAB_GROUP,
        delay: DELAYS.RETRY,
        shouldRetry: isTabDraggingError,
        onRetry: (attempt, error) => {
          logFn('WARN', `Tab group creation failed (attempt ${attempt}/${RETRIES.MAX_TAB_GROUP}): ${error.message}. Retrying...`);
        },
      }
    );
  } catch (err) {
    await logFn('WARN', `Failed to create tab group: ${err.message}`);
    return null;
  }
}

/**
 * Add a tab to the session's tab group (with retry logic)
 * @param {number} tabId - Tab ID to add to group
 * @param {number|null} [currentGroupId] - Current session group ID (overrides module state)
 * @returns {Promise<void>}
 */
export async function addTabToGroup(tabId, currentGroupId = null) {
  if (currentGroupId === null) {
    await ensureTabGroup(tabId, currentGroupId);
    return;
  }

  try {
    await retryWithBackoff(
      async () => {
        await chrome.tabs.group({ tabIds: [tabId], groupId: currentGroupId });
      },
      {
        maxRetries: RETRIES.MAX_TAB_GROUP,
        delay: DELAYS.RETRY,
        shouldRetry: isTabDraggingError,
      }
    );
  } catch (err) {
    // Group may have been deleted or other error, create new one
    await ensureTabGroup(tabId, currentGroupId);
  }
}

/**
 * Validate that a tab is accessible to the agent
 * @param {number} tabId - Tab ID to validate
 * @param {number|null} [currentGroupId] - Current session group ID (overrides module state)
 * @returns {Promise<Object>} Validation result with {valid: boolean, error?: string}
 */
export async function validateTabInGroup(tabId, currentGroupId = null) {
  // Check if tab URL is restricted (chrome://, about:, etc.)
  try {
    const tab = await chrome.tabs.get(tabId);
    const restrictedProtocols = ['chrome:', 'about:', 'chrome-extension:', 'edge:', 'brave:'];
    const isRestricted = restrictedProtocols.some(protocol => tab.url?.startsWith(protocol));

    if (isRestricted) {
      return {
        valid: false,
        error: `Cannot access ${tab.url} - Chrome blocks extensions from interacting with system pages. Please navigate to a regular website (http:// or https://).`
      };
    }
  } catch (err) {
    // Tab doesn't exist or other error
    return {
      valid: false,
      error: `Tab ${tabId} is not accessible: ${err.message}`
    };
  }

  if (currentGroupId === null) {
    // No group yet - allow any tab (if not restricted)
    return { valid: true };
  }

  // Use the unified check
  const isManaged = await isTabManagedByAgent(tabId, currentGroupId);
  if (isManaged) {
    return { valid: true };
  }

  return {
    valid: false,
    error: `Tab ${tabId} is not managed by the Agent. Use tabs_context to see available tabs.`
  };
}

/**
 * Set up tab cleanup listener
 * @param {Set<number>} agentOpenedTabsSet - Set of agent-opened tab IDs to clean up on tab close
 */
export function registerTabCleanupListener(agentOpenedTabsSet) {
  chrome.tabs.onRemoved.addListener((tabId) => {
    agentOpenedTabsSet.delete(tabId);
    clearPosition(tabId);
  });
}
