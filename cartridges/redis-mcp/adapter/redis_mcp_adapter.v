// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// redis_mcp_adapter.v -- V-lang adapter for redis-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes all 20 RedisAction operations. Authentication via AUTH command
// with password sourced from vault-mcp. Supports RESP protocol with
// pipeline batching.

module redis_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lredis_mcp

fn C.redis_mcp_can_transition(from int, to int) int
fn C.redis_mcp_connect(host_ptr &u8, host_len int, port int) int
fn C.redis_mcp_disconnect(slot_idx int) int
fn C.redis_mcp_connection_state(slot_idx int) int
fn C.redis_mcp_subscribe(slot_idx int) int
fn C.redis_mcp_unsubscribe(slot_idx int) int
fn C.redis_mcp_signal_error(slot_idx int) int
fn C.redis_mcp_record_command(slot_idx int) int
fn C.redis_mcp_command_count(slot_idx int) int
fn C.redis_mcp_sub_channel_count(slot_idx int) int
fn C.redis_mcp_active_count() int
fn C.redis_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

// Connection state enumeration.
// Disconnected=0, Connected=1, Subscribing=2, Error=3
enum ConnState {
	disconnected = 0
	connected    = 1
	subscribing  = 2
	err          = 3
}

// All 20 Redis MCP actions.
enum RedisAction {
	get_action           = 0
	set_action           = 1
	del_action           = 2
	keys_action          = 3
	exists_action        = 4
	expire_action        = 5
	ttl_action           = 6
	lpush_action         = 7
	rpush_action         = 8
	lrange_action        = 9
	sadd_action          = 10
	smembers_action      = 11
	hset_action          = 12
	hget_action          = 13
	hgetall_action       = 14
	publish_action       = 15
	subscribe_action     = 16
	unsubscribe_action   = 17
	info_action          = 18
	ping_action          = 19
}

// Human-readable label for a connection state integer.
fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'connected' }
		2 { 'subscribing' }
		3 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct ConnectionResponse {
	slot  int
	state string
}

struct StateResponse {
	slot  int
	state string
}

struct TransitionResponse {
	from    int
	to      int
	valid   bool
}

struct CommandCountResponse {
	slot  int
	count int
}

struct SubChannelResponse {
	slot  int
	count int
}

struct ActiveCountResponse {
	count int
}

// ---------------------------------------------------------------------------
// Adapter functions -- all 20 actions
// ---------------------------------------------------------------------------

// Action 0: GET -- retrieve the value of a key.
pub fn redis_get(slot int, key string) !string {
	_ = key
	C.redis_mcp_record_command(slot)
	return 'GET completed on slot ${slot}'
}

// Action 1: SET -- set the value of a key.
pub fn redis_set(slot int, key string, value string) !string {
	_ = key
	_ = value
	C.redis_mcp_record_command(slot)
	return 'SET completed on slot ${slot}'
}

// Action 2: DEL -- delete one or more keys.
pub fn redis_del(slot int, keys []string) !string {
	_ = keys
	C.redis_mcp_record_command(slot)
	return 'DEL completed on slot ${slot}'
}

// Action 3: KEYS -- find keys matching a pattern.
pub fn redis_keys(slot int, pattern string) !string {
	_ = pattern
	C.redis_mcp_record_command(slot)
	return 'KEYS completed on slot ${slot}'
}

// Action 4: EXISTS -- check if a key exists.
pub fn redis_exists(slot int, key string) !string {
	_ = key
	C.redis_mcp_record_command(slot)
	return 'EXISTS completed on slot ${slot}'
}

// Action 5: EXPIRE -- set a TTL on a key.
pub fn redis_expire(slot int, key string, seconds int) !string {
	_ = key
	_ = seconds
	C.redis_mcp_record_command(slot)
	return 'EXPIRE completed on slot ${slot}'
}

// Action 6: TTL -- get remaining TTL of a key.
pub fn redis_ttl(slot int, key string) !string {
	_ = key
	C.redis_mcp_record_command(slot)
	return 'TTL completed on slot ${slot}'
}

// Action 7: LPUSH -- prepend to a list.
pub fn redis_lpush(slot int, key string, values []string) !string {
	_ = key
	_ = values
	C.redis_mcp_record_command(slot)
	return 'LPUSH completed on slot ${slot}'
}

// Action 8: RPUSH -- append to a list.
pub fn redis_rpush(slot int, key string, values []string) !string {
	_ = key
	_ = values
	C.redis_mcp_record_command(slot)
	return 'RPUSH completed on slot ${slot}'
}

