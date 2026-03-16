// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// slack_mcp_adapter.v — V-lang REST adapter for the Slack Web API cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes REST endpoints for all 16 Slack actions, connection management,
// rate-limit inspection, and workspace status.

module slack_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lslack_mcp

fn C.slack_mcp_can_transition(from int, to int) int
fn C.slack_mcp_authenticate(token &u8) int
fn C.slack_mcp_disconnect(slot_idx int) int
fn C.slack_mcp_session_state(slot_idx int) int
fn C.slack_mcp_workspace(slot_idx int, out_buf &u8, out_cap int, out_len &int) int
fn C.slack_mcp_messages_sent(slot_idx int) int
fn C.slack_mcp_rate_count(slot_idx int, tier_id int) int
fn C.slack_mcp_rate_recover(slot_idx int) int
fn C.slack_mcp_send_message(slot_idx int, channel &u8, text &u8, thread_ts &u8, out_buf &u8, out_cap int, out_len &int) int
fn C.slack_mcp_list_channels(slot_idx int, out_buf &u8, out_cap int, out_len &int) int
fn C.slack_mcp_search(slot_idx int, query &u8, out_buf &u8, out_cap int, out_len &int) int
fn C.slack_mcp_api_call(slot_idx int, action_id int, params &u8, out_buf &u8, out_cap int, out_len &int) int
fn C.slack_mcp_reset()

// ---------------------------------------------------------------------------
// Connection state enum (mirrors Idris2 ConnState / Zig ConnState)
// ---------------------------------------------------------------------------

enum ConnState {
	disconnected   = 0
	authenticating = 1
	connected      = 2
	rate_limited   = 3
	err            = 4
}

// ---------------------------------------------------------------------------
// Slack action IDs (mirrors Idris2 SlackAction / Zig SlackAction)
// ---------------------------------------------------------------------------

enum SlackActionId {
	send_message       = 0
	list_channels      = 1
	get_channel        = 2
	list_users         = 3
	get_user           = 4
	post_reaction      = 5
	remove_reaction    = 6
	upload_file        = 7
	search_messages    = 8
	list_conversations = 9
	get_thread         = 10
	update_message     = 11
	delete_message     = 12
	set_status         = 13
	create_channel     = 14
	invite_to_channel  = 15
}

// ---------------------------------------------------------------------------
// Helper: decode connection state integer to label
// ---------------------------------------------------------------------------

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'authenticating' }
		2 { 'connected' }
		3 { 'rate_limited' }
		4 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Response from authenticate / connect operations.
struct ConnectResponse {
	slot      int
	state     string
	workspace string
}

/// Response from state queries.
struct StateResponse {
	slot  int
	state string
}

/// Response from transition validation.
struct TransitionResponse {
	from  int
	to    int
	valid bool
}

/// Response from Slack API operations (generic JSON envelope).
struct ApiResponse {
	slot   int
	action string
	body   string
}

/// Rate-limit status for a single tier.
struct TierStatus {
	tier    int
	count   int
	budget  int
}

/// Aggregated rate-limit status across all tiers.
struct RateLimitStatus {
	slot  int
	tiers []TierStatus
}

/// Workspace + session metrics for panel data sources.
struct SessionMetrics {
	slot           int
	state          string
	workspace      string
	messages_sent  int
	rate_tiers     []TierStatus
}

// ---------------------------------------------------------------------------
// Adapter functions — connection lifecycle
// ---------------------------------------------------------------------------

/// Authenticate with Slack using a bot token (xoxb-*).
/// The token should be retrieved from vault-mcp before calling.
pub fn authenticate(token string) !ConnectResponse {
	slot := C.slack_mcp_authenticate(token.str)
	if slot == -1 {
		return error('no session slots available')
	}
	if slot == -3 {
		return error('empty token')
	}
	if slot == -4 {
		return error('invalid token prefix (expected xoxb-*)')
	}
	if slot < 0 {
		return error('authentication failed (code ${slot})')
	}

	mut ws_buf := []u8{len: 256}
	mut ws_len := 0
	C.slack_mcp_workspace(slot, ws_buf.data, 256, &ws_len)
	workspace := if ws_len > 0 { ws_buf[..ws_len].bytestr() } else { '' }

	return ConnectResponse{
		slot: slot
		state: 'connected'
		workspace: workspace
	}
}

