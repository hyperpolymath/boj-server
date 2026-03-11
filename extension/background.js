// SPDX-License-Identifier: MPL-2.0
// (PMPL-1.0-or-later preferred; MPL-2.0 required for browser extension stores)

/// Background service worker — polls boj-server health and updates
/// the extension badge to reflect current server status.

const SERVER_URL = "http://localhost:7700";
const POLL_INTERVAL_MINUTES = 1;

/// Fetch server health and update the badge icon/text.
async function pollHealth() {
  try {
    const resp = await fetch(`${SERVER_URL}/health`, {
      signal: AbortSignal.timeout(3000),
    });

    if (resp.ok) {
      const status = await resp.json();
      await chrome.action.setBadgeBackgroundColor({ color: "#4ecca3" });
      await chrome.action.setBadgeText({ text: "ON" });
      // Store latest status for the popup to read immediately
      await chrome.storage.local.set({ lastStatus: status, lastPoll: Date.now() });
    } else {
      await setOfflineBadge();
    }
  } catch (_err) {
    await setOfflineBadge();
  }
}

async function setOfflineBadge() {
  await chrome.action.setBadgeBackgroundColor({ color: "#e74c3c" });
  await chrome.action.setBadgeText({ text: "OFF" });
  await chrome.storage.local.set({
    lastStatus: {
      healthy: false,
      uptime_secs: 0,
      cartridges_loaded: 0,
      peers_connected: 0,
      requests_served: 0,
    },
    lastPoll: Date.now(),
  });
}

// Poll on alarm
chrome.alarms.create("health-poll", { periodInMinutes: POLL_INTERVAL_MINUTES });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "health-poll") {
    pollHealth();
  }
});

// Poll immediately on install/startup
chrome.runtime.onInstalled.addListener(() => pollHealth());
chrome.runtime.onStartup.addListener(() => pollHealth());

// Allow popup to request an immediate refresh
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === "poll-now") {
    pollHealth().then(() => sendResponse({ ok: true }));
    return true; // async response
  }
});
