// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// (MPL-2.0 preferred; MPL-2.0 required for boj-server ecosystem)
//
//! # BoJ Node Operator — Gossamer tray application
//!
//! System tray / desktop dashboard for volunteer node operators to manage
//! their boj-server instance. Provides resource allocation sliders,
//! cartridge subscription management, and live health monitoring.
//!
//! ## Architecture
//!
//! - **Frontend**: `index.html` + `gossamer-bridge.js` (embedded via `include_str!`)
//! - **Backend**: gossamer-rs webview shell with 7 registered IPC commands
//! - **Server**: communicates with `boj-server` at `http://[::1]:7700`
//!
//! ## Commands
//!
//! | Command               | Direction        | Description                        |
//! |-----------------------|------------------|------------------------------------|
//! | `get_server_status`   | GET /health      | Poll server health                 |
//! | `get_resource_prefs`  | Local file I/O   | Read `~/.config/boj-node/prefs.json` |
//! | `set_resource_prefs`  | Local file I/O   | Write preferences to disk          |
//! | `get_cartridges`      | GET /api/cartridges  | List loaded cartridges         |
//! | `add_cartridge_source`| POST /api/cartridges | Subscribe to a new source      |
//! | `toggle_cartridge`    | PATCH /api/cartridges/{name} | Enable/disable cartridge |
//! | `restart_server`      | POST /api/restart | Restart the boj-server process    |

#![forbid(unsafe_code)]
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod server;

use gossamer_rs::App;
use serde::{Deserialize, Serialize};

// ── Data structures ──────────────────────────────────────────────────

/// Server health status, returned by the `/health` endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerStatus {
    pub healthy: bool,
    pub uptime_secs: u64,
    pub cartridges_loaded: u32,
    pub peers_connected: u32,
    pub requests_served: u64,
}

/// Resource allocation preferences (BOINC-style).
///
/// Persisted locally to `~/.config/boj-node/prefs.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourcePrefs {
    pub cpu_percent: u8,
    pub memory_mb: u32,
    pub bandwidth_kbps: u32,
    pub run_when: RunSchedule,
}

/// When the node operator wants boj-server to be active.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum RunSchedule {
    Always,
    IdleOnly,
    Scheduled { start_hour: u8, end_hour: u8 },
}

impl Default for ResourcePrefs {
    fn default() -> Self {
        Self {
            cpu_percent: 50,
            memory_mb: 512,
            bandwidth_kbps: 0, // unlimited
            run_when: RunSchedule::Always,
        }
    }
}

/// Cartridge subscription entry from the server's cartridge registry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CartridgeSubscription {
    pub name: String,
    pub source: String,  // GitHub URL or registry ID
    pub enabled: bool,
    pub status: String,  // "downloading", "ready", "error", "disabled"
}

// ── Embedded frontend ────────────────────────────────────────────────

/// The tray dashboard HTML, embedded at compile time.
const INDEX_HTML: &str = include_str!("index.html");

/// The Gossamer/Tauri IPC bridge, embedded at compile time.
const BRIDGE_JS: &str = include_str!("gossamer-bridge.js");

// ── Entry point ──────────────────────────────────────────────────────

fn main() -> Result<(), gossamer_rs::Error> {
    let mut app = App::new("BoJ Node Operator", 420, 680)?;

    // ── Command 1: get_server_status ─────────────────────────────
    // Polls the local boj-server health endpoint.
    app.command("get_server_status", |_payload| {
        let status = server::fetch_status().unwrap_or(ServerStatus {
            healthy: false,
            uptime_secs: 0,
            cartridges_loaded: 0,
            peers_connected: 0,
            requests_served: 0,
        });
        serde_json::to_value(&status).map_err(|e| e.to_string())
    });

    // ── Command 2: get_resource_prefs ────────────────────────────
    // Reads the local preferences file, falling back to defaults.
    app.command("get_resource_prefs", |_payload| {
        let prefs = server::load_prefs().unwrap_or_default();
        serde_json::to_value(&prefs).map_err(|e| e.to_string())
    });

    // ── Command 3: set_resource_prefs ────────────────────────────
    // Writes the given preferences to disk.
    app.command("set_resource_prefs", |payload| {
        let prefs: ResourcePrefs = serde_json::from_value(
            payload.get("prefs").cloned().unwrap_or(payload.clone()),
        )
        .map_err(|e| format!("invalid prefs payload: {e}"))?;

        server::save_prefs(&prefs)?;
        Ok(serde_json::json!(null))
    });

    // ── Command 4: get_cartridges ────────────────────────────────
    // Fetches the cartridge list from the running server.
    app.command("get_cartridges", |_payload| {
        let cartridges = server::fetch_cartridges()?;
        serde_json::to_value(&cartridges).map_err(|e| e.to_string())
    });

    // ── Command 5: add_cartridge_source ──────────────────────────
    // Subscribes to a new cartridge source URL.
    app.command("add_cartridge_source", |payload| {
        let url = payload
            .get("url")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "missing 'url' field".to_string())?;

        let cartridge = server::add_cartridge(url)?;
        serde_json::to_value(&cartridge).map_err(|e| e.to_string())
    });

    // ── Command 6: toggle_cartridge ──────────────────────────────
    // Enables or disables a cartridge by name.
    app.command("toggle_cartridge", |payload| {
        let name = payload
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "missing 'name' field".to_string())?;
        let enabled = payload
            .get("enabled")
            .and_then(|v| v.as_bool())
            .ok_or_else(|| "missing 'enabled' field".to_string())?;

        server::toggle_cartridge(name, enabled)?;
        Ok(serde_json::json!(null))
    });

    // ── Command 7: restart_server ────────────────────────────────
    // Restarts the boj-server process via its management API.
    app.command("restart_server", |_payload| {
        server::restart()?;
        Ok(serde_json::json!(null))
    });

    // ── Load the frontend ────────────────────────────────────────
    // Inject the bridge JS inline before the closing </head> tag,
    // then load the combined HTML into the webview.
    let bridge_injection = format!(
        "<script>\n{BRIDGE_JS}\n</script>\n</head>"
    );
    let full_html = INDEX_HTML.replace("</head>", &bridge_injection);

    app.load_html(&full_html)?;
    app.run();

    Ok(())
}
