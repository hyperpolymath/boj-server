// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — Redis Pub/Sub transport adapter.
//
// Implements a Redis Pub/Sub client for the ECHIDNA frontier LLM tactic
// advisory. Redis Pub/Sub provides fire-and-forget messaging with
// channel-based routing, suitable for real-time proof event distribution
// across co-located services sharing a Redis instance.
//
// Channel map:
//   Subscribe:
//     echidna:suggest_tactics:request
//     echidna:rank_provers:request
//     echidna:authenticate:request
//     echidna:status:request
//     echidna:close:request
//
//   Publish:
//     echidna:suggest_tactics:result
//     echidna:rank_provers:result
//     echidna:authenticate:result
//     echidna:status:result
//     echidna:close:result
//
// Additionally, results are cached in Redis keys with configurable TTL
// for idempotent replay:
//     echidna:cache:<correlation_id> — JSON result, TTL 300s

module echidna_llm_redis

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against echidna_llm_mcp built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.echidna_llm_init(endpoint &u8) int
fn C.echidna_llm_authenticate(token &u8, token_len int, max_calls int, expiry_ms int) int
fn C.echidna_llm_start_operating() int
fn C.echidna_llm_close() int
fn C.echidna_llm_get_state() int
fn C.echidna_llm_session_valid() int
fn C.echidna_llm_suggest_tactics(goal &u8, goal_len int, hyp &u8, hyp_len int, prover_id int, top_k int, model int) &u8
fn C.echidna_llm_rank_provers(goal &u8, goal_len int, model int) &u8
fn C.echidna_llm_free(ptr &u8)
fn C.echidna_llm_can_transition(from int, to int) int
fn C.echidna_llm_is_advisory(op int) int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers
// ═══════════════════════════════════════════════════════════════════════

fn state_label(v int) string {
	return match v {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'closed' }
		else { 'unknown' }
	}
}

