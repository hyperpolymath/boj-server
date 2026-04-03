// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// cartridge-minter — Wizard-driven cartridge scaffolder for BoJ Server.
//
// Four modes of operation:
//   mint        — Scaffold a new cartridge (Idris2 ABI + Zig FFI + V adapter)
//   provision   — Wire a cartridge into BoJ menu, matrix, and MCP bridge
//   configure   — Set domain, protocols, tier, generate test stubs
//   harness     — Generate PanLL panel manifest for cartridge management UI
//
// Designed to be as easy as a child finds fishfingers to eat.

mod config;
mod scaffold;
mod templates;

use clap::{Parser, Subcommand};
use console::style;
use dialoguer::{Confirm, Input, MultiSelect, Select};
use std::io;
use std::path::PathBuf;

use config::{CapabilityDomain, CartridgeConfig, MenuTier, ProtocolType};
use scaffold::Scaffolder;

/// BoJ Cartridge Minter — scaffold, provision, configure, and harness cartridges.
#[derive(Parser)]
#[command(name = "cartridge-minter", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Path to boj-server root (auto-detected from CWD if omitted)
    #[arg(long, global = true)]
    boj_root: Option<PathBuf>,
}

#[derive(Subcommand)]
enum Commands {
    /// Scaffold a new cartridge with full 3-layer stack
    Mint {
        /// Cartridge name (e.g., "browser-mcp")
        #[arg(short, long)]
        name: Option<String>,

        /// Skip interactive wizard, use defaults
        #[arg(long)]
        non_interactive: bool,
    },

    /// Wire an existing cartridge into BoJ menu + MCP bridge
    Provision {
        /// Cartridge name to provision
        name: String,
    },

    /// Configure cartridge settings (domain, protocols, tier)
    Configure {
        /// Cartridge name to configure
        name: String,
    },

    /// Generate PanLL panel harness for cartridge management
    Harness {
        /// Cartridge name (or "all" for every cartridge)
        name: String,
    },

    /// Run full wizard: mint → provision → configure → harness
    Wizard,

    /// List all known domains and protocols
    ListOptions,

    /// Validate an existing cartridge structure
    Validate {
        /// Cartridge name to validate
        name: String,
    },

    /// Show cartridge status summary
    Status,
}

fn main() {
    let cli = Cli::parse();
    let boj_root = resolve_boj_root(cli.boj_root);

    match cli.command {
        Some(Commands::Mint {
            name,
            non_interactive,
        }) => {
            cmd_mint(&boj_root, name, non_interactive);
        }
        Some(Commands::Provision { name }) => {
            cmd_provision(&boj_root, &name);
        }
        Some(Commands::Configure { name }) => {
            cmd_configure(&boj_root, &name);
        }
        Some(Commands::Harness { name }) => {
            cmd_harness(&boj_root, &name);
        }
        Some(Commands::Wizard) | None => {
            cmd_wizard(&boj_root);
        }
        Some(Commands::ListOptions) => {
            cmd_list_options();
        }
        Some(Commands::Validate { name }) => {
            cmd_validate(&boj_root, &name);
        }
        Some(Commands::Status) => {
            cmd_status(&boj_root);
        }
    }
}

// ---------------------------------------------------------------------------
// Command implementations
// ---------------------------------------------------------------------------

/// Full wizard: ask everything interactively, then mint + provision + configure + harness.
fn cmd_wizard(boj_root: &PathBuf) {
    println!(
        "{}",
        style("╔══════════════════════════════════════════╗").cyan()
    );
    println!(
        "{}",
        style("║   BoJ Cartridge Minter — Full Wizard    ║").cyan()
    );
    println!(
        "{}",
        style("╚══════════════════════════════════════════╝").cyan()
    );
    println!();

    let cfg = wizard_gather_config().unwrap_or_else(|e| {
        eprintln!("{} Terminal error: {e}", style("✗").red());
        std::process::exit(1);
    });
    let scaffolder = Scaffolder::new(boj_root.clone());

    // Phase 1: Mint
    println!(
        "\n{} Minting cartridge '{}'...",
        style("[1/4]").bold(),
        cfg.name
    );
    match scaffolder.mint(&cfg) {
        Ok(path) => println!("  {} Created {}", style("✓").green(), path.display()),
        Err(e) => {
            eprintln!("  {} Mint failed: {e}", style("✗").red());
            std::process::exit(1);
        }
    }

    // Phase 2: Provision
    println!(
        "\n{} Provisioning into BoJ menu + MCP bridge...",
        style("[2/4]").bold()
    );
    match scaffolder.provision(&cfg) {
        Ok(files) => {
            for f in &files {
                println!("  {} Updated {}", style("✓").green(), f);
            }
        }
        Err(e) => eprintln!("  {} Provision warning: {e}", style("⚠").yellow()),
    }

    // Phase 3: Configure
    println!(
        "\n{} Generating test stubs + benchmarks...",
        style("[3/4]").bold()
    );
    match scaffolder.configure(&cfg) {
        Ok(files) => {
            for f in &files {
                println!("  {} Created {}", style("✓").green(), f);
            }
        }
        Err(e) => eprintln!("  {} Configure warning: {e}", style("⚠").yellow()),
    }

    // Phase 4: Harness
    println!(
        "\n{} Creating PanLL panel harness...",
        style("[4/4]").bold()
    );
    match scaffolder.harness(&cfg) {
        Ok(path) => println!("  {} Created {}", style("✓").green(), path),
        Err(e) => eprintln!("  {} Harness warning: {e}", style("⚠").yellow()),
    }

    println!(
        "\n{}",
        style("═══════════════════════════════════════════").green()
    );
    println!(
        "{} Cartridge '{}' is ready!",
        style("Done!").green().bold(),
        cfg.name
    );
    println!();
    println!("Next steps:");
    println!("  1. Edit the Idris2 ABI:  cartridges/{}/abi/", cfg.name);
    println!("  2. Implement Zig FFI:    cartridges/{}/ffi/", cfg.name);
    println!("  3. Wire V-lang adapter:  cartridges/{}/adapter/", cfg.name);
    println!("  4. Run tests:            just test-cartridge {}", cfg.name);
    println!("  5. Build:                just build-cartridge {}", cfg.name);
}

