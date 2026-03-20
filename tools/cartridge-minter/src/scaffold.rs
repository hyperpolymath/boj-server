// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Scaffolder — creates, provisions, configures, and harnesses cartridges.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::config::CartridgeConfig;
use crate::templates;

/// Core scaffolding engine for cartridge operations.
pub struct Scaffolder {
    boj_root: PathBuf,
}

impl Scaffolder {
    pub fn new(boj_root: PathBuf) -> Self {
        Self { boj_root }
    }

    /// Mint: create the full 3-layer cartridge directory structure.
    pub fn mint(&self, cfg: &CartridgeConfig) -> io::Result<PathBuf> {
        let cart_dir = self.boj_root.join("cartridges").join(&cfg.name);

        if cart_dir.exists() {
            return Err(io::Error::other(format!(
                "Cartridge '{}' already exists at {}",
                cfg.name,
                cart_dir.display()
            )));
        }

        let pkg = cfg.idris_package_name();
        let ffi_name = cfg.ffi_name();

        // Create directory structure
        let abi_dir = cart_dir.join("abi").join(&pkg);
        let ffi_dir = cart_dir.join("ffi");
        let adapter_dir = cart_dir.join("adapter");

        fs::create_dir_all(&abi_dir)?;
        fs::create_dir_all(&ffi_dir)?;
        fs::create_dir_all(&adapter_dir)?;

        // Write Idris2 ABI
        let domain_mod = cfg.domain.idris_module_name();
        fs::write(
            abi_dir.join(format!("Safe{domain_mod}.idr")),
            templates::idris2_abi(cfg),
        )?;
        fs::write(
            cart_dir.join("abi").join(format!("{}.ipkg", cfg.name.replace('-', "_"))),
            templates::idris2_ipkg(cfg),
        )?;

        // Write Zig FFI
        fs::write(
            ffi_dir.join(format!("{ffi_name}_ffi.zig")),
            templates::zig_ffi(cfg),
        )?;
        fs::write(ffi_dir.join("build.zig"), templates::zig_build(cfg))?;

        // Write V-lang adapter
        fs::write(
            adapter_dir.join(format!("{ffi_name}_adapter.v")),
            templates::vlang_adapter(cfg),
        )?;

        // Write cartridge config
        cfg.save(&cart_dir)?;

        // Write README
        fs::write(cart_dir.join("README.adoc"), templates::readme(cfg))?;

        Ok(cart_dir)
    }

    /// Provision: wire the cartridge into BoJ menu and MCP bridge.
    pub fn provision(&self, cfg: &CartridgeConfig) -> Result<Vec<String>, String> {
        let mut updated = Vec::new();

        // Append to menu.a2ml
        let menu_path = self
            .boj_root
            .join(".machine_readable/servers/menu.a2ml");
        if menu_path.exists() {
            let entry = templates::menu_entry(cfg);
            let existing = fs::read_to_string(&menu_path)
                .map_err(|e| format!("Failed to read menu.a2ml: {e}"))?;

            // Check if cartridge already in menu
            if existing.contains(&format!("@cartridge(id=\"{}\")", cfg.name)) {
                return Err(format!("'{}' already in menu.a2ml", cfg.name));
            }

            // Append before the last @end or at the end
            let new_content = format!("{existing}\n{entry}");
            fs::write(&menu_path, new_content)
                .map_err(|e| format!("Failed to write menu.a2ml: {e}"))?;
            updated.push("menu.a2ml".to_string());
        }

        // Update MCP bridge offline menu (main.js)
        let bridge_path = self.boj_root.join("mcp-bridge/main.js");
        if bridge_path.exists() {
            let bridge_content = fs::read_to_string(&bridge_path)
                .map_err(|e| format!("Failed to read main.js: {e}"))?;

            // Look for the tier section to add to
            let tier_key = match cfg.tier {
                crate::config::MenuTier::Teranga => "tier_teranga",
                crate::config::MenuTier::Shield => "tier_shield",
                crate::config::MenuTier::Ayo => "tier_ayo",
            };

            // Add entry to the appropriate tier array in OFFLINE_MENU
            if !bridge_content.contains(&format!("\"{}\"", cfg.name)) {
                // Find the tier array and append
                let search = format!("\"{tier_key}\": [");
                if let Some(pos) = bridge_content.find(&search) {
                    let insert_pos = pos + search.len();
                    let entry = format!(
                        "\n      {{ name: \"{}\", version: \"{}\", status: \"Development\", domain: \"{}\" }},",
                        cfg.name, cfg.version, cfg.domain
                    );
                    let mut new_content = bridge_content.clone();
                    new_content.insert_str(insert_pos, &entry);
                    fs::write(&bridge_path, new_content)
                        .map_err(|e| format!("Failed to write main.js: {e}"))?;
                    updated.push("mcp-bridge/main.js".to_string());
                }
            }
        }

        if updated.is_empty() {
            Err("No files updated — provision targets not found".to_string())
        } else {
            Ok(updated)
        }
    }

