// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// (MPL-2.0 preferred; MPL-2.0 required for boj-server ecosystem)
//
//! HTTP client for communicating with the local boj-server instance.
//!
//! All functions use [`reqwest::blocking::Client`] because gossamer-rs command
//! handlers are synchronous (`Fn(Value) -> Result<Value, String>`). Each call
//! creates a short-lived client with a per-operation timeout.

use crate::{CartridgeSubscription, ResourcePrefs, ServerStatus};
use std::path::PathBuf;
use std::time::Duration;

/// IPv6 loopback base URL for the local boj-server.
const BASE_URL: &str = "http://[::1]:7700";

// ── Timeout constants ────────────────────────────────────────────────

/// Timeout for health-check requests (fast, non-blocking poll).
const HEALTH_TIMEOUT: Duration = Duration::from_secs(3);

/// Timeout for cartridge list / toggle operations.
const CARTRIDGE_TIMEOUT: Duration = Duration::from_secs(5);

/// Timeout for adding a new cartridge source (may involve download).
const ADD_CARTRIDGE_TIMEOUT: Duration = Duration::from_secs(10);

/// Timeout for server restart command.
const RESTART_TIMEOUT: Duration = Duration::from_secs(5);

// ── HTTP client helpers ──────────────────────────────────────────────

/// Build a one-shot blocking client with the given timeout.
fn client(timeout: Duration) -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|e| format!("failed to build HTTP client: {e}"))
}

// ── Server communication ─────────────────────────────────────────────

/// Fetch server health status from the `/health` endpoint.
///
/// Returns a degraded status (healthy=false) when the server is unreachable
/// rather than propagating the error, so the UI always has something to display.
pub fn fetch_status() -> Result<ServerStatus, String> {
    let c = client(HEALTH_TIMEOUT)?;
    let resp = c
        .get(format!("{BASE_URL}/health"))
        .send()
        .map_err(|e| e.to_string())?;

    if resp.status().is_success() {
        resp.json::<ServerStatus>().map_err(|e| e.to_string())
    } else {
        Ok(ServerStatus {
            healthy: false,
            uptime_secs: 0,
            cartridges_loaded: 0,
            peers_connected: 0,
            requests_served: 0,
        })
    }
}

/// Fetch the list of loaded cartridges from the server.
pub fn fetch_cartridges() -> Result<Vec<CartridgeSubscription>, String> {
    let c = client(CARTRIDGE_TIMEOUT)?;
    let resp = c
        .get(format!("{BASE_URL}/api/cartridges"))
        .send()
        .map_err(|e| e.to_string())?;

    resp.json::<Vec<CartridgeSubscription>>()
        .map_err(|e| e.to_string())
}

/// Add a new cartridge source (GitHub URL or registry ID).
pub fn add_cartridge(url: &str) -> Result<CartridgeSubscription, String> {
    let c = client(ADD_CARTRIDGE_TIMEOUT)?;
    let resp = c
        .post(format!("{BASE_URL}/api/cartridges"))
        .json(&serde_json::json!({ "source": url }))
        .send()
        .map_err(|e| e.to_string())?;

    resp.json::<CartridgeSubscription>()
        .map_err(|e| e.to_string())
}

/// Enable or disable a cartridge by name.
pub fn toggle_cartridge(name: &str, enabled: bool) -> Result<(), String> {
    let c = client(CARTRIDGE_TIMEOUT)?;
    c.patch(format!("{BASE_URL}/api/cartridges/{name}"))
        .json(&serde_json::json!({ "enabled": enabled }))
        .send()
        .map_err(|e| e.to_string())?;

    Ok(())
}

/// Restart the boj-server process via its management endpoint.
pub fn restart() -> Result<(), String> {
    let c = client(RESTART_TIMEOUT)?;
    c.post(format!("{BASE_URL}/api/restart"))
        .send()
        .map_err(|e| e.to_string())?;

    Ok(())
}

// ── Local preferences persistence ────────────────────────────────────

/// Path to the local preferences file: `~/.config/boj-node/prefs.json`.
fn prefs_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("boj-node")
        .join("prefs.json")
}

/// Load resource preferences from disk.
///
/// Returns `Err` if the file does not exist or contains invalid JSON —
/// callers should fall back to `ResourcePrefs::default()`.
pub fn load_prefs() -> Result<ResourcePrefs, String> {
    let path = prefs_path();
    let data = std::fs::read_to_string(&path)
        .map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    serde_json::from_str(&data)
        .map_err(|e| format!("failed to parse prefs: {e}"))
}

/// Save resource preferences to disk.
///
/// Creates the parent directory (`~/.config/boj-node/`) if it does not exist.
pub fn save_prefs(prefs: &ResourcePrefs) -> Result<(), String> {
    let path = prefs_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create config dir: {e}"))?;
    }
    let data = serde_json::to_string_pretty(prefs)
        .map_err(|e| format!("failed to serialise prefs: {e}"))?;
    std::fs::write(&path, data)
        .map_err(|e| format!("failed to write {}: {e}", path.display()))
}
