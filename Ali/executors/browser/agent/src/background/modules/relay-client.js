/**
 * Relay Client Module
 *
 * Shared WebSocket relay primitives extracted from mcp-bridge.js
 * to break circular dependencies.
 *
 * api.js, oauth-manager.js, and codex-oauth-manager.js import from here
 * instead of mcp-bridge.js, eliminating all 3 circular dependency cycles.
 */

// ─── Socket Reference ──────────────────────────────────────────
// Owned by mcp-bridge.js — set/cleared via setRelaySocket()
let relaySocket = null;

export function getRelaySocket() {
  return relaySocket;
}

export function setRelaySocket(ws) {
  relaySocket = ws;
}

// ─── Connection Check ──────────────────────────────────────────
export function isRelayConnected() {
  return relaySocket && relaySocket.readyState === WebSocket.OPEN;
}

// ─── Pending Request State ─────────────────────────────────────
const pendingRelayRequests = new Map();
let relayRequestCounter = 0;

const pendingApiProxies = new Map();
let apiProxyCounter = 0;

// ─── Relay Request (for credential reads, etc.) ────────────────
/**
 * Send a request to the relay and wait for a typed response.
 *
 * @param {Object} message - Message to send to the relay
 * @param {string} responseType - Expected response message type
 * @param {number} timeoutMs - Timeout in milliseconds
 * @returns {Promise<Object>} Response message from the relay
 */
export function relayRequest(message, responseType, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    if (!relaySocket || relaySocket.readyState !== WebSocket.OPEN) {
      reject(new Error('Relay not connected'));
      return;
    }

    const requestId = message.requestId || `relay_${Date.now()}_${++relayRequestCounter}`;
    const timeout = setTimeout(() => {
      pendingRelayRequests.delete(requestId);
      reject(new Error('Relay request timed out'));
    }, timeoutMs);

    pendingRelayRequests.set(requestId, { resolve, reject, timeout, responseType });
    relaySocket.send(JSON.stringify({ ...message, requestId }));
  });
}

// ─── API Proxy (streaming through relay) ───────────────────────
/**
 * Proxy an API call through the relay server.
 * The relay adds Claude Code impersonation headers (user-agent, x-app)
 * that browsers can't set due to CORS restrictions.
 *
 * @param {string} url - API endpoint URL
 * @param {string} body - Serialized JSON request body
 * @param {Function} onChunk - Called with each SSE event object
 * @param {number} timeoutMs - Timeout in milliseconds
 * @returns {Promise<void>} Resolves when stream completes
 */
export function proxyApiCall(url, body, onChunk, timeoutMs = 150000) {
  return new Promise((resolve, reject) => {
    if (!relaySocket || relaySocket.readyState !== WebSocket.OPEN) {
      reject(new Error('Relay not connected'));
      return;
    }

    const requestId = `proxy_${Date.now()}_${++apiProxyCounter}`;

    const timeout = setTimeout(() => {
      pendingApiProxies.delete(requestId);
      reject(new Error('API proxy request timed out'));
    }, timeoutMs);

    pendingApiProxies.set(requestId, { onChunk, resolve, reject, timeout });

    relaySocket.send(JSON.stringify({
      type: 'proxy_api_call',
      requestId,
      url,
      body,
    }));
  });
}

// ─── Dispatch Helpers (called by mcp-bridge WebSocket handler) ──

/**
 * Try to match an incoming message against pending relay requests.
 * Returns true if the message was consumed.
 */
export function dispatchRelayResponse(message) {
  if (message.requestId && pendingRelayRequests.has(message.requestId)) {
    const pending = pendingRelayRequests.get(message.requestId);
    if (!pending.responseType || pending.responseType === message.type) {
      clearTimeout(pending.timeout);
      pendingRelayRequests.delete(message.requestId);
      pending.resolve(message);
      return true;
    }
  }
  return false;
}

/**
 * Try to match an incoming message against pending API proxy streams.
 * Returns true if the message was consumed.
 */
export function dispatchProxyResponse(message) {
  if (message.type === 'proxy_stream_chunk' || message.type === 'proxy_stream_end' || message.type === 'proxy_api_error') {
    const pending = pendingApiProxies.get(message.requestId);
    if (pending) {
      if (message.type === 'proxy_stream_chunk') {
        if (pending.onChunk) pending.onChunk(message.data);
      } else if (message.type === 'proxy_stream_end') {
        clearTimeout(pending.timeout);
        pendingApiProxies.delete(message.requestId);
        pending.resolve();
      } else if (message.type === 'proxy_api_error') {
        clearTimeout(pending.timeout);
        pendingApiProxies.delete(message.requestId);
        pending.reject(new Error(message.error));
      }
    }
    return true;
  }
  return false;
}

/**
 * Reject all in-flight relay operations (called on WebSocket disconnect).
 */
export function failAllPending() {
  for (const [requestId, pending] of pendingRelayRequests) {
    clearTimeout(pending.timeout);
    pending.reject(new Error('Relay disconnected before the request completed'));
    pendingRelayRequests.delete(requestId);
  }

  for (const [requestId, pending] of pendingApiProxies) {
    clearTimeout(pending.timeout);
    pending.reject(new Error('Relay disconnected during API proxy request'));
    pendingApiProxies.delete(requestId);
  }
}