    /// Configure: generate test stubs and benchmark scaffolding.
    pub fn configure(&self, cfg: &CartridgeConfig) -> Result<Vec<String>, String> {
        let cart_dir = self.boj_root.join("cartridges").join(&cfg.name);
        if !cart_dir.exists() {
            return Err(format!("Cartridge '{}' not found — run mint first", cfg.name));
        }

        let mut created = Vec::new();

        // Create test directory with integration test stub
        let test_dir = cart_dir.join("tests");
        fs::create_dir_all(&test_dir).map_err(|e| e.to_string())?;

        let test_content = format!(
            r#"#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Integration tests for {name} cartridge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
CART_DIR="$(dirname "$SCRIPT_DIR")"
FFI_DIR="$CART_DIR/ffi"

echo "=== {name} integration tests ==="

# Build FFI
echo "[1/3] Building FFI..."
cd "$FFI_DIR" && zig build 2>&1

# Run Zig unit tests
echo "[2/3] Running FFI unit tests..."
cd "$FFI_DIR" && zig build test 2>&1

# Validate Idris2 ABI (if idris2 available)
echo "[3/3] Checking ABI..."
if command -v idris2 &>/dev/null; then
    cd "$CART_DIR/abi" && idris2 --check {pkg}.Safe{domain_mod} 2>&1
    echo "  ABI: OK"
else
    echo "  ABI: SKIPPED (idris2 not in PATH)"
fi

echo ""
echo "All tests passed for {name}!"
"#,
            name = cfg.name,
            pkg = cfg.idris_package_name(),
            domain_mod = cfg.domain.idris_module_name(),
        );
        fs::write(test_dir.join("integration_test.sh"), test_content)
            .map_err(|e| e.to_string())?;

        // Make test script executable
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = fs::Permissions::from_mode(0o755);
            fs::set_permissions(test_dir.join("integration_test.sh"), perms)
                .map_err(|e| e.to_string())?;
        }

        created.push(format!("tests/integration_test.sh"));

        // Create benchmark stub
        let bench_dir = cart_dir.join("benchmarks");
        fs::create_dir_all(&bench_dir).map_err(|e| e.to_string())?;

