// SPDX-License-Identifier: PMPL-1.0-or-later
//! Binary entry point for the BoJ Node Operator tray application.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    boj_tray_lib::run();
}
