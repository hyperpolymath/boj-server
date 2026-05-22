// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// toolchain-mcp/mod.js -- Toolchain orchestrator cartridge.
//
// Mints, provisions, and configures language toolchains composed from the
// generic toolserver cartridges: lsp-mcp, dap-mcp, lang-mcp, bsp-mcp.
// Integrates with PanLL panels via Groove and supports collaborative Burble
// sessions for pair-debugging and pair-programming workflows.
//
// Toolchain lifecycle:
//   toolchain_mint → toolchain_provision → toolchain_configure
//     → (work: LSP/DAP/BSP/lang operations via their own cartridges)
//     → toolchain_groove_bind (optional — connects to a PanLL panel)
//     → toolchain_burble_session (optional — starts collaborative session)
//     → toolchain_stop
//
// Auth: None required (Groove/Burble auth delegated to those systems).
//
// Usage: import { handleTool } from "./mod.js";

// ---------------------------------------------------------------------------
// Language → default server command map
// Operators can override any of these in toolchain_provision.
// ---------------------------------------------------------------------------

const DEFAULT_COMMANDS = {
  affinescript:    { lsp: "affinescript server --stdio", dap: null,          bsp: null,       lang: "affinescript" },
  eclexia:         { lsp: "eclexia server --stdio",      dap: null,          bsp: null,       lang: "eclexia" },
  rust:            { lsp: "rust-analyzer",               dap: "codelldb",    bsp: "cargo-bsp",lang: null },
  ocaml:           { lsp: "ocamllsp",                    dap: null,          bsp: null,       lang: null },
  ephapax:         { lsp: "ephapax server --stdio",      dap: null,          bsp: null,       lang: "ephapax" },
  mylang:          { lsp: null,                          dap: null,          bsp: null,       lang: "mylang" },
  wokelang:        { lsp: null,                          dap: null,          bsp: null,       lang: "wokelang" },
  julia_the_viper: { lsp: "julia-the-viper server",      dap: null,          bsp: null,       lang: "julia_the_viper" },
};

// ---------------------------------------------------------------------------
// Toolchain registry
// ---------------------------------------------------------------------------

/**
 * Toolchain entry:
 *   id, language, workspace_root, servers (lsp/dap/bsp/lang flags),
 *   sessions { lsp_session_id, dap_session_id, bsp_session_id, lang_session_id },
 *   state: minted | provisioning | ready | error | stopped,
 *   config, groove_binding, burble_room
 */
const TOOLCHAINS = new Map();

