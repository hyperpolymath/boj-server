// SPDX-License-Identifier: MPL-2.0
// (PMPL-1.0-or-later preferred; MPL-2.0 required for boj-server ecosystem)
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

/**
 * gossamer-bridge.js — Unified IPC bridge for BoJ Node Operator tray app.
 *
 * Detects the available runtime (Gossamer, Tauri, or browser-only) and
 * dispatches `invoke` / `listen` calls to the appropriate backend. This
 * allows the tray UI to work under both Gossamer and Tauri during the
 * migration period.
 *
 * Priority order:
 *   1. Gossamer (`window.__gossamer_invoke`)  — own stack, preferred
 *   2. Tauri    (`window.__TAURI__`)          — legacy, transition
 *   3. Browser  (stub / error)               — development fallback
 */

(function (root) {
  'use strict';

  // ── Runtime detection ─────────────────────────────────────────────

  /**
   * Detect which desktop runtime is available.
   * @returns {"gossamer"|"tauri"|"browser"}
   */
  function detectRuntime() {
    if (typeof window !== 'undefined' &&
        typeof window.__gossamer_invoke === 'function') {
      return 'gossamer';
    }
    if (typeof window !== 'undefined' &&
        window.__TAURI__ != null &&
        typeof window.__TAURI__.core !== 'undefined') {
      return 'tauri';
    }
    return 'browser';
  }

  var _runtime = null;

  /**
   * Get the cached runtime identifier.
   * @returns {"gossamer"|"tauri"|"browser"}
   */
  function runtime() {
    if (_runtime === null) {
      _runtime = detectRuntime();
    }
    return _runtime;
  }

  // ── Invoke ────────────────────────────────────────────────────────

  /**
   * Invoke a backend command through whatever runtime is available.
   *
   * - On Gossamer: calls `window.__gossamer_invoke(cmd, args)`
   * - On Tauri:    calls `window.__TAURI__.core.invoke(cmd, args)`
   * - On browser:  rejects with a descriptive error
   *
   * @param {string} cmd   — The command name (e.g. "get_server_status")
   * @param {object} [args] — Optional payload object
   * @returns {Promise<any>}
   */
  function invoke(cmd, args) {
    var rt = runtime();
    if (rt === 'gossamer') {
      return window.__gossamer_invoke(cmd, args || {});
    }
    if (rt === 'tauri') {
      return window.__TAURI__.core.invoke(cmd, args || {});
    }
    return Promise.reject(
      new Error('No desktop runtime \u2014 "' + cmd + '" requires Gossamer or Tauri')
    );
  }

  // ── Listen ────────────────────────────────────────────────────────

  /**
   * Listen for backend events.
   *
   * - On Gossamer: calls `window.__gossamer_listen(event, handler)`
   * - On Tauri:    calls `window.__TAURI__.event.listen(event, handler)`
   * - On browser:  returns a no-op unlisten function
   *
   * @param {string} event     — The event name (e.g. "server-status")
   * @param {function} handler — Callback receiving `{ payload: ... }`
   * @returns {Promise<function>} Unlisten function
   */
  function listen(event, handler) {
    var rt = runtime();
    if (rt === 'gossamer') {
      if (typeof window.__gossamer_listen === 'function') {
        return window.__gossamer_listen(event, handler);
      }
      // Gossamer without event support — fall through to no-op
      console.warn('[gossamer-bridge] Gossamer event listener not available for:', event);
      return Promise.resolve(function () {});
    }
    if (rt === 'tauri') {
      return window.__TAURI__.event.listen(event, handler);
    }
    console.warn('[gossamer-bridge] No desktop runtime — ignoring event listener for:', event);
    return Promise.resolve(function () {});
  }

  // ── Check runtime availability ────────────────────────────────────

  /**
   * Whether any desktop runtime is available.
   * @returns {boolean}
   */
  function hasDesktopRuntime() {
    return runtime() !== 'browser';
  }

  /**
   * Human-readable name for the current runtime.
   * @returns {string}
   */
  function runtimeName() {
    var names = { gossamer: 'Gossamer', tauri: 'Tauri', browser: 'Browser' };
    return names[runtime()] || 'Unknown';
  }

  // ── Export ─────────────────────────────────────────────────────────

  var bridge = {
    invoke: invoke,
    listen: listen,
    runtime: runtime,
    hasDesktopRuntime: hasDesktopRuntime,
    runtimeName: runtimeName,
  };

  // Expose as window.GossamerBridge for script-tag usage
  if (typeof root !== 'undefined') {
    root.GossamerBridge = bridge;
  }

  // Also support ES module import if bundler is present
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = bridge;
  }
})(typeof window !== 'undefined' ? window : globalThis);
