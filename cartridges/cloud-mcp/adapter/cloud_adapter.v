// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Cloud-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (cloud_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides provider session lifecycle management, operation execution,
// and state machine inspection via the BoJ triple adapter.

module cloud_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against cloud_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.cloud_authenticate(provider int) int
fn C.cloud_logout(slot_idx int) int
fn C.cloud_begin_operation(slot_idx int) int
fn C.cloud_end_operation(slot_idx int) int
fn C.cloud_state(slot_idx int) int
fn C.cloud_can_transition(from int, to int) int
fn C.cloud_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum SessionState {
	unauthenticated = 0
	authenticated = 1
	operating = 2
	auth_error = 3
}

enum CloudProvider {
	aws = 1
	gcloud = 2
	azure = 3
	digital_ocean = 4
	verpex = 5
	cloudflare = 6
	vercel = 7
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'auth_error' }
		else { 'unknown' }
	}
}

fn provider_label(p CloudProvider) string {
	return match p {
		.aws { 'AWS' }
		.gcloud { 'GCloud' }
		.azure { 'Azure' }
		.digital_ocean { 'DigitalOcean' }
		.verpex { 'Verpex' }
		.cloudflare { 'Cloudflare' }
		.vercel { 'Vercel' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct AuthResponse {
	slot     int
	provider string
	state    string
}

struct StateResponse {
	slot  int
	state string
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn authenticate(provider_name string) !AuthResponse {
	p := match provider_name {
		'aws' { int(CloudProvider.aws) }
		'gcloud' { int(CloudProvider.gcloud) }
		'azure' { int(CloudProvider.azure) }
		'digitalocean' { int(CloudProvider.digital_ocean) }
		'verpex' { int(CloudProvider.verpex) }
		'cloudflare' { int(CloudProvider.cloudflare) }
		'vercel' { int(CloudProvider.vercel) }
		else { return error('unknown provider: ${provider_name}') }
	}
	slot := C.cloud_authenticate(p)
	if slot < 0 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		provider: provider_name
		state: 'authenticated'
	}
}

pub fn logout(slot int) !string {
	result := C.cloud_logout(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active or already unauthenticated') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.cloud_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn begin_operation(slot int) !string {
	result := C.cloud_begin_operation(slot)
	return match result {
		0 { 'operation started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_operation(slot int) !string {
	result := C.cloud_end_operation(slot)
	return match result {
		0 { 'operation completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.cloud_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.cloud_reset()
}

// ═══════════════════════════════════════════════════════════════════════
// Vercel Provider — C FFI declarations
// ═══════════════════════════════════════════════════════════════════════

fn C.cloud_vercel_set_credentials(slot_idx int, token_ptr &u8, token_len usize) int
fn C.cloud_vercel_list_projects(slot_idx int) int
fn C.cloud_vercel_get_project(slot_idx int, name_ptr &u8, name_len usize) int
fn C.cloud_vercel_list_deployments(slot_idx int) int
fn C.cloud_vercel_get_deployment(slot_idx int, id_ptr &u8, id_len usize) int
fn C.cloud_vercel_list_domains(slot_idx int) int
fn C.cloud_vercel_list_env_vars(slot_idx int, project_ptr &u8, project_len usize) int
fn C.cloud_vercel_deployment_logs(slot_idx int, id_ptr &u8, id_len usize) int
fn C.cloud_vercel_list_functions(slot_idx int, deployment_ptr &u8, deployment_len usize) int
fn C.cloud_vercel_read_result(slot_idx int, out_ptr &u8, out_cap usize) int

// ═══════════════════════════════════════════════════════════════════════
// Vercel Provider — Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

struct VercelResponse {
	slot     int
	provider string
	result   string
}

/// Authenticate with Vercel and store a bearer token.
pub fn vercel_authenticate(token string) !VercelResponse {
	slot := C.cloud_authenticate(int(CloudProvider.vercel))
	if slot < 0 {
		return error('no session slots available for Vercel')
	}
	rc := C.cloud_vercel_set_credentials(slot, token.str, usize(token.len))
	if rc < 0 {
		_ = C.cloud_logout(slot)
		return error('failed to set Vercel credentials on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: 'authenticated'
	}
}

/// Read the JSON result buffer from a Vercel operation.
fn read_vercel_result(slot int) string {
	mut buf := []u8{len: 4096}
	rc := C.cloud_vercel_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// List all Vercel projects.
pub fn vercel_list_projects(slot int) !VercelResponse {
	rc := C.cloud_vercel_list_projects(slot)
	if rc < 0 {
		return error('vercel_list_projects failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

/// Get a specific Vercel project by name.
pub fn vercel_get_project(slot int, name string) !VercelResponse {
	rc := C.cloud_vercel_get_project(slot, name.str, usize(name.len))
	if rc < 0 {
		return error('vercel_get_project failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

/// List all Vercel deployments.
pub fn vercel_list_deployments(slot int) !VercelResponse {
	rc := C.cloud_vercel_list_deployments(slot)
	if rc < 0 {
		return error('vercel_list_deployments failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

/// Get a specific Vercel deployment by ID.
pub fn vercel_get_deployment(slot int, id string) !VercelResponse {
	rc := C.cloud_vercel_get_deployment(slot, id.str, usize(id.len))
	if rc < 0 {
		return error('vercel_get_deployment failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

/// List all Vercel domains.
pub fn vercel_list_domains(slot int) !VercelResponse {
	rc := C.cloud_vercel_list_domains(slot)
	if rc < 0 {
		return error('vercel_list_domains failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

/// List environment variables for a Vercel project.
pub fn vercel_list_env_vars(slot int, project string) !VercelResponse {
	rc := C.cloud_vercel_list_env_vars(slot, project.str, usize(project.len))
	if rc < 0 {
		return error('vercel_list_env_vars failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

/// Get deployment logs for a Vercel deployment.
pub fn vercel_deployment_logs(slot int, id string) !VercelResponse {
	rc := C.cloud_vercel_deployment_logs(slot, id.str, usize(id.len))
	if rc < 0 {
		return error('vercel_deployment_logs failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

/// List serverless functions for a Vercel deployment.
pub fn vercel_list_functions(slot int, deployment_id string) !VercelResponse {
	rc := C.cloud_vercel_list_functions(slot, deployment_id.str, usize(deployment_id.len))
	if rc < 0 {
		return error('vercel_list_functions failed on slot ${slot}')
	}
	return VercelResponse{
		slot: slot
		provider: 'vercel'
		result: read_vercel_result(slot)
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Cloudflare Provider — C FFI declarations
// ═══════════════════════════════════════════════════════════════════════

fn C.cloud_cf_set_credentials(slot_idx int, token_ptr &u8, token_len usize) int
fn C.cloud_cf_list_workers(slot_idx int) int
fn C.cloud_cf_get_worker(slot_idx int, name_ptr &u8, name_len usize) int
fn C.cloud_cf_list_d1(slot_idx int) int
fn C.cloud_cf_query_d1(slot_idx int, json_ptr &u8, json_len usize) int
fn C.cloud_cf_list_kv(slot_idx int) int
fn C.cloud_cf_kv_get(slot_idx int, json_ptr &u8, json_len usize) int
fn C.cloud_cf_kv_put(slot_idx int, json_ptr &u8, json_len usize) int
fn C.cloud_cf_list_r2(slot_idx int) int
fn C.cloud_cf_list_dns_zones(slot_idx int) int
fn C.cloud_cf_list_dns_records(slot_idx int, zone_ptr &u8, zone_len usize) int
fn C.cloud_cf_add_dns_record(slot_idx int, json_ptr &u8, json_len usize) int
fn C.cloud_cf_read_result(slot_idx int, out_ptr &u8, out_cap usize) int

// ═══════════════════════════════════════════════════════════════════════
// Cloudflare Provider — Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

struct CloudflareResponse {
	slot     int
	provider string
	result   string
}

/// Read the JSON result buffer from a Cloudflare operation.
fn read_cf_result(slot int) string {
	mut buf := []u8{len: 4096}
	rc := C.cloud_cf_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// Authenticate with Cloudflare and store a bearer token.
pub fn cloudflare_authenticate(token string) !CloudflareResponse {
	slot := C.cloud_authenticate(int(CloudProvider.cloudflare))
	if slot < 0 {
		return error('no session slots available for Cloudflare')
	}
	rc := C.cloud_cf_set_credentials(slot, token.str, usize(token.len))
	if rc < 0 {
		_ = C.cloud_logout(slot)
		return error('failed to set Cloudflare credentials on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: 'authenticated'
	}
}

/// List all Cloudflare Workers scripts.
pub fn cf_list_workers(slot int) !CloudflareResponse {
	rc := C.cloud_cf_list_workers(slot)
	if rc < 0 {
		return error('cf_list_workers failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// Get a specific Cloudflare Worker by name.
pub fn cf_get_worker(slot int, name string) !CloudflareResponse {
	rc := C.cloud_cf_get_worker(slot, name.str, usize(name.len))
	if rc < 0 {
		return error('cf_get_worker failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// List all Cloudflare D1 databases.
pub fn cf_list_d1(slot int) !CloudflareResponse {
	rc := C.cloud_cf_list_d1(slot)
	if rc < 0 {
		return error('cf_list_d1 failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// Query a Cloudflare D1 database with SQL JSON payload.
pub fn cf_query_d1(slot int, query_json string) !CloudflareResponse {
	rc := C.cloud_cf_query_d1(slot, query_json.str, usize(query_json.len))
	if rc < 0 {
		return error('cf_query_d1 failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// List all Cloudflare KV namespaces.
pub fn cf_list_kv(slot int) !CloudflareResponse {
	rc := C.cloud_cf_list_kv(slot)
	if rc < 0 {
		return error('cf_list_kv failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// Get a value from a Cloudflare KV namespace.
pub fn cf_kv_get(slot int, request_json string) !CloudflareResponse {
	rc := C.cloud_cf_kv_get(slot, request_json.str, usize(request_json.len))
	if rc < 0 {
		return error('cf_kv_get failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// Put a value into a Cloudflare KV namespace.
pub fn cf_kv_put(slot int, request_json string) !CloudflareResponse {
	rc := C.cloud_cf_kv_put(slot, request_json.str, usize(request_json.len))
	if rc < 0 {
		return error('cf_kv_put failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// List all Cloudflare R2 buckets.
pub fn cf_list_r2(slot int) !CloudflareResponse {
	rc := C.cloud_cf_list_r2(slot)
	if rc < 0 {
		return error('cf_list_r2 failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// List all Cloudflare DNS zones.
pub fn cf_list_dns_zones(slot int) !CloudflareResponse {
	rc := C.cloud_cf_list_dns_zones(slot)
	if rc < 0 {
		return error('cf_list_dns_zones failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// List DNS records for a specific Cloudflare zone.
pub fn cf_list_dns_records(slot int, zone_id string) !CloudflareResponse {
	rc := C.cloud_cf_list_dns_records(slot, zone_id.str, usize(zone_id.len))
	if rc < 0 {
		return error('cf_list_dns_records failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

/// Add a DNS record to a Cloudflare zone.
pub fn cf_add_dns_record(slot int, record_json string) !CloudflareResponse {
	rc := C.cloud_cf_add_dns_record(slot, record_json.str, usize(record_json.len))
	if rc < 0 {
		return error('cf_add_dns_record failed on slot ${slot}')
	}
	return CloudflareResponse{
		slot: slot
		provider: 'cloudflare'
		result: read_cf_result(slot)
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Verpex Provider — C FFI declarations
// ═══════════════════════════════════════════════════════════════════════

fn C.cloud_verpex_set_credentials(slot_idx int, host_ptr &u8, host_len usize, user_ptr &u8, user_len usize, token_ptr &u8, token_len usize) int
fn C.cloud_verpex_list_domains(slot_idx int) int
fn C.cloud_verpex_list_dns(slot_idx int, domain_ptr &u8, domain_len usize) int
fn C.cloud_verpex_add_dns(slot_idx int, json_ptr &u8, json_len usize) int
fn C.cloud_verpex_remove_dns(slot_idx int, json_ptr &u8, json_len usize) int
fn C.cloud_verpex_list_email(slot_idx int) int
fn C.cloud_verpex_create_email(slot_idx int, json_ptr &u8, json_len usize) int
fn C.cloud_verpex_list_databases(slot_idx int) int
fn C.cloud_verpex_create_database(slot_idx int, name_ptr &u8, name_len usize) int
fn C.cloud_verpex_ssl_status(slot_idx int, domain_ptr &u8, domain_len usize) int
fn C.cloud_verpex_list_cron(slot_idx int) int
fn C.cloud_verpex_metrics(slot_idx int) int
fn C.cloud_verpex_read_result(slot_idx int, out_ptr &u8, out_cap usize) int

// ═══════════════════════════════════════════════════════════════════════
// Verpex Provider — Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

struct VerpexResponse {
	slot     int
	provider string
	result   string
}

/// Read the JSON result buffer from a Verpex operation.
fn read_verpex_result(slot int) string {
	mut buf := []u8{len: 4096}
	rc := C.cloud_verpex_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// Authenticate with Verpex and store cPanel credentials (hostname + username + api_token).
pub fn verpex_authenticate(hostname string, username string, api_token string) !VerpexResponse {
	slot := C.cloud_authenticate(int(CloudProvider.verpex))
	if slot < 0 {
		return error('no session slots available for Verpex')
	}
	rc := C.cloud_verpex_set_credentials(
		slot,
		hostname.str,
		usize(hostname.len),
		username.str,
		usize(username.len),
		api_token.str,
		usize(api_token.len),
	)
	if rc < 0 {
		_ = C.cloud_logout(slot)
		return error('failed to set Verpex credentials on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: 'authenticated'
	}
}

/// List all domains on the Verpex hosting account.
pub fn verpex_list_domains(slot int) !VerpexResponse {
	rc := C.cloud_verpex_list_domains(slot)
	if rc < 0 {
		return error('verpex_list_domains failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// List DNS zone records for a domain.
pub fn verpex_dns_list(slot int, domain string) !VerpexResponse {
	rc := C.cloud_verpex_list_dns(slot, domain.str, usize(domain.len))
	if rc < 0 {
		return error('verpex_dns_list failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// Add a DNS record to a domain. params_json contains the record definition.
pub fn verpex_dns_add(slot int, params_json string) !VerpexResponse {
	rc := C.cloud_verpex_add_dns(slot, params_json.str, usize(params_json.len))
	if rc < 0 {
		return error('verpex_dns_add failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// Remove a DNS record from a domain. params_json identifies the record to remove.
pub fn verpex_dns_remove(slot int, params_json string) !VerpexResponse {
	rc := C.cloud_verpex_remove_dns(slot, params_json.str, usize(params_json.len))
	if rc < 0 {
		return error('verpex_dns_remove failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// List all email accounts on the hosting account.
pub fn verpex_email_list(slot int) !VerpexResponse {
	rc := C.cloud_verpex_list_email(slot)
	if rc < 0 {
		return error('verpex_email_list failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// Create an email account. params_json contains account details.
pub fn verpex_email_create(slot int, params_json string) !VerpexResponse {
	rc := C.cloud_verpex_create_email(slot, params_json.str, usize(params_json.len))
	if rc < 0 {
		return error('verpex_email_create failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// List all MySQL databases on the hosting account.
pub fn verpex_databases_list(slot int) !VerpexResponse {
	rc := C.cloud_verpex_list_databases(slot)
	if rc < 0 {
		return error('verpex_databases_list failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// Create a MySQL database with the given name.
pub fn verpex_database_create(slot int, name string) !VerpexResponse {
	rc := C.cloud_verpex_create_database(slot, name.str, usize(name.len))
	if rc < 0 {
		return error('verpex_database_create failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// Get SSL/TLS certificate status for a domain.
pub fn verpex_ssl_status(slot int, domain string) !VerpexResponse {
	rc := C.cloud_verpex_ssl_status(slot, domain.str, usize(domain.len))
	if rc < 0 {
		return error('verpex_ssl_status failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// List all cron jobs on the hosting account.
pub fn verpex_cron_list(slot int) !VerpexResponse {
	rc := C.cloud_verpex_list_cron(slot)
	if rc < 0 {
		return error('verpex_cron_list failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}

/// Get hosting metrics and resource usage.
pub fn verpex_metrics(slot int) !VerpexResponse {
	rc := C.cloud_verpex_metrics(slot)
	if rc < 0 {
		return error('verpex_metrics failed on slot ${slot}')
	}
	return VerpexResponse{
		slot: slot
		provider: 'verpex'
		result: read_verpex_result(slot)
	}
}