        let bench_content = format!(
            r#"#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Benchmarks for {name} cartridge.
set -euo pipefail

echo "=== {name} benchmarks ==="

cd "$(dirname "${{BASH_SOURCE[0]}}")/../ffi"

# Build with ReleaseFast for benchmarking
zig build -Doptimize=ReleaseFast 2>&1

echo "Session open/close cycle (1000 iterations):"
time for i in $(seq 1 1000); do
    # This would call the FFI benchmark binary
    true
done

echo ""
echo "Benchmark placeholder — implement real benchmarks in Zig test blocks"
echo "or via the V-lang adapter HTTP benchmark tool."
"#,
            name = cfg.name,
        );
        fs::write(bench_dir.join("quick-bench.sh"), bench_content)
            .map_err(|e| e.to_string())?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = fs::Permissions::from_mode(0o755);
            fs::set_permissions(bench_dir.join("quick-bench.sh"), perms)
                .map_err(|e| e.to_string())?;
        }

        created.push(format!("benchmarks/quick-bench.sh"));

        Ok(created)
    }

    /// Harness: generate PanLL panel manifest and panel definition.
    pub fn harness(&self, cfg: &CartridgeConfig) -> Result<String, String> {
        let cart_dir = self.boj_root.join("cartridges").join(&cfg.name);
        if !cart_dir.exists() {
            return Err(format!("Cartridge '{}' not found — run mint first", cfg.name));
        }

        let ffi_name = cfg.ffi_name();
        let panels_dir = cart_dir.join("panels").join(&ffi_name);
        fs::create_dir_all(&panels_dir).map_err(|e| e.to_string())?;

        // Write manifest
        fs::write(
            cart_dir.join("panels/manifest.json"),
            templates::panel_manifest(cfg),
        )
        .map_err(|e| e.to_string())?;

        // Write panel definition
        fs::write(
            panels_dir.join("panel.json"),
            templates::panel_definition(cfg),
        )
        .map_err(|e| e.to_string())?;

        Ok(format!(
            "cartridges/{}/panels/manifest.json + panels/{}/panel.json",
            cfg.name, ffi_name
        ))
    }

    /// Generate harnesses for all cartridges that lack one.
    pub fn harness_all(&self) -> Result<usize, String> {
        let carts_dir = self.boj_root.join("cartridges");
        if !carts_dir.exists() {
            return Err("No cartridges directory found".to_string());
        }

        let mut count = 0;
        let entries = fs::read_dir(&carts_dir).map_err(|e| e.to_string())?;
        for entry in entries {
            let entry = entry.map_err(|e| e.to_string())?;
            let path = entry.path();
            if path.is_dir() {
                // SafePath-informed: file_name() can return None for root or
                // ".." paths; skip entries where the name cannot be extracted.
                let Some(os_name) = path.file_name() else {
                    continue;
                };
                let name = os_name.to_string_lossy().to_string();
                if !path.join("panels/manifest.json").exists() {
                    let cfg = CartridgeConfig::load_or_default(&self.boj_root, &name);
                    self.harness(&cfg)?;
                    count += 1;
                }
            }
        }
        Ok(count)
    }

    /// Validate a cartridge's structure and contents.
    pub fn validate(&self, name: &str) -> Result<Vec<(String, bool)>, String> {
        let cart_dir = self.boj_root.join("cartridges").join(name);
        if !cart_dir.exists() {
            return Err(format!("Cartridge '{name}' not found"));
        }

        let mut checks = Vec::new();

        // Check directory structure
        checks.push((
            "abi/ directory exists".to_string(),
            cart_dir.join("abi").is_dir(),
        ));
        checks.push((
            "ffi/ directory exists".to_string(),
            cart_dir.join("ffi").is_dir(),
        ));
        checks.push((
            "adapter/ directory exists".to_string(),
            cart_dir.join("adapter").is_dir(),
        ));

        // Check for .idr files in abi/
        let has_idr = has_files_with_extension(&cart_dir.join("abi"), "idr");
        checks.push(("Idris2 ABI files present".to_string(), has_idr));

        // Check for .zig files in ffi/
        let has_zig = has_files_with_extension(&cart_dir.join("ffi"), "zig");
        checks.push(("Zig FFI files present".to_string(), has_zig));

        // Check for .v files in adapter/
        let has_v = has_files_with_extension(&cart_dir.join("adapter"), "v");
        checks.push(("V-lang adapter files present".to_string(), has_v));

        // Check for build.zig
        checks.push((
            "ffi/build.zig exists".to_string(),
            cart_dir.join("ffi/build.zig").is_file(),
        ));

        // Check for .ipkg
        let has_ipkg = has_files_with_extension(&cart_dir.join("abi"), "ipkg");
        checks.push(("Idris2 .ipkg package file".to_string(), has_ipkg));

        // Check for %default total in .idr files
        let total_check = check_idris_totality(&cart_dir.join("abi"));
        checks.push(("%default total in all .idr files".to_string(), total_check));

        // Check for believe_me (must be absent)
        let no_believe = !check_for_unsafe_pattern(&cart_dir.join("abi"), "believe_me");
        checks.push(("No believe_me in ABI".to_string(), no_believe));

        // Check for assert_total (must be absent)
        let no_assert = !check_for_unsafe_pattern(&cart_dir.join("abi"), "assert_total");
        checks.push(("No assert_total in ABI".to_string(), no_assert));

        // Check for SPDX header
        let has_spdx = check_spdx_headers(&cart_dir);
        checks.push(("SPDX headers present".to_string(), has_spdx));

        // Check README
        checks.push((
            "README.adoc exists".to_string(),
            cart_dir.join("README.adoc").is_file(),
        ));

        Ok(checks)
    }

    /// Status of all cartridges.
    pub fn status(&self) -> Result<Vec<(String, bool, bool, bool)>, String> {
        let carts_dir = self.boj_root.join("cartridges");
        if !carts_dir.exists() {
            return Err("No cartridges directory found".to_string());
        }

        let mut entries = Vec::new();
        let dir_entries = fs::read_dir(&carts_dir).map_err(|e| e.to_string())?;
        for entry in dir_entries {
            let entry = entry.map_err(|e| e.to_string())?;
            let path = entry.path();
            if path.is_dir() {
                // SafePath-informed: skip entries without extractable names.
                let Some(os_name) = path.file_name() else {
                    continue;
                };
                let name = os_name.to_string_lossy().to_string();
                let has_abi = has_files_with_extension(&path.join("abi"), "idr");
                let has_ffi = has_files_with_extension(&path.join("ffi"), "zig");
                let has_adapter = has_files_with_extension(&path.join("adapter"), "v");
                entries.push((name, has_abi, has_ffi, has_adapter));
            }
        }
        entries.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(entries)
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Check if a directory (recursively) contains files with the given extension.
fn has_files_with_extension(dir: &Path, ext: &str) -> bool {
    if !dir.exists() {
        return false;
    }
    walk_dir_for_extension(dir, ext)
}

fn walk_dir_for_extension(dir: &Path, ext: &str) -> bool {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                if let Some(file_ext) = path.extension() {
                    if file_ext == ext {
                        return true;
                    }
                }
            } else if path.is_dir() {
                if walk_dir_for_extension(&path, ext) {
                    return true;
                }
            }
        }
    }
    false
}