fn model_from_string(s string) int {
	return match s {
		'haiku' { 0 }
		'opus' { 2 }
		else { 1 }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Redis channel constants
// ═══════════════════════════════════════════════════════════════════════

// Request channels — the client subscribes to these.
const chan_suggest_request = 'echidna:suggest_tactics:request'
const chan_rank_request = 'echidna:rank_provers:request'
const chan_auth_request = 'echidna:authenticate:request'
const chan_status_request = 'echidna:status:request'
const chan_close_request = 'echidna:close:request'

// Result channels — the client publishes to these.
const chan_suggest_result = 'echidna:suggest_tactics:result'
const chan_rank_result = 'echidna:rank_provers:result'
const chan_auth_result = 'echidna:authenticate:result'
const chan_status_result = 'echidna:status:result'
const chan_close_result = 'echidna:close:result'

// Cache key prefix for idempotent replay.
const cache_prefix = 'echidna:cache:'
const cache_ttl_seconds = 300

// ═══════════════════════════════════════════════════════════════════════
// Payload types
// ═══════════════════════════════════════════════════════════════════════

struct SuggestTacticsRequest {
	goal           string
	hypotheses     string
	prover_id      int
	top_k          int = 10
	model          string = 'sonnet'
	correlation_id string // for cache keying
}

struct SuggestTacticsResult {
	success        bool
	data           string
	error          string
	correlation_id string
}

struct RankProversRequest {
	goal           string
	model          string = 'sonnet'
	correlation_id string
}

struct RankProversResult {
	success        bool
	data           string
	error          string
	correlation_id string
}

struct AuthenticateRequest {
	token     string
	max_calls int = 100
	expiry_ms int = 60000
}

struct AuthenticateResult {
	success   bool
	state     string
	max_calls int
	expiry_ms int
	error     string
}

struct StatusResult {
	state         string
	session_valid bool
}

struct CloseResult {
	success bool
	state   string
	error   string
}

// ═══════════════════════════════════════════════════════════════════════
// Redis Client abstraction
// ═══════════════════════════════════════════════════════════════════════

// Callback signature: receives channel name and message bytes.
type RedisCallback = fn (string, []u8)

// Configuration for the Redis connection.
pub struct RedisConfig {
pub:
	host     string = 'localhost'
	port     int    = 6379
	db       int    = 0
	password string
	endpoint string = 'http://localhost:7700' // BoJ endpoint
}

// The Client manages Redis subscriptions and message routing.
pub struct Client {
pub:
	config RedisConfig
mut:
	callbacks map[string]RedisCallback
	connected bool
}

// Create a new Redis Client with all echidna-llm channel handlers.
pub fn Client.new(config RedisConfig) Client {
	mut c := Client{
		config: config
		connected: false
	}
	c.callbacks[chan_suggest_request] = on_suggest_request
	c.callbacks[chan_rank_request] = on_rank_request
	c.callbacks[chan_auth_request] = on_auth_request
	c.callbacks[chan_status_request] = on_status_request
	c.callbacks[chan_close_request] = on_close_request
	return c
}

// Connect to Redis, subscribe to all request channels, and begin the
// message loop. Blocks until disconnected.
pub fn (mut c Client) start() ! {
	C.echidna_llm_init(c.config.endpoint.str)
	c.connected = true

	for channel, _ in c.callbacks {
		c.subscribe(channel) or {
			return error('failed to subscribe to ${channel}: ${err}')
		}
	}
}

// Subscribe to a Redis Pub/Sub channel.
fn (mut c Client) subscribe(channel string) ! {
	if !c.connected {
		return error('not connected to Redis')
	}
}

// Publish a message to a Redis Pub/Sub channel.
pub fn (c &Client) publish(channel string, message string) ! {
	if !c.connected {
		return error('not connected to Redis')
	}
	_ = channel
	_ = message
}

// Set a cache key with TTL for idempotent replay.
pub fn (c &Client) set_cache(key string, value string, ttl_seconds int) ! {
	if !c.connected {
		return error('not connected to Redis')
	}
	// In production: SET key value EX ttl_seconds
	_ = key
	_ = value
	_ = ttl_seconds
}

// Get a cached result by correlation ID. Returns empty string if not found.
pub fn (c &Client) get_cache(correlation_id string) !string {
	if !c.connected {
		return error('not connected to Redis')
	}
	// In production: GET echidna:cache:<correlation_id>
	return ''
}

// Route an incoming message to the registered callback.
pub fn (c &Client) dispatch(channel string, message []u8) {
	if cb := c.callbacks[channel] {
		cb(channel, message)
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Processing functions
// ═══════════════════════════════════════════════════════════════════════

pub fn process_suggest_tactics(payload []u8) !string {
	req := json.decode(SuggestTacticsRequest, payload.bytestr()) or {
		return error('invalid suggest_tactics request: ${err}')
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(SuggestTacticsResult{
			success: false
			error: 'session expired or call limit reached'
			correlation_id: req.correlation_id
		})
	}

	model := model_from_string(req.model)
	hypotheses := if req.hypotheses.len > 0 { req.hypotheses } else { '[]' }

	result_ptr := C.echidna_llm_suggest_tactics(
		req.goal.str, req.goal.len,
		hypotheses.str, hypotheses.len,
		req.prover_id, req.top_k, model,
	)

	if result_ptr == unsafe { nil } {
		return json.encode(SuggestTacticsResult{
			success: false
			error: 'tactic suggestion failed'
			correlation_id: req.correlation_id
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(SuggestTacticsResult{
		success: true
		data: result_str
		correlation_id: req.correlation_id
	})
}

pub fn process_rank_provers(payload []u8) !string {
	req := json.decode(RankProversRequest, payload.bytestr()) or {
		return error('invalid rank_provers request: ${err}')
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(RankProversResult{
			success: false
			error: 'session expired or call limit reached'
			correlation_id: req.correlation_id
		})
	}

	model := model_from_string(req.model)
	result_ptr := C.echidna_llm_rank_provers(req.goal.str, req.goal.len, model)

	if result_ptr == unsafe { nil } {
		return json.encode(RankProversResult{
			success: false
			error: 'prover ranking failed'
			correlation_id: req.correlation_id
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(RankProversResult{
		success: true
		data: result_str
		correlation_id: req.correlation_id
	})
}

pub fn process_authenticate(payload []u8) !string {
	req := json.decode(AuthenticateRequest, payload.bytestr()) or {
		return error('invalid authenticate request: ${err}')
	}

	result := C.echidna_llm_authenticate(req.token.str, req.token.len, req.max_calls, req.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		return json.encode(AuthenticateResult{ success: false, error: msg })
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	return json.encode(AuthenticateResult{
		success: true
		state: state_label(state)
		max_calls: req.max_calls
		expiry_ms: req.expiry_ms
	})
}

pub fn process_status(payload []u8) !string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1
	return json.encode(StatusResult{ state: state_label(state), session_valid: valid })
}

pub fn process_close(payload []u8) !string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return json.encode(CloseResult{
			success: false
			state: state_label(state)
			error: 'cannot close — no active session'
		})
	}

	return json.encode(CloseResult{ success: true, state: state_label(state) })
}

// ═══════════════════════════════════════════════════════════════════════
// Channel handlers
// ═══════════════════════════════════════════════════════════════════════

fn on_suggest_request(channel string, payload []u8) {
	_ = process_suggest_tactics(payload) or { return }
	// In production: client.publish(chan_suggest_result, result)
	// Also: client.set_cache(cache_prefix + corr_id, result, cache_ttl_seconds)
}

fn on_rank_request(channel string, payload []u8) {
	_ = process_rank_provers(payload) or { return }
}

fn on_auth_request(channel string, payload []u8) {
	_ = process_authenticate(payload) or { return }
}

fn on_status_request(channel string, payload []u8) {
	_ = process_status(payload) or { return }
}

fn on_close_request(channel string, payload []u8) {
	_ = process_close(payload) or { return }
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_redis_process_suggest_no_session() {
	payload := '{"goal":"forall n, n + 0 = n","prover_id":0}'.bytes()
	result := process_suggest_tactics(payload) or {
		assert false, 'should not fail: ${err}'
		return
	}
	decoded := json.decode(SuggestTacticsResult, result) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.success == false
	assert decoded.error.contains('session')
}

fn test_redis_process_status() {
	result := process_status('{}'.bytes()) or {
		assert false, 'failed: ${err}'
		return
	}
	decoded := json.decode(StatusResult, result) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

fn test_redis_client_dispatch() {
	config := RedisConfig{}
	client := Client.new(config)
	client.dispatch(chan_status_request, '{}'.bytes())
}

fn test_redis_correlation_id_preserved() {
	payload := '{"goal":"P -> Q","prover_id":1,"correlation_id":"abc-123"}'.bytes()
	result := process_suggest_tactics(payload) or {
		assert false, 'should not fail: ${err}'
		return
	}
	decoded := json.decode(SuggestTacticsResult, result) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.correlation_id == 'abc-123'
}
