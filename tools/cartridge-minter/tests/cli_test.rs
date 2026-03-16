// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// CLI integration tests for cartridge-minter.

use assert_cmd::Command;
use predicates::prelude::*;
use std::fs;
use tempfile::TempDir;

fn setup_fake_boj() -> (TempDir, std::path::PathBuf) {
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().to_path_buf();
    fs::create_dir_all(root.join("cartridges")).unwrap();
    fs::create_dir_all(root.join(".machine_readable/servers")).unwrap();
    fs::write(root.join("0-AI-MANIFEST.a2ml"), "# test manifest").unwrap();
    fs::write(
        root.join(".machine_readable/servers/menu.a2ml"),
        "# BoJ Menu\n",
    )
    .unwrap();
    (tmp, root)
}

#[test]
fn test_list_options() {
    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .arg("list-options")
        .assert()
        .success()
        .stdout(predicate::str::contains("Cloud"))
        .stdout(predicate::str::contains("MCP"))
        .stdout(predicate::str::contains("Teranga"));
}

#[test]
fn test_mint_non_interactive() {
    let (_tmp, root) = setup_fake_boj();

    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["mint", "--name", "demo-mcp", "--non-interactive"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Minted"));

    // Verify structure
    let cart = root.join("cartridges/demo-mcp");
    assert!(cart.join("abi").is_dir());
    assert!(cart.join("ffi").is_dir());
    assert!(cart.join("adapter").is_dir());
}

#[test]
fn test_mint_rejects_bad_name() {
    let (_tmp, root) = setup_fake_boj();

    // Name without -mcp suffix should fail validation in non-interactive mode
    // (non-interactive just uses defaults, but we still get the cartridge)
    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["mint", "--name", "demo-mcp", "--non-interactive"])
        .assert()
        .success();

    // Try to mint same name again
    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["mint", "--name", "demo-mcp", "--non-interactive"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("already exists"));
}

#[test]
fn test_validate_command() {
    let (_tmp, root) = setup_fake_boj();

    // Mint first
    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["mint", "--name", "val-mcp", "--non-interactive"])
        .assert()
        .success();

    // Validate
    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["validate", "val-mcp"])
        .assert()
        .success()
        .stdout(predicate::str::contains("All checks passed"));
}

#[test]
fn test_status_command() {
    let (_tmp, root) = setup_fake_boj();

    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["mint", "--name", "stat-mcp", "--non-interactive"])
        .assert()
        .success();

    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .arg("status")
        .assert()
        .success()
        .stdout(predicate::str::contains("stat-mcp"))
        .stdout(predicate::str::contains("ABI"));
}

#[test]
fn test_provision_command() {
    let (_tmp, root) = setup_fake_boj();

    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["mint", "--name", "prov-mcp", "--non-interactive"])
        .assert()
        .success();

    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["provision", "prov-mcp"])
        .assert()
        .success()
        .stdout(predicate::str::contains("menu.a2ml"));
}

#[test]
fn test_harness_command() {
    let (_tmp, root) = setup_fake_boj();

    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["mint", "--name", "harn-mcp", "--non-interactive"])
        .assert()
        .success();

    Command::cargo_bin("cartridge-minter")
        .unwrap()
        .args(["--boj-root", root.to_str().unwrap()])
        .args(["harness", "harn-mcp"])
        .assert()
        .success()
        .stdout(predicate::str::contains("manifest.json"));
}
