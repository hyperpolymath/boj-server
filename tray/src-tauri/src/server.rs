// SPDX-License-Identifier: PMPL-1.0-or-later
//! HTTP client for communicating with the local boj-server instance.

use crate::{CartridgeSubscription, ResourcePrefs, ServerStatus};
use std::path::PathBuf;
use tauri::AppHandle;

const BASE_URL: &str = "http://[::1]:7700";

/// Fetch server health status from the `/health` endpoint.
pub async fn fetch_status() -> Result<ServerStatus, Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    let resp = client
        .get(format!("{BASE_URL}/health"))
        .timeout(std::time::Duration::from_secs(3))
        .send()
        .await?;

    if resp.status().is_success() {
        let status: ServerStatus = resp.json().await?;
        Ok(status)
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
pub async fn fetch_cartridges() -> Result<Vec<CartridgeSubscription>, Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    let resp = client
        .get(format!("{BASE_URL}/api/cartridges"))
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await?;

    let cartridges: Vec<CartridgeSubscription> = resp.json().await?;
    Ok(cartridges)
}

/// Add a new cartridge source (GitHub URL or registry ID).
pub async fn add_cartridge(
    url: &str,
) -> Result<CartridgeSubscription, Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{BASE_URL}/api/cartridges"))
        .json(&serde_json::json!({ "source": url }))
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await?;

    let cartridge: CartridgeSubscription = resp.json().await?;
    Ok(cartridge)
}

/// Enable or disable a cartridge by name.
pub async fn toggle_cartridge(
    name: &str,
    enabled: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    client
        .patch(format!("{BASE_URL}/api/cartridges/{name}"))
        .json(&serde_json::json!({ "enabled": enabled }))
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await?;

    Ok(())
}

/// Restart the boj-server process via its management endpoint.
pub async fn restart() -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    client
        .post(format!("{BASE_URL}/api/restart"))
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await?;

    Ok(())
}

// ── Local preferences persistence ────────────────────────────────

/// Path to the local preferences file.
fn prefs_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("boj-node")
        .join("prefs.json")
}

/// Load resource preferences from disk.
pub fn load_prefs() -> Result<ResourcePrefs, Box<dyn std::error::Error>> {
    let path = prefs_path();
    let data = std::fs::read_to_string(path)?;
    let prefs: ResourcePrefs = serde_json::from_str(&data)?;
    Ok(prefs)
}

/// Save resource preferences to disk.
pub fn save_prefs(prefs: &ResourcePrefs) -> Result<(), Box<dyn std::error::Error>> {
    let path = prefs_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let data = serde_json::to_string_pretty(prefs)?;
    std::fs::write(path, data)?;
    Ok(())
}

// ── Background health poller ─────────────────────────────────────

/// Polls the server health endpoint every 10 seconds and emits
/// status events to the frontend.
pub async fn health_poll_loop(handle: AppHandle) {
    use tauri::Emitter;

    loop {
        let status = match fetch_status().await {
            Ok(s) => s,
            Err(_) => ServerStatus {
                healthy: false,
                uptime_secs: 0,
                cartridges_loaded: 0,
                peers_connected: 0,
                requests_served: 0,
            },
        };

        // Emit to all windows — frontend listens on "server-status"
        let _ = handle.emit("server-status", &status);

        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
    }
}