/// Mint a cartridge (interactive or with flags).
fn cmd_mint(boj_root: &PathBuf, name: Option<String>, non_interactive: bool) {
    let cfg = if non_interactive {
        let name = name.expect("--name required in non-interactive mode");
        CartridgeConfig::with_defaults(name)
    } else {
        wizard_gather_config().unwrap_or_else(|e| {
            eprintln!("{} Terminal error: {e}", style("✗").red());
            std::process::exit(1);
        })
    };

    let scaffolder = Scaffolder::new(boj_root.clone());
    match scaffolder.mint(&cfg) {
        Ok(path) => println!("{} Minted: {}", style("✓").green(), path.display()),
        Err(e) => {
            eprintln!("{} {e}", style("✗").red());
            std::process::exit(1);
        }
    }
}

/// Provision a cartridge into BoJ infrastructure.
fn cmd_provision(boj_root: &PathBuf, name: &str) {
    let cfg = CartridgeConfig::load_or_default(boj_root, name);
    let scaffolder = Scaffolder::new(boj_root.clone());
    match scaffolder.provision(&cfg) {
        Ok(files) => {
            for f in &files {
                println!("{} {f}", style("✓").green());
            }
        }
        Err(e) => {
            eprintln!("{} {e}", style("✗").red());
            std::process::exit(1);
        }
    }
}

/// Configure a cartridge's settings.
fn cmd_configure(boj_root: &PathBuf, name: &str) {
    let cfg = CartridgeConfig::load_or_default(boj_root, name);
    let scaffolder = Scaffolder::new(boj_root.clone());
    match scaffolder.configure(&cfg) {
        Ok(files) => {
            for f in &files {
                println!("{} {f}", style("✓").green());
            }
        }
        Err(e) => {
            eprintln!("{} {e}", style("✗").red());
            std::process::exit(1);
        }
    }
}

/// Generate PanLL panel harness.
fn cmd_harness(boj_root: &PathBuf, name: &str) {
    let scaffolder = Scaffolder::new(boj_root.clone());
    if name == "all" {
        match scaffolder.harness_all() {
            Ok(count) => println!(
                "{} Generated harnesses for {count} cartridges",
                style("✓").green()
            ),
            Err(e) => {
                eprintln!("{} {e}", style("✗").red());
                std::process::exit(1);
            }
        }
    } else {
        let cfg = CartridgeConfig::load_or_default(boj_root, name);
        match scaffolder.harness(&cfg) {
            Ok(path) => println!("{} {path}", style("✓").green()),
            Err(e) => {
                eprintln!("{} {e}", style("✗").red());
                std::process::exit(1);
            }
        }
    }
}

/// List all known domains, protocols, and tiers.
fn cmd_list_options() {
    println!("{}", style("Capability Domains:").bold());
    for d in CapabilityDomain::all() {
        println!("  - {d}");
    }
    println!("\n{}", style("Protocols:").bold());
    for p in ProtocolType::all() {
        println!("  - {p}");
    }
    println!("\n{}", style("Tiers:").bold());
    for t in MenuTier::all() {
        println!("  - {t}");
    }
}