function newToolchainId() {
  return `tc_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
}

function getToolchain(toolchain_id) {
  const tc = TOOLCHAINS.get(toolchain_id);
  if (!tc) throw Object.assign(new Error(`Unknown toolchain: ${toolchain_id}`), { status: 404 });
  return tc;
}

// ---------------------------------------------------------------------------
// BoJ cartridge call helper
// Calls sibling cartridge handlers by importing them dynamically.
// In production the BoJ server routes these; here we simulate via dynamic import.
// ---------------------------------------------------------------------------

async function callCartridge(cartridgeName, toolName, args) {
  try {
    const mod = await import(`../${cartridgeName}/mod.js`);
    return await mod.handleTool(toolName, args);
  } catch (e) {
    return { status: 500, data: { error: `Cartridge ${cartridgeName} error: ${e.message}` } };
  }
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // -- toolchain_mint ------------------------------------------------------
    case "toolchain_mint": {
      const { language, workspace_root, servers = ["lsp", "dap", "bsp", "lang"], name } = args;
      const defaults = DEFAULT_COMMANDS[language] ?? { lsp: null, dap: null, bsp: null, lang: null };
      // Discover which servers are actually available for this language
      const available = servers.filter(s => defaults[s] !== null || s === "lang");
      const toolchain_id = newToolchainId();
      TOOLCHAINS.set(toolchain_id, {
        id: toolchain_id,
        name: name ?? `${language}-toolchain`,
        language,
        workspace_root,
        servers: available,
        sessions: {},
        state: "minted",
        config: {},
        groove_binding: null,
        burble_room: null,
        defaults,
      });
      return {
        status: 200,
        data: {
          toolchain_id,
          language,
          workspace_root,
          available_servers: available,
          message: `Toolchain minted. Call toolchain_provision to start servers.`,
        },
      };
    }

    // -- toolchain_provision -------------------------------------------------
    case "toolchain_provision": {
      const { toolchain_id, lsp_command, dap_command, bsp_command } = args;
      const tc = getToolchain(toolchain_id);
      if (tc.state === "ready") return { status: 200, data: { message: "Already provisioned", toolchain_id } };
      tc.state = "provisioning";
      const results = {};
      const errors = [];

      // -- LSP
      if (tc.servers.includes("lsp")) {
        const cmd = lsp_command ?? tc.defaults.lsp;
        if (cmd) {
          const startRes = await callCartridge("lsp-mcp", "lsp_start", { command: cmd, workspace_root: tc.workspace_root });
          if (startRes.status === 200) {
            const sid = startRes.data.session_id;
            const rootUri = tc.workspace_root ? `file://${tc.workspace_root}` : "file:///";
            await callCartridge("lsp-mcp", "lsp_initialize", { session_id: sid, root_uri: rootUri });
            tc.sessions.lsp = sid;
            results.lsp = { session_id: sid, status: "started" };
          } else {
            errors.push(`lsp: ${startRes.data.error}`);
            results.lsp = { status: "failed", error: startRes.data.error };
          }
        }
      }

      // -- DAP
      if (tc.servers.includes("dap")) {
        const cmd = dap_command ?? tc.defaults.dap;
        if (cmd) {
          const startRes = await callCartridge("dap-mcp", "dap_start", { command: cmd, cwd: tc.workspace_root });
          if (startRes.status === 200) {
            const sid = startRes.data.session_id;
            await callCartridge("dap-mcp", "dap_initialize", { session_id: sid, adapter_id: tc.language });
            tc.sessions.dap = sid;
            results.dap = { session_id: sid, status: "started" };
          } else {
            errors.push(`dap: ${startRes.data.error}`);
            results.dap = { status: "failed", error: startRes.data.error };
          }
        }
      }

      // -- BSP
      if (tc.servers.includes("bsp")) {
        const cmd = bsp_command ?? tc.defaults.bsp;
        if (cmd) {
          const startRes = await callCartridge("bsp-mcp", "bsp_start", { command: cmd, workspace_root: tc.workspace_root });
          if (startRes.status === 200) {
            const sid = startRes.data.session_id;
            await callCartridge("bsp-mcp", "bsp_initialize", { session_id: sid });
            tc.sessions.bsp = sid;
            results.bsp = { session_id: sid, status: "started" };
          } else {
            errors.push(`bsp: ${startRes.data.error}`);
            results.bsp = { status: "failed", error: startRes.data.error };
          }
        }
      }

      // -- lang
      if (tc.servers.includes("lang") && tc.defaults.lang) {
        const createRes = await callCartridge("lang-mcp", "lang_session_create", {
          language: tc.defaults.lang,
          dialect_mode: "pure",
          name: tc.name,
        });
        if (createRes.status === 200) {
          tc.sessions.lang = createRes.data.session_id;
          results.lang = { session_id: createRes.data.session_id, status: "started" };
        } else {
          errors.push(`lang: ${createRes.data.error}`);
          results.lang = { status: "failed", error: createRes.data.error };
        }
      }

      tc.state = errors.length === 0 ? "ready" : (Object.keys(results).length > 0 ? "ready" : "error");
      return {
        status: errors.length === 0 ? 200 : 207,
        data: { toolchain_id, state: tc.state, servers: results, errors },
      };
    }

    // -- toolchain_configure -------------------------------------------------
    case "toolchain_configure": {
      const { toolchain_id, settings } = args;
      const tc = getToolchain(toolchain_id);
      // Merge settings into config — deep merge one level
      for (const [k, v] of Object.entries(settings)) {
        tc.config[k] = typeof v === "object" && !Array.isArray(v)
          ? { ...(tc.config[k] ?? {}), ...v }
          : v;
      }
      return { status: 200, data: { toolchain_id, config: tc.config } };
    }

    // -- toolchain_status ----------------------------------------------------
    case "toolchain_status": {
      const { toolchain_id } = args;
      if (toolchain_id) {
        const tc = getToolchain(toolchain_id);
        return {
          status: 200,
          data: {
            toolchain_id: tc.id,
            name: tc.name,
            language: tc.language,
            workspace_root: tc.workspace_root,
            state: tc.state,
            sessions: tc.sessions,
            groove_binding: tc.groove_binding,
            burble_room: tc.burble_room,
            config: tc.config,
          },
        };
      }
      // All toolchains
      const all = [...TOOLCHAINS.values()].map(tc => ({
        toolchain_id: tc.id,
        name: tc.name,
        language: tc.language,
        state: tc.state,
        groove_binding: tc.groove_binding,
        burble_room: tc.burble_room,
      }));
      return { status: 200, data: { toolchains: all, count: all.length } };
    }

    // -- toolchain_list ------------------------------------------------------
    case "toolchain_list": {
      const all = [...TOOLCHAINS.values()].map(tc => ({
        toolchain_id: tc.id,
        name: tc.name,
        language: tc.language,
        workspace_root: tc.workspace_root,
        state: tc.state,
        servers: tc.servers,
        groove_binding: tc.groove_binding,
        burble_room: tc.burble_room,
      }));
      return { status: 200, data: { toolchains: all, count: all.length } };
    }

    // -- toolchain_groove_bind -----------------------------------------------
    case "toolchain_groove_bind": {
      const { toolchain_id, groove_endpoint, panel_id } = args;
      const tc = getToolchain(toolchain_id);
      // Register the toolchain with the Groove endpoint.
      // The Groove protocol is universal plug-and-play; we emit a binding descriptor
      // that Groove-aware panels can discover.  Actual Groove handshake is handled
      // by the Groove cartridge when it is present.
      tc.groove_binding = {
        endpoint: groove_endpoint,
        panel_id: panel_id ?? null,
        bound_at: new Date().toISOString(),
        descriptor: {
          type: "toolchain",
          id: toolchain_id,
          language: tc.language,
          capabilities: Object.keys(tc.sessions),
          workspace_root: tc.workspace_root,
        },
      };
      return {
        status: 200,
        data: {
          toolchain_id,
          groove_binding: tc.groove_binding,
          message: `Toolchain bound to Groove endpoint: ${groove_endpoint}`,
        },
      };
    }

    // -- toolchain_burble_session --------------------------------------------
    case "toolchain_burble_session": {
      const { toolchain_id, room, role } = args;
      const tc = getToolchain(toolchain_id);
      // Burble sessions enable collaborative pair-debugging / pair-programming.
      // We generate a room name and record the binding.  The Burble cartridge
      // (when present) handles the actual WebRTC signalling.
      const roomName = room ?? `toolchain-${toolchain_id.slice(0, 8)}-${Date.now()}`;
      const sessionRole = role ?? (room ? "guest" : "host");
      tc.burble_room = {
        room: roomName,
        role: sessionRole,
        created_at: new Date().toISOString(),
        toolchain_id,
        language: tc.language,
        shared_sessions: { ...tc.sessions },
      };
      return {
        status: 200,
        data: {
          toolchain_id,
          room: roomName,
          role: sessionRole,
          message: `Burble ${sessionRole === "host" ? "room created" : "room joined"}: ${roomName}`,
          burble_binding: tc.burble_room,
        },
      };
    }

    // -- toolchain_stop ------------------------------------------------------
    case "toolchain_stop": {
      const { toolchain_id } = args;
      const tc = getToolchain(toolchain_id);
      const results = {};

      if (tc.sessions.lsp) {
        const r = await callCartridge("lsp-mcp", "lsp_stop", { session_id: tc.sessions.lsp });
        results.lsp = r.status === 200 ? "stopped" : r.data.error;
        delete tc.sessions.lsp;
      }
      if (tc.sessions.dap) {
        const r = await callCartridge("dap-mcp", "dap_stop", { session_id: tc.sessions.dap, terminate_debuggee: true });
        results.dap = r.status === 200 ? "stopped" : r.data.error;
        delete tc.sessions.dap;
      }
      if (tc.sessions.bsp) {
        const r = await callCartridge("bsp-mcp", "bsp_stop", { session_id: tc.sessions.bsp });
        results.bsp = r.status === 200 ? "stopped" : r.data.error;
        delete tc.sessions.bsp;
      }
      if (tc.sessions.lang) {
        const r = await callCartridge("lang-mcp", "lang_session_close", { session_id: tc.sessions.lang });
        results.lang = r.status === 200 ? "stopped" : r.data.error;
        delete tc.sessions.lang;
      }

      tc.state = "stopped";
      TOOLCHAINS.delete(toolchain_id);
      return { status: 200, data: { toolchain_id, stopped: true, servers: results } };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