/// Disconnect a session gracefully.
pub fn disconnect(slot int) !string {
	result := C.slack_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for disconnect') }
		else { return error('disconnect failed (code ${result})') }
	}
}

/// Get the current connection state of a session.
pub fn session_state(slot int) StateResponse {
	s := C.slack_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

/// Check if a state transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.slack_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Recover from a rate-limited state.
pub fn rate_recover(slot int) !string {
	result := C.slack_mcp_rate_recover(slot)
	return match result {
		0 { 'recovered slot ${slot} to connected' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not in rate_limited state') }
		else { return error('recovery failed (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions — Slack API actions (all 16)
// ---------------------------------------------------------------------------

/// Send a message to a channel, optionally as a threaded reply.
pub fn send_message(slot int, channel string, text string, thread_ts string) !ApiResponse {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	ts_ptr := if thread_ts.len > 0 { thread_ts.str } else { unsafe { nil } }
	result := C.slack_mcp_send_message(slot, channel.str, text.str, ts_ptr, buf.data, 8192, &out_len)
	if result < 0 {
		return error('send_message failed (code ${result})')
	}
	return ApiResponse{ slot: slot, action: 'send_message', body: buf[..out_len].bytestr() }
}

/// List channels in the workspace.
pub fn list_channels(slot int) !ApiResponse {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	result := C.slack_mcp_list_channels(slot, buf.data, 8192, &out_len)
	if result < 0 {
		return error('list_channels failed (code ${result})')
	}
	return ApiResponse{ slot: slot, action: 'list_channels', body: buf[..out_len].bytestr() }
}

/// Search messages matching a query.
pub fn search_messages(slot int, query string) !ApiResponse {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	result := C.slack_mcp_search(slot, query.str, buf.data, 8192, &out_len)
	if result < 0 {
		return error('search_messages failed (code ${result})')
	}
	return ApiResponse{ slot: slot, action: 'search_messages', body: buf[..out_len].bytestr() }
}

/// Generic API call by action ID. Covers all 16 actions.
pub fn api_call(slot int, action_id int, params string) !ApiResponse {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	params_ptr := if params.len > 0 { params.str } else { unsafe { nil } }
	result := C.slack_mcp_api_call(slot, action_id, params_ptr, buf.data, 8192, &out_len)
	if result == -6 {
		return error('unknown action id ${action_id}')
	}
	if result < 0 {
		return error('api_call failed (code ${result})')
	}

	action_name := match action_id {
		0 { 'send_message' }
		1 { 'list_channels' }
		2 { 'get_channel' }
		3 { 'list_users' }
		4 { 'get_user' }
		5 { 'post_reaction' }
		6 { 'remove_reaction' }
		7 { 'upload_file' }
		8 { 'search_messages' }
		9 { 'list_conversations' }
		10 { 'get_thread' }
		11 { 'update_message' }
		12 { 'delete_message' }
		13 { 'set_status' }
		14 { 'create_channel' }
		15 { 'invite_to_channel' }
		else { 'unknown' }
	}
	return ApiResponse{ slot: slot, action: action_name, body: buf[..out_len].bytestr() }
}

// ---------------------------------------------------------------------------
// Convenience wrappers for each action (delegate to api_call)
// ---------------------------------------------------------------------------

/// Get info about a specific channel.
pub fn get_channel(slot int, channel_id string) !ApiResponse {
	return api_call(slot, int(SlackActionId.get_channel), '{"channel":"${channel_id}"}')
}

/// List users in the workspace.
pub fn list_users(slot int) !ApiResponse {
	return api_call(slot, int(SlackActionId.list_users), '')
}

/// Get info about a specific user.
pub fn get_user(slot int, user_id string) !ApiResponse {
	return api_call(slot, int(SlackActionId.get_user), '{"user":"${user_id}"}')
}

/// Add a reaction to a message.
pub fn post_reaction(slot int, channel string, timestamp string, emoji string) !ApiResponse {
	return api_call(slot, int(SlackActionId.post_reaction), '{"channel":"${channel}","timestamp":"${timestamp}","name":"${emoji}"}')
}

/// Remove a reaction from a message.
pub fn remove_reaction(slot int, channel string, timestamp string, emoji string) !ApiResponse {
	return api_call(slot, int(SlackActionId.remove_reaction), '{"channel":"${channel}","timestamp":"${timestamp}","name":"${emoji}"}')
}

/// Upload a file to a channel.
pub fn upload_file(slot int, channel string, filename string, content string) !ApiResponse {
	return api_call(slot, int(SlackActionId.upload_file), '{"channels":"${channel}","filename":"${filename}"}')
}

/// List conversations with optional type filter.
pub fn list_conversations(slot int, types string) !ApiResponse {
	return api_call(slot, int(SlackActionId.list_conversations), '{"types":"${types}"}')
}

/// Get replies in a message thread.
pub fn get_thread(slot int, channel string, thread_ts string) !ApiResponse {
	return api_call(slot, int(SlackActionId.get_thread), '{"channel":"${channel}","ts":"${thread_ts}"}')
}

/// Update an existing message.
pub fn update_message(slot int, channel string, ts string, text string) !ApiResponse {
	return api_call(slot, int(SlackActionId.update_message), '{"channel":"${channel}","ts":"${ts}","text":"${text}"}')
}

/// Delete a message.
pub fn delete_message(slot int, channel string, ts string) !ApiResponse {
	return api_call(slot, int(SlackActionId.delete_message), '{"channel":"${channel}","ts":"${ts}"}')
}

/// Set the authenticated user's status.
pub fn set_status(slot int, status_text string, status_emoji string) !ApiResponse {
	return api_call(slot, int(SlackActionId.set_status), '{"profile":{"status_text":"${status_text}","status_emoji":"${status_emoji}"}}')
}

/// Create a new channel.
pub fn create_channel(slot int, name string, is_private bool) !ApiResponse {
	priv := if is_private { 'true' } else { 'false' }
	return api_call(slot, int(SlackActionId.create_channel), '{"name":"${name}","is_private":${priv}}')
}

/// Invite a user to a channel.
pub fn invite_to_channel(slot int, channel string, user_id string) !ApiResponse {
	return api_call(slot, int(SlackActionId.invite_to_channel), '{"channel":"${channel}","users":"${user_id}"}')
}

// ---------------------------------------------------------------------------
// Adapter functions — metrics and rate limits (for PanLL panels)
// ---------------------------------------------------------------------------

/// Get rate-limit counters for all four tiers.
pub fn rate_limit_status(slot int) RateLimitStatus {
	mut tiers := []TierStatus{cap: 4}
	budgets := [1, 20, 50, 100]
	for tier_id in 1 .. 5 {
		count := C.slack_mcp_rate_count(slot, tier_id)
		tiers << TierStatus{
			tier: tier_id
			count: if count >= 0 { count } else { 0 }
			budget: budgets[tier_id - 1]
		}
	}
	return RateLimitStatus{ slot: slot, tiers: tiers }
}

/// Get full session metrics (state, workspace, messages, rate tiers).
pub fn session_metrics(slot int) SessionMetrics {
	st := C.slack_mcp_session_state(slot)

	mut ws_buf := []u8{len: 256}
	mut ws_len := 0
	C.slack_mcp_workspace(slot, ws_buf.data, 256, &ws_len)
	workspace := if ws_len > 0 { ws_buf[..ws_len].bytestr() } else { '' }

	msgs := C.slack_mcp_messages_sent(slot)
	rates := rate_limit_status(slot)

	return SessionMetrics{
		slot: slot
		state: state_label(st)
		workspace: workspace
		messages_sent: if msgs >= 0 { msgs } else { 0 }
		rate_tiers: rates.tiers
	}
}

/// Reset all sessions (test/debug use only).
pub fn reset() {
	C.slack_mcp_reset()
}