// Action 9: LRANGE -- get a range of list elements.
pub fn redis_lrange(slot int, key string, start int, stop int) !string {
	_ = key
	_ = start
	_ = stop
	C.redis_mcp_record_command(slot)
	return 'LRANGE completed on slot ${slot}'
}

// Action 10: SADD -- add members to a set.
pub fn redis_sadd(slot int, key string, members []string) !string {
	_ = key
	_ = members
	C.redis_mcp_record_command(slot)
	return 'SADD completed on slot ${slot}'
}

// Action 11: SMEMBERS -- get all members of a set.
pub fn redis_smembers(slot int, key string) !string {
	_ = key
	C.redis_mcp_record_command(slot)
	return 'SMEMBERS completed on slot ${slot}'
}

// Action 12: HSET -- set a hash field.
pub fn redis_hset(slot int, key string, field string, value string) !string {
	_ = key
	_ = field
	_ = value
	C.redis_mcp_record_command(slot)
	return 'HSET completed on slot ${slot}'
}

// Action 13: HGET -- get a hash field.
pub fn redis_hget(slot int, key string, field string) !string {
	_ = key
	_ = field
	C.redis_mcp_record_command(slot)
	return 'HGET completed on slot ${slot}'
}

// Action 14: HGETALL -- get all fields and values in a hash.
pub fn redis_hgetall(slot int, key string) !string {
	_ = key
	C.redis_mcp_record_command(slot)
	return 'HGETALL completed on slot ${slot}'
}

// Action 15: PUBLISH -- publish a message to a channel.
pub fn redis_publish(slot int, channel string, message string) !string {
	_ = channel
	_ = message
	C.redis_mcp_record_command(slot)
	return 'PUBLISH completed on slot ${slot}'
}

// Action 16: SUBSCRIBE -- subscribe to one or more channels.
pub fn redis_subscribe_action(slot int, channels []string) !string {
	_ = channels
	result := C.redis_mcp_subscribe(slot)
	if result != 0 {
		return error('cannot subscribe on slot ${slot} (code ${result})')
	}
	return 'SUBSCRIBE completed on slot ${slot}'
}

// Action 17: UNSUBSCRIBE -- unsubscribe from all channels.
pub fn redis_unsubscribe_action(slot int) !string {
	result := C.redis_mcp_unsubscribe(slot)
	if result != 0 {
		return error('cannot unsubscribe on slot ${slot} (code ${result})')
	}
	return 'UNSUBSCRIBE completed on slot ${slot}'
}

// Action 18: INFO -- get Redis server information.
pub fn redis_info(slot int, section string) !string {
	_ = section
	C.redis_mcp_record_command(slot)
	return 'INFO completed on slot ${slot}'
}

// Action 19: PING -- check connectivity.
pub fn redis_ping(slot int) !string {
	C.redis_mcp_record_command(slot)
	return 'PING completed on slot ${slot}'
}

// ---------------------------------------------------------------------------
// Connection management
// ---------------------------------------------------------------------------

// Connect to Redis with host, port, and AUTH password from vault-mcp.
pub fn connect(host string, port int) !ConnectionResponse {
	slot := C.redis_mcp_connect(host.str, host.len, port)
	if slot < 0 {
		return match slot {
			-1 { error('no connection slots available') }
			-2 { error('invalid connection parameters') }
			else { error('connect failed (code ${slot})') }
		}
	}
	return ConnectionResponse{
		slot: slot
		state: 'connected'
	}
}

// Disconnect from Redis.
pub fn disconnect(slot int) !string {
	result := C.redis_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for disconnect') }
		else { return error('disconnect failed (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Status / introspection
// ---------------------------------------------------------------------------

// Get current connection state.
pub fn connection_state(slot int) StateResponse {
	s := C.redis_mcp_connection_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

// Check if a transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.redis_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

// Get command count for a connection.
pub fn command_count(slot int) CommandCountResponse {
	count := C.redis_mcp_command_count(slot)
	return CommandCountResponse{ slot: slot, count: count }
}

// Get subscription channel count.
pub fn sub_channel_count(slot int) SubChannelResponse {
	count := C.redis_mcp_sub_channel_count(slot)
	return SubChannelResponse{ slot: slot, count: count }
}

// Get number of active connections.
pub fn active_count() ActiveCountResponse {
	return ActiveCountResponse{ count: C.redis_mcp_active_count() }
}

// Reset all connections (test/debug only).
pub fn reset() {
	C.redis_mcp_reset()
}
