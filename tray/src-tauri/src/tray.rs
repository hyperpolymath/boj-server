// SPDX-License-Identifier: PMPL-1.0-or-later
//! System tray setup and menu handling for the BoJ Node Operator.

use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle,
};

/// Build and register the system tray icon with its context menu.
pub fn setup_tray(handle: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let show_item = MenuItem::with_id(handle, "show", "Show Dashboard", true, None::<&str>)?;
    let status_item = MenuItem::with_id(handle, "status", "Status: checking…", false, None::<&str>)?;
    let restart_item = MenuItem::with_id(handle, "restart", "Restart Server", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(handle, "quit", "Quit", true, None::<&str>)?;

    let menu = Menu::with_items(
        handle,
        &[&show_item, &status_item, &restart_item, &quit_item],
    )?;

    TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("BoJ Server — Node Operator")
        .on_menu_event(move |app, event| match event.id.as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "restart" => {
                let handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    let _ = crate::server::restart().await;
                    // Give it a moment then refresh status
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    if let Ok(status) = crate::server::fetch_status().await {
                        use tauri::Emitter;
                        let _ = handle.emit("server-status", &status);
                    }
                });
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray_icon, event| {
            if let tauri::tray::TrayIconEvent::Click { .. } = event {
                if let Some(window) = tray_icon.app_handle().get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        })
        .build(handle)?;

    Ok(())
}
