// SPDX-License-Identifier: PMPL-1.0-or-later
//! BoJ Node Operator — system tray application for boj-server.
//!
//! Provides a desktop interface for volunteer node operators to manage
//! their boj-server instance, control resource allocation, subscribe
//! to cartridge catalogues, and monitor federation status.

#![forbid(unsafe_code)]
mod server;
mod tray;

use tauri::Manager;

/// Server health status, polled periodically.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ServerStatus {
    pub healthy: bool,
    pub uptime_secs: u64,
    pub cartridges_loaded: u32,
    pub peers_connected: u32,
    pub requests_served: u64,
}

/// Resource allocation preferences (BOINC-style).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ResourcePrefs {
    pub cpu_percent: u8,
    pub memory_mb: u32,
    pub bandwidth_kbps: u32,
    pub run_when: RunSchedule,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
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

/// Cartridge subscription entry.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CartridgeSubscription {
    pub name: String,
    pub source: String, // GitHub URL or registry ID
    pub enabled: bool,
    pub status: String, // "downloading", "ready", "error", "disabled"
}

// ── Tauri commands (called from frontend) ──────────────────────────

#[tauri::command]
async fn get_server_status() -> Result<ServerStatus, String> {
    server::fetch_status().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_resource_prefs() -> Result<ResourcePrefs, String> {
    Ok(server::load_prefs().unwrap_or_default())
}

#[tauri::command]
async fn set_resource_prefs(prefs: ResourcePrefs) -> Result<(), String> {
    server::save_prefs(&prefs).map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_cartridges() -> Result<Vec<CartridgeSubscription>, String> {
    server::fetch_cartridges().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn add_cartridge_source(url: String) -> Result<CartridgeSubscription, String> {
    server::add_cartridge(&url).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn toggle_cartridge(name: String, enabled: bool) -> Result<(), String> {
    server::toggle_cartridge(&name, enabled)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn restart_server() -> Result<(), String> {
    server::restart().await.map_err(|e| e.to_string())
}

// ── App entry point ────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            // Build system tray
            tray::setup_tray(app.handle())?;

            // Start background health poller
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                server::health_poll_loop(handle).await;
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_server_status,
            get_resource_prefs,
            set_resource_prefs,
            get_cartridges,
            add_cartridge_source,
            toggle_cartridge,
            restart_server,
        ])
        .run(tauri::generate_context!())
        .expect("error while running boj-tray");
}
