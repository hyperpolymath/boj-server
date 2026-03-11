// SPDX-License-Identifier: MPL-2.0
// (PMPL-1.0-or-later preferred; MPL-2.0 required for browser extension stores)

/// Popup script — renders the monitoring dashboard by fetching
/// data from the local boj-server REST API.

const DEFAULT_SERVER_URL = "http://localhost:7700";

// ── Helpers ──────────────────────────────────────────────────────

function formatUptime(secs) {
  if (secs === 0) return "--";
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m`;
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  return `${h}h ${m}m`;
}

function formatRequests(n) {
  if (n === 0) return "--";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return String(n);
}

async function getServerUrl() {
  const result = await chrome.storage.local.get("serverUrl");
  return result.serverUrl || DEFAULT_SERVER_URL;
}

async function apiFetch(path, options = {}) {
  const base = await getServerUrl();
  const resp = await fetch(`${base}${path}`, {
    signal: AbortSignal.timeout(5000),
    ...options,
  });
  return resp;
}

// ── Tab switching ────────────────────────────────────────────────

document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
    document.querySelectorAll(".tab-content").forEach((c) => c.classList.remove("active"));
    tab.classList.add("active");
    document.getElementById(`tab-${tab.dataset.tab}`).classList.add("active");
  });
});

// ── Status rendering ─────────────────────────────────────────────

function renderStatus(status) {
  const dot = document.getElementById("status-dot");
  dot.className = "status-dot " + (status.healthy ? "healthy" : "unhealthy");

  const uptimeEl = document.getElementById("uptime");
  const cartEl = document.getElementById("cartridges-count");
  const peersEl = document.getElementById("peers-count");
  const reqEl = document.getElementById("requests-count");

  uptimeEl.textContent = formatUptime(status.uptime_secs);
  uptimeEl.className = "value" + (status.healthy ? "" : " offline");
  cartEl.textContent = status.cartridges_loaded || "--";
  peersEl.textContent = status.peers_connected || "--";
  reqEl.textContent = formatRequests(status.requests_served);
}

async function fetchAndRenderStatus() {
  try {
    const resp = await apiFetch("/health");
    if (resp.ok) {
      const status = await resp.json();
      renderStatus(status);
      return status;
    }
  } catch (_err) {
    // fall through
  }
  renderStatus({
    healthy: false,
    uptime_secs: 0,
    cartridges_loaded: 0,
    peers_connected: 0,
    requests_served: 0,
  });
  return null;
}

// ── Resource bars ────────────────────────────────────────────────

async function fetchAndRenderResources() {
  try {
    const resp = await apiFetch("/api/prefs");
    if (resp.ok) {
      const prefs = await resp.json();
      const cpuBar = document.getElementById("cpu-bar");
      const memBar = document.getElementById("mem-bar");
      const bwBar = document.getElementById("bw-bar");
      const cpuVal = document.getElementById("cpu-val");
      const memVal = document.getElementById("mem-val");
      const bwVal = document.getElementById("bw-val");

      cpuBar.style.width = prefs.cpu_percent + "%";
      cpuVal.textContent = prefs.cpu_percent + "%";

      // Memory bar: assume 4096 MB max for display
      const memPct = Math.min(100, (prefs.memory_mb / 4096) * 100);
      memBar.style.width = memPct + "%";
      memVal.textContent = prefs.memory_mb + " MB";

      if (prefs.bandwidth_kbps === 0) {
        bwBar.style.width = "100%";
        bwVal.textContent = "Unlimited";
      } else {
        const bwPct = Math.min(100, (prefs.bandwidth_kbps / 10000) * 100);
        bwBar.style.width = bwPct + "%";
        bwVal.textContent = prefs.bandwidth_kbps + " kbps";
      }
    }
  } catch (_err) {
    // Leave bars at default
  }
}

// ── Cartridges ───────────────────────────────────────────────────

function renderCartridges(cartridges) {
  const list = document.getElementById("cartridge-list");
  if (!cartridges || cartridges.length === 0) {
    list.innerHTML = '<div class="empty-msg">No cartridges loaded</div>';
    return;
  }

  list.innerHTML = cartridges
    .map(
      (c) => `
    <div class="cartridge-item">
      <div class="toggle ${c.enabled ? "on" : ""}" data-name="${c.name}" data-enabled="${c.enabled}"></div>
      <span class="name">${c.name}</span>
      <span class="badge ${c.status}">${c.status}</span>
    </div>
  `
    )
    .join("");

  // Toggle handlers
  list.querySelectorAll(".toggle").forEach((el) => {
    el.addEventListener("click", async () => {
      const name = el.dataset.name;
      const newState = el.dataset.enabled !== "true";
      try {
        await apiFetch(`/api/cartridges/${name}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ enabled: newState }),
        });
        await fetchAndRenderCartridges();
      } catch (err) {
        console.error("Toggle failed:", err);
      }
    });
  });
}

async function fetchAndRenderCartridges() {
  try {
    const resp = await apiFetch("/api/cartridges");
    if (resp.ok) {
      const cartridges = await resp.json();
      renderCartridges(cartridges);
    } else {
      renderCartridges([]);
    }
  } catch (_err) {
    renderCartridges([]);
  }
}

// ── Settings ─────────────────────────────────────────────────────

async function loadSettings() {
  const url = await getServerUrl();
  document.getElementById("server-url").value = url;
}

document.getElementById("save-url-btn").addEventListener("click", async () => {
  const url = document.getElementById("server-url").value.trim();
  if (url) {
    await chrome.storage.local.set({ serverUrl: url });
    // Re-fetch everything with new URL
    fetchAndRenderStatus();
    fetchAndRenderResources();
    fetchAndRenderCartridges();
  }
});

// ── Actions ──────────────────────────────────────────────────────

document.getElementById("restart-btn").addEventListener("click", async () => {
  try {
    await apiFetch("/api/restart", { method: "POST" });
    // Brief delay then re-poll
    setTimeout(() => {
      fetchAndRenderStatus();
      chrome.runtime.sendMessage({ type: "poll-now" });
    }, 2000);
  } catch (err) {
    console.error("Restart failed:", err);
  }
});

document.getElementById("refresh-btn").addEventListener("click", () => {
  fetchAndRenderStatus();
  fetchAndRenderResources();
  fetchAndRenderCartridges();
  chrome.runtime.sendMessage({ type: "poll-now" });
});

// ── Initialise ───────────────────────────────────────────────────

// First try to load cached status from background worker (instant)
chrome.storage.local.get("lastStatus", (result) => {
  if (result.lastStatus) {
    renderStatus(result.lastStatus);
  }
});

// Then fetch fresh data
fetchAndRenderStatus();
fetchAndRenderResources();
fetchAndRenderCartridges();
loadSettings();
