// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Legacy Adapter Deprecation System
//
// Tracks deprecated adapters, provides migration guidance, and enforces
// sunset dates. Integrated with Unified API to warn users about legacy
// system usage and guide them toward modern alternatives.

module deprecation

import json
import time

// Deprecation status levels
pub enum DeprecationStatus {
    active
    deprecated
    sunset
    archived
}

// Migration guide reference
pub struct MigrationGuide {
    url          string
    title        string
    description  string
}

// Alternative recommendation
pub struct Alternative {
    adapter_id   string
    name         string
    description  string
    mcp_cartridge bool  // Whether it's a modern MCP cartridge
}

// Deprecated adapter metadata
pub struct DeprecatedAdapter {
    id               string
    name             string
    status           DeprecationStatus
    deprecated_since string  // ISO date
    sunset_date      string  // ISO date (when support ends)
    reason           string  // Why it's deprecated
    migration_guides array<MigrationGuide>
    alternatives     array<Alternative>
    warning_message  string
}

// Current deprecation registry
pub mut deprecated_registry map[string]DeprecatedAdapter

// Initialize the deprecation registry with known legacy adapters
pub fn init_deprecation_registry() {
    deprecated_registry = {
        'wordpress': DeprecatedAdapter{
            id: 'wordpress'
            name: 'WordPress Legacy Adapter'
            status: .deprecated
            deprecated_since: '2026-04-01'
            sunset_date: '2028-12-31'
            reason: 'WordPress PHP-based CMS encourages outdated practices. Modern static site generators provide better security and performance.'
            migration_guides: [
                MigrationGuide{
                    url: 'https://panll.dev/migrate/wordpress-to-ssg'
                    title: 'Migrating from WordPress to Static Site Generation'
                    description: 'Step-by-step guide to move from WordPress to modern SSG solutions'
                }
            ]
            alternatives: [
                Alternative{
                    adapter_id: 'ssg-mcp'
                    name: 'Static Site Generator'
                    description: 'Modern SSG with Markdown content, Git-based workflow, and better security'
                    mcp_cartridge: true
                }
            ]
            warning_message: 'WARNING: WordPress adapter is deprecated and will be removed on 2028-12-31. Please migrate to static site generation for better security and performance.'
        }
        'hol': DeprecatedAdapter{
            id: 'hol'
            name: 'HOL Legacy Adapter'
            status: .deprecated
            deprecated_since: '2026-04-01'
            sunset_date: '2029-12-31'
            reason: 'HOL system uses legacy ML implementation. Modern theorem provers like Lean and Coq provide better tooling and community support.'
            migration_guides: [
                MigrationGuide{
                    url: 'https://panll.dev/migrate/hol-to-lean'
                    title: 'Migrating from HOL to Lean Theorem Prover'
                    description: 'Guide for academic researchers moving to modern theorem proving'
                }
            ]
            alternatives: [
                Alternative{
                    adapter_id: 'proof-mcp'
                    name: 'Proof Cartridge'
                    description: 'Modern proof system with Lean/Coq/Isabelle support'
                    mcp_cartridge: true
                }
            ]
            warning_message: 'WARNING: HOL adapter is deprecated (sunset: 2029-12-31). Consider migrating to Lean or Coq for ongoing support and better tooling.'
        }
        'julia': DeprecatedAdapter{
            id: 'julia'
            name: 'Julia Legacy Adapter'
            status: .deprecated
            deprecated_since: '2026-04-01'
            sunset_date: '2028-12-31'
            reason: 'While Julia is excellent for scientific computing, Python has broader ecosystem support and better integration with modern data science tools.'
            migration_guides: [
                MigrationGuide{
                    url: 'https://panll.dev/migrate/julia-to-python'
                    title: 'Migrating Julia Code to Python'
                    description: 'Tools and techniques for moving scientific computing workloads to Python'
                }
            ]
            alternatives: [
                Alternative{
                    adapter_id: 'python-mcp'
                    name: 'Python Data Science'
                    description: 'Modern Python data science stack with Pandas, NumPy, SciPy'
                    mcp_cartridge: true
                }
            ]
            warning_message: 'WARNING: Julia adapter deprecated (sunset: 2028-12-31). Python ecosystem provides broader tooling and better long-term support.'
        }
        'pandoc': DeprecatedAdapter{
            id: 'pandoc'
            name: 'Pandoc Legacy Adapter'
            status: .active  // Not deprecated yet - still useful
            deprecated_since: ''
            sunset_date: ''
            reason: ''
            migration_guides: []
            alternatives: []
            warning_message: ''
        }
    }
}

// Check if an adapter is deprecated
pub fn is_deprecated(adapter_id string) bool {
    return deprecated_registry.has(adapter_id) && 
           deprecated_registry[adapter_id].status != .active
}

// Get deprecation warning for an adapter
pub fn get_deprecation_warning(adapter_id string) ?string {
    if deprecated_registry.has(adapter_id) {
        dep := deprecated_registry[adapter_id]
        if dep.status != .active {
            return dep.warning_message
        }
    }
    return error('Adapter not deprecated')
}

// Get full deprecation info
pub fn get_deprecation_info(adapter_id string) ?DeprecatedAdapter {
    if deprecated_registry.has(adapter_id) {
        return deprecated_registry[adapter_id]
    }
    return error('Adapter not found in registry')
}

// Check if adapter has reached sunset date
pub fn is_sunset(adapter_id string) bool {
    if deprecated_registry.has(adapter_id) {
        dep := deprecated_registry[adapter_id]
        if dep.sunset_date != '' && dep.status == .sunset {
            // Parse and compare dates
            sunset := time.parse(dep.sunset_date, time.iso8601) or { time.Time{} }
            return time.now() >= sunset
        }
    }
    return false
}

// Get migration alternatives
pub fn get_alternatives(adapter_id string) []Alternative {
    mut alternatives := []Alternative{}
    if deprecated_registry.has(adapter_id) {
        dep := deprecated_registry[adapter_id]
        for alt in dep.alternatives {
            alternatives << alt
        }
    }
    return alternatives
}

// Add deprecation warning to API response
pub fn add_deprecation_warning(response mut map[string]json.Value, adapter_id string) {
    if is_deprecated(adapter_id) {
        warning := get_deprecation_warning(adapter_id) or { '' }
        if warning != '' {
            response['deprecation_warning'] = json.value(warning)
            response['deprecation_info'] = json.value(get_deprecation_info(adapter_id) or { DeprecatedAdapter{} })
        }
    }
}

// Initialize the system
init {
    init_deprecation_registry()
}