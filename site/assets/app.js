// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// hypatia: allow cicd_rules/javascript_detected -- static-site interactivity; AffineScript browser/DOM bindings not yet shipped
//
// boj-server.net — install configurator + cartridge catalogue browser.
// Zero dependencies. Reads /catalog.json (a snapshot of the canonical registry).

(() => {
  "use strict";

  const REGISTRY = "https://github.com/hyperpolymath/boj-server-cartridges";
  const RAW_TREE = REGISTRY + "/tree/main/";

  // Capability bundles map to canonical registry buckets (group/bucket in catalog.json).
  const BUNDLES = {
    nesy:         { label: "NeSy",         buckets: [["cross-cutting", "nesy"]] },
    agentic:      { label: "Agentic",      buckets: [["cross-cutting", "agentic"]] },
    coordination: { label: "Coordination", buckets: [["cross-cutting", "orchestration"], ["cross-cutting", "fleet"]] },
  };

  // Base install command per client. Cartridges are fetched on demand by the host,
  // so the BASE command is constant; selection is surfaced separately (honest model).
  const CLIENTS = {
    "claude-code": {
      label: "Claude Code (CLI)",
      cmd: () => "claude mcp add boj-server -- npx -y @hyperpolymath/boj-server@latest",
    },
    "claude-desktop": {
      label: "Claude Desktop (claude_desktop_config.json)",
      cmd: () => JSON.stringify({
        mcpServers: { "boj-server": {
          command: "npx", args: ["-y", "@hyperpolymath/boj-server@latest"],
          env: { BOJ_URL: "http://localhost:7700" } } }
      }, null, 2),
    },
    "deno": {
      label: "Deno (preferred runtime — zero install)",
      cmd: () => "deno run --allow-net --allow-env --allow-read /path/to/boj-server/mcp-bridge/main.js",
    },
    "gemini": {
      label: "Gemini CLI (~/.gemini/settings.json)",
      cmd: () => JSON.stringify({
        mcpServers: { "boj-server": {
          command: "npx", args: ["-y", "@hyperpolymath/boj-server@latest"],
          env: { BOJ_URL: "http://localhost:7700" } } }
      }, null, 2),
    },
    "cursor": {
      label: "Cursor (.cursor/mcp.json)",
      cmd: () => JSON.stringify({
        mcpServers: { "boj-server": {
          command: "npx", args: ["-y", "@hyperpolymath/boj-server@latest"],
          env: { BOJ_URL: "http://localhost:7700" } } }
      }, null, 2),
    },
  };

  const $  = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  const state = {
    client: "claude-code",
    bundles: new Set(),
    picks: new Set(),   // individually picked cartridge names
    catalog: [],
    byName: new Map(),
  };

  // ---------- install + selection rendering ----------
  function bundleCartridges(key) {
    const def = BUNDLES[key];
    if (!def) return [];
    if (!state.catalog.length) {
      // static fallback if catalogue hasn't loaded yet
      return { nesy: ["ml-mcp", "nesy-mcp"],
               agentic: ["agent-mcp", "claude-agents-power-mcp", "claude-ai-mcp", "local-coord-mcp", "model-router-mcp"],
               coordination: ["stack-orchestrator-mcp", "fleet-mcp"] }[key] || [];
    }
    return state.catalog
      .filter(c => def.buckets.some(([g, b]) => c.group === g && c.bucket === b))
      .map(c => c.name);
  }

  function selectedNames() {
    const set = new Set(state.picks);
    state.bundles.forEach(b => bundleCartridges(b).forEach(n => set.add(n)));
    return Array.from(set).sort();
  }

  function renderInstall() {
    const client = CLIENTS[state.client];
    $("#output-label").textContent = client.label;
    $("#install-cmd").textContent = client.cmd();

    const names = selectedNames();
    const block = $("#selection-block");
    block.hidden = false;
    $("#sel-count").textContent = String(names.length);
    if (names.length === 0) {
      $("#sel-list").textContent = "# add bundles or pick from the catalogue ↓";
    } else {
      $("#sel-list").textContent =
        "# Fetched on demand from the registry:\n# " + REGISTRY + "\n" +
        names.join("\n");
    }
  }

  // ---------- catalogue rendering ----------
  function cardTemplate(c) {
    const li = document.createElement("li");
    li.className = "card";
    li.dataset.name = c.name;

    const top = document.createElement("div");
    top.className = "card-top";
    const name = document.createElement("span");
    name.className = "card-name"; name.textContent = c.name;
    const tier = document.createElement("span");
    tier.className = "card-tier"; tier.textContent = c.tier;
    top.append(name, tier);

    const desc = document.createElement("p");
    desc.className = "card-desc"; desc.textContent = c.description || "—";

    const meta = document.createElement("div");
    meta.className = "card-meta";
    const grp = document.createElement("span"); grp.textContent = c.bucket;
    meta.append(grp);
    (c.protocols || []).slice(0, 3).forEach(p => {
      const s = document.createElement("span"); s.textContent = p; meta.append(s);
    });
    if (c.toolCount) { const s = document.createElement("span"); s.textContent = c.toolCount + " tools"; meta.append(s); }

    const actions = document.createElement("div");
    actions.className = "card-actions";
    const add = document.createElement("button");
    add.type = "button"; add.className = "card-add";
    const pressed = state.picks.has(c.name);
    add.setAttribute("aria-pressed", pressed ? "true" : "false");
    add.textContent = pressed ? "Added ✓" : "+ Add";
    add.addEventListener("click", () => togglePick(c.name, add));
    const src = document.createElement("a");
    src.className = "card-src"; src.href = RAW_TREE + c.path; src.textContent = "manifest ↗";
    src.rel = "noopener";
    actions.append(add, src);

    li.append(top, desc, meta, actions);
    return li;
  }

  function togglePick(nm, btn) {
    if (state.picks.has(nm)) { state.picks.delete(nm); btn.setAttribute("aria-pressed", "false"); btn.textContent = "+ Add"; }
    else { state.picks.add(nm); btn.setAttribute("aria-pressed", "true"); btn.textContent = "Added ✓"; }
    renderInstall();
  }

  function applyFilters() {
    const q = $("#cat-search").value.trim().toLowerCase();
    const grp = $("#cat-group").value;
    const tier = $("#cat-tier").value;
    const list = $("#cat-list");
    list.replaceChildren();
    const matches = state.catalog.filter(c => {
      if (grp && (c.group + "/" + c.bucket) !== grp) return false;
      if (tier && c.tier !== tier) return false;
      if (q && !(c.name.toLowerCase().includes(q) || (c.description || "").toLowerCase().includes(q))) return false;
      return true;
    });
    const frag = document.createDocumentFragment();
    matches.forEach(c => frag.append(cardTemplate(c)));
    list.append(frag);
    $("#cat-status").textContent =
      `${matches.length} of ${state.catalog.length} cartridges` +
      (grp || tier || q ? " (filtered)" : "");
  }

  function populateGroups() {
    const sel = $("#cat-group");
    const groups = Array.from(new Set(state.catalog.map(c => c.group + "/" + c.bucket))).sort();
    groups.forEach(g => {
      const o = document.createElement("option");
      o.value = g; o.textContent = g; sel.append(o);
    });
  }

  // ---------- clipboard ----------
  async function copy(btn) {
    const el = document.getElementById(btn.dataset.target);
    if (!el) return;
    try {
      await navigator.clipboard.writeText(el.textContent);
      const prev = btn.textContent;
      btn.textContent = "Copied ✓"; btn.classList.add("copied");
      setTimeout(() => { btn.textContent = prev; btn.classList.remove("copied"); }, 1400);
    } catch { /* clipboard unavailable; selection still possible manually */ }
  }

  // ---------- wiring ----------
  function init() {
    // client tabs
    $$("#clients [role=tab]").forEach(tab => {
      tab.addEventListener("click", () => {
        $$("#clients [role=tab]").forEach(t => t.setAttribute("aria-selected", "false"));
        tab.setAttribute("aria-selected", "true");
        state.client = tab.dataset.client;
        renderInstall();
      });
    });
    // bundle checkboxes
    $$("#bundles input[name=bundle]").forEach(cb => {
      cb.addEventListener("change", () => {
        if (cb.checked) state.bundles.add(cb.value); else state.bundles.delete(cb.value);
        renderInstall();
      });
    });
    // copy buttons
    $$(".copy").forEach(b => b.addEventListener("click", () => copy(b)));
    // catalogue filters
    ["cat-search", "cat-group", "cat-tier"].forEach(id => {
      const el = document.getElementById(id);
      el.addEventListener(id === "cat-search" ? "input" : "change", applyFilters);
    });

    renderInstall();
    loadCatalogue();
  }

  async function loadCatalogue() {
    try {
      const res = await fetch("/catalog.json", { cache: "no-cache" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      const data = await res.json();
      state.catalog = (data.cartridges || []).sort((a, b) => a.name.localeCompare(b.name));
      state.catalog.forEach(c => state.byName.set(c.name, c));
      const total = state.catalog.length;
      $("#cat-total").textContent = String(total);
      $("#foot-count").textContent = String(total);
      if (data.generated) $("#foot-date").textContent = data.generated;
      populateGroups();
      applyFilters();
      renderInstall(); // bundles now resolve against real catalogue
    } catch (e) {
      $("#cat-status").textContent =
        "Could not load the catalogue snapshot. Browse the registry on GitHub instead.";
      const a = document.createElement("a");
      a.href = REGISTRY + "/tree/main/cartridges"; a.textContent = " Open registry ↗";
      $("#cat-status").append(a);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
