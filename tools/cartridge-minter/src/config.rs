// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Configuration types for the cartridge minter.
// These mirror the Idris2 ABI definitions in src/abi/Boj/ exactly.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::path::Path;

/// Capability domains — matches Boj.Domain.idr.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CapabilityDomain {
    Cloud,
    Container,
    Database,
    K8s,
    Git,
    Secrets,
    Queues,
    IaC,
    Observe,
    SSG,
    Proof,
    FleetDom,
    NeSyDom,
    Feedback,
    Browser,
    Comms,
    ML,
    Research,
    Lang,
}

impl CapabilityDomain {
    /// All known domains in canonical order.
    pub fn all() -> Vec<CapabilityDomain> {
        vec![
            Self::Cloud,
            Self::Container,
            Self::Database,
            Self::K8s,
            Self::Git,
            Self::Secrets,
            Self::Queues,
            Self::IaC,
            Self::Observe,
            Self::SSG,
            Self::Proof,
            Self::FleetDom,
            Self::NeSyDom,
            Self::Feedback,
            Self::Browser,
            Self::Comms,
            Self::ML,
            Self::Research,
            Self::Lang,
        ]
    }

    /// Integer encoding for C-ABI boundary (matches Idris2 domainToInt).
    pub fn to_int(self) -> i32 {
        match self {
            Self::Cloud => 0,
            Self::Container => 1,
            Self::Database => 2,
            Self::K8s => 3,
            Self::Git => 4,
            Self::Secrets => 5,
            Self::Queues => 6,
            Self::IaC => 7,
            Self::Observe => 8,
            Self::SSG => 9,
            Self::Proof => 10,
            Self::FleetDom => 11,
            Self::NeSyDom => 12,
            Self::Feedback => 13,
            Self::Browser => 14,
            Self::Comms => 15,
            Self::ML => 16,
            Self::Research => 17,
            Self::Lang => 18,
        }
    }

    /// Convert the domain name to a PascalCase module prefix for Idris2.
    pub fn idris_module_name(self) -> &'static str {
        match self {
            Self::Cloud => "Cloud",
            Self::Container => "Container",
            Self::Database => "Database",
            Self::K8s => "Kubernetes",
            Self::Git => "Git",
            Self::Secrets => "Secrets",
            Self::Queues => "Queues",
            Self::IaC => "IaC",
            Self::Observe => "Observe",
            Self::SSG => "SSG",
            Self::Proof => "Proof",
            Self::FleetDom => "Fleet",
            Self::NeSyDom => "NeSy",
            Self::Feedback => "Feedback",
            Self::Browser => "Browser",
            Self::Comms => "Comms",
            Self::ML => "ML",
            Self::Research => "Research",
            Self::Lang => "Lang",
        }
    }
}

impl fmt::Display for CapabilityDomain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}", self)
    }
}

/// Protocol types — matches Boj.Protocol.idr.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProtocolType {
    MCP,
    LSP,
    DAP,
    BSP,
    NeSy,
    Agentic,
    Fleet,
    GRPC,
    REST,
}

impl ProtocolType {
    /// All known protocols in canonical order.
    pub fn all() -> Vec<ProtocolType> {
        vec![
            Self::MCP,
            Self::LSP,
            Self::DAP,
            Self::BSP,
            Self::NeSy,
            Self::Agentic,
            Self::Fleet,
            Self::GRPC,
            Self::REST,
        ]
    }

    /// Integer encoding for C-ABI boundary (matches Idris2 protocolToInt).
    pub fn to_int(self) -> i32 {
        match self {
            Self::MCP => 0,
            Self::LSP => 1,
            Self::DAP => 2,
            Self::BSP => 3,
            Self::NeSy => 4,
            Self::Agentic => 5,
            Self::Fleet => 6,
            Self::GRPC => 7,
            Self::REST => 8,
        }
    }

    /// A2ML-compatible label for menu entries.
    pub fn a2ml_label(self) -> &'static str {
        match self {
            Self::MCP => "MCP",
            Self::LSP => "LSP",
            Self::DAP => "DAP",
            Self::BSP => "BSP",
            Self::NeSy => "NeSy",
            Self::Agentic => "Agentic",
            Self::Fleet => "Fleet",
            Self::GRPC => "gRPC",
            Self::REST => "REST",
        }
    }
}

impl fmt::Display for ProtocolType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.a2ml_label())
    }
}