/// Validate a cartridge's structure.
fn cmd_validate(boj_root: &PathBuf, name: &str) {
    let scaffolder = Scaffolder::new(boj_root.clone());
    match scaffolder.validate(name) {
        Ok(report) => {
            println!("{}", style(format!("Validation: {name}")).bold());
            for (check, ok) in &report {
                let icon = if *ok {
                    style("✓").green()
                } else {
                    style("✗").red()
                };
                println!("  {icon} {check}");
            }
            let pass = report.iter().all(|(_, ok)| *ok);
            if pass {
                println!("\n{}", style("All checks passed!").green().bold());
            } else {
                println!("\n{}", style("Some checks failed.").red().bold());
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("{} {e}", style("✗").red());
            std::process::exit(1);
        }
    }
}

/// Show status of all cartridges.
fn cmd_status(boj_root: &PathBuf) {
    let scaffolder = Scaffolder::new(boj_root.clone());
    match scaffolder.status() {
        Ok(entries) => {
            println!("{}", style("BoJ Cartridge Status").bold());
            println!("{:-<60}", "");
            for (name, has_abi, has_ffi, has_adapter) in &entries {
                let abi = if *has_abi {
                    style("ABI").green()
                } else {
                    style("ABI").red()
                };
                let ffi = if *has_ffi {
                    style("FFI").green()
                } else {
                    style("FFI").red()
                };
                let adp = if *has_adapter {
                    style("ADT").green()
                } else {
                    style("ADT").red()
                };
                println!("  {name:<24} {abi}  {ffi}  {adp}");
            }
        }
        Err(e) => {
            eprintln!("{} {e}", style("✗").red());
            std::process::exit(1);
        }
    }
}

// ---------------------------------------------------------------------------
// Interactive wizard helpers
// ---------------------------------------------------------------------------

/// Gather all configuration from the user interactively.
fn wizard_gather_config() -> io::Result<CartridgeConfig> {
    let name: String = Input::new()
        .with_prompt("Cartridge name (e.g., browser-mcp)")
        .validate_with(|input: &String| -> Result<(), &str> {
            if input.is_empty() {
                return Err("Name cannot be empty");
            }
            if !input.ends_with("-mcp") {
                return Err("Cartridge names must end with '-mcp'");
            }
            if !input
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-')
            {
                return Err("Name must be alphanumeric with hyphens only");
            }
            Ok(())
        })
        .interact_text()?;

    let description: String = Input::new()
        .with_prompt("Short description")
        .interact_text()?;

    let domains = CapabilityDomain::all();
    let domain_labels: Vec<String> = domains.iter().map(|d| d.to_string()).collect();
    let domain_idx = Select::new()
        .with_prompt("Capability domain")
        .items(&domain_labels)
        .default(0)
        .interact()?;

    let protocols = ProtocolType::all();
    let proto_labels: Vec<String> = protocols.iter().map(|p| p.to_string()).collect();
    let proto_indices = MultiSelect::new()
        .with_prompt("Supported protocols (space to select, enter to confirm)")
        .items(&proto_labels)
        .defaults(&[true, false, false, false, false, false, false, false, true])
        .interact()?;
    let selected_protocols: Vec<ProtocolType> =
        proto_indices.into_iter().map(|i| protocols[i]).collect();

    let tiers = MenuTier::all();
    let tier_labels: Vec<String> = tiers
        .iter()
        .map(|t| format!("{t} — {}", t.description()))
        .collect();
    let tier_idx = Select::new()
        .with_prompt("Tier")
        .items(&tier_labels)
        .default(2) // Ayo by default (community)
        .interact()?;

    let backend: String = Input::new()
        .with_prompt("Backend identifier (e.g., 'universal', 'sqlite', 'rest-api')")
        .default("universal".to_string())
        .interact_text()?;

    let generate_panel = Confirm::new()
        .with_prompt("Generate PanLL panel harness?")
        .default(true)
        .interact()?;

    Ok(CartridgeConfig {
        name,
        description,
        version: "0.1.0".to_string(),
        domain: domains[domain_idx],
        protocols: selected_protocols,
        tier: tiers[tier_idx],
        backend,
        generate_panel,
    })
}

// ---------------------------------------------------------------------------
// Resolve boj-server root
// ---------------------------------------------------------------------------

fn resolve_boj_root(explicit: Option<PathBuf>) -> PathBuf {
    if let Some(root) = explicit {
        return root;
    }

    // Walk up from CWD looking for 0-AI-MANIFEST.a2ml (BoJ signature)
    let mut dir = std::env::current_dir().unwrap_or_default();
    for _ in 0..10 {
        if dir.join("0-AI-MANIFEST.a2ml").exists() && dir.join("cartridges").exists() {
            return dir;
        }
        if !dir.pop() {
            break;
        }
    }

    // Fallback: check BOJ_SERVER_DIR env var, then current directory
    if let Ok(dir) = std::env::var("BOJ_SERVER_DIR") {
        let p = PathBuf::from(&dir);
        if p.join("Justfile").exists() || p.join("Cargo.toml").exists() {
            return p;
        }
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    if cwd.join("Justfile").exists() || cwd.join("Cargo.toml").exists() {
        return cwd;
    }

    eprintln!("Could not locate boj-server root. Use --boj-root to specify.");
    std::process::exit(1);
}
