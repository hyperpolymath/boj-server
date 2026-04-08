// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Legacy Adapter Framework
//
// Framework for creating isolated adapters for legacy systems.
// Each legacy adapter implements the LegacyAdapter interface and
// handles protocol conversion between MCP and the legacy system.

module legacy

import deprecation
import json
import net.http

// Legacy adapter interface
pub interface LegacyAdapter {
    id() string
    name() string
    is_deprecated() bool
    handle_request(req MCPRequest) MCPResponse
    health_check() HealthStatus
    capabilities() []Capability
}

// Health status
pub enum HealthStatus {
    healthy
    degraded
    unavailable
    deprecated
}

// Capability declaration
pub struct Capability {
    id          string
    name        string
    description string
}

// MCP request/response types (simplified)
pub struct MCPRequest {
    method      string
    path        string
    headers     map[string]string
    body        json.Value
    cartridge   string
    tool        string
}

pub struct MCPResponse {
    status      int
    headers     map[string]string
    body        json.Value
    error       ?string
    deprecation ?DeprecationWarning
}

// Deprecation warning in response
pub struct DeprecationWarning {
    message string
    url      string
    sunset   string
}

// Base legacy adapter implementation
pub struct BaseLegacyAdapter {
    adapter_id string
    pub mut healthy bool
}

// WordPress legacy adapter
pub struct WordPressAdapter {
    BaseLegacyAdapter
    base_url string
}

fn (w WordPressAdapter) id() string {
    return 'wordpress'
}

fn (w WordPressAdapter) name() string {
    return 'WordPress Legacy Adapter'
}

fn (w WordPressAdapter) is_deprecated() bool {
    return deprecation.is_deprecated(w.id())
}

fn (w WordPressAdapter) handle_request(req MCPRequest) MCPResponse {
    // Check deprecation
    mut resp := MCPResponse{
        status: 200
        headers: {}
        body: json.Value{}
        error: none
        deprecation: none
    }
    
    if w.is_deprecated() {
        warning := deprecation.get_deprecation_warning(w.id())
        resp.deprecation = DeprecationWarning{
            message: warning or { '' }
            url: 'https://panll.dev/migrate/wordpress-to-ssg'
            sunset: '2028-12-31'
        }
    }
    
    // Convert MCP request to WordPress REST API call
    wp_url := w.base_url + '/wp-json/wp/v2/' + req.path
    wp_headers := {
        'Content-Type': 'application/json'
        'User-Agent': 'PanLL-BoJ/1.0'
    }
    
    // Add WordPress-specific headers
    if req.headers.has('X-WordPress-Nonce') {
        wp_headers['X-WP-Nonce'] = req.headers['X-WordPress-Nonce']
    }
    
    // Make HTTP request
    client := http.Client{}
    mut http_req := http.Request{
        method: req.method
        url: wp_url
        headers: wp_headers
        body: req.body.string()
    }
    
    http_resp := client.request(http_req) or {
        return MCPResponse{
            status: 502
            headers: {}
            body: json.Value{}
            error: 'WordPress request failed'
            deprecation: resp.deprecation
        }
    }
    
    // Convert WordPress response back to MCP
    resp.status = http_resp.status_code
    resp.headers = http_resp.headers
    resp.body = json.parse(http_resp.body) or { json.Value{} }
    
    return resp
}

fn (w WordPressAdapter) health_check() HealthStatus {
    // Simple health check - try to reach WordPress
    client := http.Client{}
    resp := client.get(w.base_url + '/wp-json/') or { return .unavailable }
    if resp.status_code == 200 {
        return .healthy
    }
    return .degraded
}

fn (w WordPressAdapter) capabilities() []Capability {
    return [
        Capability{
            id: 'posts'
            name: 'Post Management'
            description: 'Create, read, update, delete WordPress posts'
        }
        Capability{
            id: 'pages'
            name: 'Page Management'
            description: 'Create, read, update, delete WordPress pages'
        }
        Capability{
            id: 'media'
            name: 'Media Management'
            description: 'Upload and manage media files'
        }
    ]
}

// HOL legacy adapter
pub struct HolAdapter {
    BaseLegacyAdapter
    hol_path string
}

fn (h HolAdapter) id() string {
    return 'hol'
}

fn (h HolAdapter) name() string {
    return 'HOL Legacy Adapter'
}

fn (h HolAdapter) is_deprecated() bool {
    return deprecation.is_deprecated(h.id())
}

fn (h HolAdapter) handle_request(req MCPRequest) MCPResponse {
    mut resp := MCPResponse{
        status: 200
        headers: {}
        body: json.Value{}
        error: none
        deprecation: none
    }
    
    // Add deprecation warning
    if h.is_deprecated() {
        warning := deprecation.get_deprecation_warning(h.id())
        resp.deprecation = DeprecationWarning{
            message: warning or { '' }
            url: 'https://panll.dev/migrate/hol-to-lean'
            sunset: '2029-12-31'
        }
    }
    
    // HOL uses XML-RPC or custom protocol - would need specific implementation
    // This is a placeholder showing the pattern
    
    // For now, return not implemented for HOL-specific operations
    if req.cartridge == 'hol' && req.tool != 'health' {
        return MCPResponse{
            status: 501
            headers: {}
            body: json.Value{}
            error: 'HOL operation not yet implemented in adapter'
            deprecation: resp.deprecation
        }
    }
    
    return resp
}