/// Menu tier — matches Boj.Catalogue.idr MenuTier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MenuTier {
    Teranga,
    Shield,
    Ayo,
}

impl MenuTier {
    /// All tiers.
    pub fn all() -> Vec<MenuTier> {
        vec![Self::Teranga, Self::Shield, Self::Ayo]
    }

    /// Human-readable description of the tier.
    pub fn description(self) -> &'static str {
        match self {
            Self::Teranga => "Core cartridges maintained by hyperpolymath",
            Self::Shield => "Privacy & security cartridges",
            Self::Ayo => "Community-contributed cartridges",
        }
    }
}

impl fmt::Display for MenuTier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}", self)
    }
}

/// Full configuration for a cartridge.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CartridgeConfig {
    pub name: String,
    pub description: String,
    pub version: String,
    pub domain: CapabilityDomain,
    pub protocols: Vec<ProtocolType>,
    pub tier: MenuTier,
    pub backend: String,
    pub generate_panel: bool,
}

impl CartridgeConfig {
    /// Create a config with sensible defaults (for non-interactive mode).
    pub fn with_defaults(name: String) -> Self {
        Self {
            description: format!("{name} cartridge"),
            version: "0.1.0".to_string(),
            domain: CapabilityDomain::Cloud,
            protocols: vec![ProtocolType::MCP, ProtocolType::REST],
            tier: MenuTier::Ayo,
            backend: "universal".to_string(),
            generate_panel: true,
            name,
        }
    }

    /// Load config from an existing cartridge's minter.toml, or fall back to defaults.
    pub fn load_or_default(boj_root: &Path, name: &str) -> Self {
        let config_path = boj_root
            .join("cartridges")
            .join(name)
            .join("minter.toml");
        if config_path.exists() {
            if let Ok(content) = std::fs::read_to_string(&config_path) {
                if let Ok(cfg) = toml::from_str::<CartridgeConfig>(&content) {
                    return cfg;
                }
            }
        }
        Self::with_defaults(name.to_string())
    }

    /// The PascalCase module name for Idris2 (e.g., "browser-mcp" → "BrowserMcp").
    pub fn idris_package_name(&self) -> String {
        self.name
            .split('-')
            .map(|part| {
                let mut chars = part.chars();
                match chars.next() {
                    None => String::new(),
                    Some(c) => c.to_uppercase().to_string() + chars.as_str(),
                }
            })
            .collect()
    }

    /// The snake_case FFI name (e.g., "browser-mcp" → "browser_mcp").
    pub fn ffi_name(&self) -> String {
        self.name.replace('-', "_")
    }

    /// Save config as minter.toml inside the cartridge directory.
    pub fn save(&self, cartridge_dir: &Path) -> std::io::Result<()> {
        let content =
            toml::to_string_pretty(self).map_err(|e| std::io::Error::other(e.to_string()))?;
        std::fs::write(cartridge_dir.join("minter.toml"), content)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_domain_round_trip() {
        for d in CapabilityDomain::all() {
            let i = d.to_int();
            assert!(i >= 0);
            let s = d.to_string();
            assert!(!s.is_empty());
        }
    }

    #[test]
    fn test_protocol_round_trip() {
        for p in ProtocolType::all() {
            let i = p.to_int();
            assert!(i >= 0);
            let s = p.a2ml_label();
            assert!(!s.is_empty());
        }
    }

    #[test]
    fn test_idris_package_name() {
        let cfg = CartridgeConfig::with_defaults("browser-mcp".to_string());
        assert_eq!(cfg.idris_package_name(), "BrowserMcp");

        let cfg2 = CartridgeConfig::with_defaults("database-mcp".to_string());
        assert_eq!(cfg2.idris_package_name(), "DatabaseMcp");
    }

    #[test]
    fn test_ffi_name() {
        let cfg = CartridgeConfig::with_defaults("browser-mcp".to_string());
        assert_eq!(cfg.ffi_name(), "browser_mcp");
    }

    #[test]
    fn test_config_serialisation() {
        let cfg = CartridgeConfig::with_defaults("test-mcp".to_string());
        let toml_str = toml::to_string_pretty(&cfg).unwrap();
        let roundtrip: CartridgeConfig = toml::from_str(&toml_str).unwrap();
        assert_eq!(roundtrip.name, cfg.name);
        assert_eq!(roundtrip.domain, cfg.domain);
    }
}