/// Check that all .idr files contain %default total.
fn check_idris_totality(abi_dir: &Path) -> bool {
    if !abi_dir.exists() {
        return false;
    }
    let mut found_any = false;
    check_idr_files_total(abi_dir, &mut found_any, &mut true)
}

fn check_idr_files_total(dir: &Path, found_any: &mut bool, all_total: &mut bool) -> bool {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().is_some_and(|e| e == "idr") {
                *found_any = true;
                if let Ok(content) = fs::read_to_string(&path) {
                    if !content.contains("%default total") {
                        *all_total = false;
                        return false;
                    }
                }
            } else if path.is_dir() {
                check_idr_files_total(&path, found_any, all_total);
                if !*all_total {
                    return false;
                }
            }
        }
    }
    *found_any && *all_total
}

/// Check if any .idr file contains an unsafe pattern (believe_me, assert_total, etc.).
fn check_for_unsafe_pattern(abi_dir: &Path, pattern: &str) -> bool {
    if !abi_dir.exists() {
        return false;
    }
    scan_for_pattern(abi_dir, pattern)
}

fn scan_for_pattern(dir: &Path, pattern: &str) -> bool {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().is_some_and(|e| e == "idr") {
                if let Ok(content) = fs::read_to_string(&path) {
                    if content.contains(pattern) {
                        return true;
                    }
                }
            } else if path.is_dir() {
                if scan_for_pattern(&path, pattern) {
                    return true;
                }
            }
        }
    }
    false
}

/// Check that key files have SPDX headers.
fn check_spdx_headers(cart_dir: &Path) -> bool {
    let extensions = ["idr", "zig", "v"];
    let mut found_any = false;
    for ext in &extensions {
        if check_spdx_in_dir(cart_dir, ext, &mut found_any) == false {
            return false;
        }
    }
    found_any
}