fn (h HolAdapter) health_check() HealthStatus {
    // Check if HOL binary exists and is executable
    if os.file_exists(h.hol_path) {
        return .healthy
    }
    return .unavailable
}

fn (h HolAdapter) capabilities() []Capability {
    return [
        Capability{
            id: 'theorem_proving'
            name: 'Theorem Proving'
            description: 'HOL theorem proving operations'
        }
        Capability{
            id: 'logic_analysis'
            name: 'Logic Analysis'
            description: 'HOL logic analysis tools'
        }
    ]
}

// Julia legacy adapter
pub struct JuliaAdapter {
    BaseLegacyAdapter
    julia_path string
}

fn (j JuliaAdapter) id() string {
    return 'julia'
}

fn (j JuliaAdapter) name() string {
    return 'Julia Legacy Adapter'
}

fn (j JuliaAdapter) is_deprecated() bool {
    return deprecation.is_deprecated(j.id())
}

fn (j JuliaAdapter) handle_request(req MCPRequest) MCPResponse {
    mut resp := MCPResponse{
        status: 200
        headers: {}
        body: json.Value{}
        error: none
        deprecation: none
    }
    
    // Add deprecation warning
    if j.is_deprecated() {
        warning := deprecation.get_deprecation_warning(j.id())
        resp.deprecation = DeprecationWarning{
            message: warning or { '' }
            url: 'https://panll.dev/migrate/julia-to-python'
            sunset: '2028-12-31'
        }
    }
    
    // Julia adapter would execute Julia code
    // This is a placeholder showing the pattern
    
    if req.cartridge == 'julia' && req.tool == 'execute' {
        // Would execute Julia code here
        return MCPResponse{
            status: 501
            headers: {}
            body: json.Value{}
            error: 'Julia execution not yet implemented'
            deprecation: resp.deprecation
        }
    }
    
    return resp
}

fn (j JuliaAdapter) health_check() HealthStatus {
    if os.file_exists(j.julia_path) {
        return .healthy
    }
    return .unavailable
}

fn (j JuliaAdapter) capabilities() []Capability {
    return [
        Capability{
            id: 'data_science'
            name: 'Data Science'
            description: 'Julia data science operations'
        }
        Capability{
            id: 'scientific_computing'
            name: 'Scientific Computing'
            description: 'Julia scientific computing tools'
        }
    ]
}

// Pandoc legacy adapter
pub struct PandocAdapter {
    BaseLegacyAdapter
    pandoc_path string
}

fn (p PandocAdapter) id() string {
    return 'pandoc'
}

fn (p PandocAdapter) name() string {
    return 'Pandoc Legacy Adapter'
}

fn (p PandocAdapter) is_deprecated() bool {
    return deprecation.is_deprecated(p.id())
}

fn (p PandocAdapter) handle_request(req MCPRequest) MCPResponse {
    mut resp := MCPResponse{
        status: 200
        headers: {}
        body: json.Value{}
        error: none
        deprecation: none
    }
    
    // Pandoc is not deprecated yet
    if p.is_deprecated() {
        warning := deprecation.get_deprecation_warning(p.id())
        resp.deprecation = DeprecationWarning{
            message: warning or { '' }
            url: ''
            sunset: ''
        }
    }
    
    // Pandoc adapter would handle document conversion
    if req.cartridge == 'pandoc' && req.tool == 'convert' {
        return MCPResponse{
            status: 501
            headers: {}
            body: json.Value{}
            error: 'Pandoc conversion not yet implemented'
            deprecation: resp.deprecation
        }
    }
    
    return resp
}

fn (p PandocAdapter) health_check() HealthStatus {
    if os.file_exists(p.pandoc_path) {
        return .healthy
    }
    return .unavailable
}

fn (p PandocAdapter) capabilities() []Capability {
    return [
        Capability{
            id: 'document_conversion'
            name: 'Document Conversion'
            description: 'Convert between document formats'
        }
        Capability{
            id: 'format_analysis'
            name: 'Format Analysis'
            description: 'Analyze document formats'
        }
    ]
}

// Adapter registry
pub mut adapter_registry map[string]LegacyAdapter

// Register all legacy adapters
pub fn register_legacy_adapters() {
    // WordPress adapter
    wordpress := WordPressAdapter{
        base_url: 'http://localhost:8080'  // Default WordPress URL
    }
    adapter_registry['wordpress'] = wordpress
    
    // HOL adapter
    hol := HolAdapter{
        hol_path: '/usr/bin/hol'  // Default HOL path
    }
    adapter_registry['hol'] = hol
    
    // Julia adapter
    julia := JuliaAdapter{
        julia_path: '/usr/bin/julia'  // Default Julia path
    }
    adapter_registry['julia'] = julia
    
    // Pandoc adapter
    pandoc := PandocAdapter{
        pandoc_path: '/usr/bin/pandoc'  // Default Pandoc path
    }
    adapter_registry['pandoc'] = pandoc
}

// Get adapter by ID
pub fn get_adapter(adapter_id string) ?LegacyAdapter {
    if adapter_registry.has(adapter_id) {
        return adapter_registry[adapter_id]
    }
    return error('Adapter not found')
}

// Initialize legacy adapters
init {
    register_legacy_adapters()
}