fn check_spdx_in_dir(dir: &Path, ext: &str, found_any: &mut bool) -> bool {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().is_some_and(|e| e == ext) {
                *found_any = true;
                if let Ok(content) = fs::read_to_string(&path) {
                    if !content.contains("SPDX-License-Identifier") {
                        return false;
                    }
                }
            } else if path.is_dir() {
                if !check_spdx_in_dir(&path, ext, found_any) {
                    return false;
                }
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup_fake_boj() -> (TempDir, PathBuf) {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path().to_path_buf();

        // Create minimal boj-server structure
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
    fn test_mint_creates_structure() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());

        let result = scaffolder.mint(&cfg);
        assert!(result.is_ok());

        let cart_dir = root.join("cartridges/test-mcp");
        assert!(cart_dir.join("abi").is_dir());
        assert!(cart_dir.join("ffi").is_dir());
        assert!(cart_dir.join("adapter").is_dir());
        assert!(cart_dir.join("abi/TestMcp/SafeCloud.idr").is_file());
        assert!(cart_dir.join("ffi/test_mcp_ffi.zig").is_file());
        assert!(cart_dir.join("ffi/build.zig").is_file());
        assert!(cart_dir.join("adapter/test_mcp_adapter.v").is_file());
        assert!(cart_dir.join("minter.toml").is_file());
        assert!(cart_dir.join("README.adoc").is_file());
    }

    #[test]
    fn test_mint_rejects_duplicate() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());

        scaffolder.mint(&cfg).unwrap();
        let result = scaffolder.mint(&cfg);
        assert!(result.is_err());
    }

    #[test]
    fn test_provision_updates_menu() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());

        scaffolder.mint(&cfg).unwrap();
        let result = scaffolder.provision(&cfg);
        assert!(result.is_ok());

        let menu = fs::read_to_string(root.join(".machine_readable/servers/menu.a2ml")).unwrap();
        assert!(menu.contains("@cartridge(id=\"test-mcp\")"));
    }

    #[test]
    fn test_configure_creates_tests() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());

        scaffolder.mint(&cfg).unwrap();
        let result = scaffolder.configure(&cfg);
        assert!(result.is_ok());

        let cart_dir = root.join("cartridges/test-mcp");
        assert!(cart_dir.join("tests/integration_test.sh").is_file());
        assert!(cart_dir.join("benchmarks/quick-bench.sh").is_file());
    }

    #[test]
    fn test_harness_creates_panel() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());

        scaffolder.mint(&cfg).unwrap();
        let result = scaffolder.harness(&cfg);
        assert!(result.is_ok());

        let cart_dir = root.join("cartridges/test-mcp");
        assert!(cart_dir.join("panels/manifest.json").is_file());
        assert!(cart_dir.join("panels/test_mcp/panel.json").is_file());

        // Verify manifest is valid JSON
        let manifest = fs::read_to_string(cart_dir.join("panels/manifest.json")).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&manifest).unwrap();
        assert_eq!(parsed["$schema"], "panll-harness/v1");
        assert_eq!(parsed["service_id"], "test-mcp");
    }

    #[test]
    fn test_validate_passes_for_good_cartridge() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());

        scaffolder.mint(&cfg).unwrap();
        let report = scaffolder.validate("test-mcp").unwrap();

        // All structural checks should pass
        for (check, ok) in &report {
            if !ok {
                panic!("Check failed: {check}");
            }
        }
    }

    #[test]
    fn test_status_lists_cartridges() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());

        let cfg1 = CartridgeConfig::with_defaults("alpha-mcp".to_string());
        let cfg2 = CartridgeConfig::with_defaults("beta-mcp".to_string());
        scaffolder.mint(&cfg1).unwrap();
        scaffolder.mint(&cfg2).unwrap();

        let entries = scaffolder.status().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].0, "alpha-mcp");
        assert_eq!(entries[1].0, "beta-mcp");
    }

    #[test]
    fn test_generated_idris_has_total() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());
        scaffolder.mint(&cfg).unwrap();

        let idr = fs::read_to_string(root.join("cartridges/test-mcp/abi/TestMcp/SafeCloud.idr"))
            .unwrap();
        assert!(idr.contains("%default total"));
        assert!(!idr.contains("believe_me"));
        assert!(!idr.contains("assert_total"));
        assert!(!idr.contains("sorry"));
    }

    #[test]
    fn test_generated_zig_has_tests() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());
        scaffolder.mint(&cfg).unwrap();

        let zig = fs::read_to_string(root.join("cartridges/test-mcp/ffi/test_mcp_ffi.zig"))
            .unwrap();
        assert!(zig.contains("test \"session lifecycle\""));
        assert!(zig.contains("test \"invalid transitions rejected\""));
        assert!(zig.contains("test \"transition validator\""));
        assert!(zig.contains("test \"slot exhaustion\""));
    }

    #[test]
    fn test_full_wizard_pipeline() {
        let (_tmp, root) = setup_fake_boj();
        let scaffolder = Scaffolder::new(root.clone());
        let cfg = CartridgeConfig::with_defaults("full-mcp".to_string());

        // Run all four phases
        scaffolder.mint(&cfg).unwrap();
        scaffolder.provision(&cfg).unwrap();
        scaffolder.configure(&cfg).unwrap();
        scaffolder.harness(&cfg).unwrap();

        // Everything should validate
        let report = scaffolder.validate("full-mcp").unwrap();
        assert!(report.iter().all(|(_, ok)| *ok));
    }
}
