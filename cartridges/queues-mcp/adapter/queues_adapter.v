// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Queues-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (queues_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides queue connection, subscription lifecycle, message consumption
// with ack enforcement, and publish operations via the BoJ triple adapter.

module queues_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against queues_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.queue_connect(backend int) int
fn C.queue_subscribe(slot_idx int) int
fn C.queue_begin_consume(slot_idx int) int
fn C.queue_ack(slot_idx int) int
fn C.queue_publish(slot_idx int) int
fn C.queue_unsubscribe(slot_idx int) int
fn C.queue_disconnect(slot_idx int) int
fn C.queue_state(slot_idx int) int
fn C.queue_msg_count(slot_idx int) int
fn C.queue_can_transition(from int, to int) int
fn C.queue_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum QueueState {
	disconnected = 0
	connected = 1
	subscribed = 2
	consuming = 3
	queue_error = 4
}

enum QueueBackend {
	redis_stream = 1
	rabbitmq = 2
	nats = 3
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'connected' }
		2 { 'subscribed' }
		3 { 'consuming' }
		4 { 'queue_error' }
		else { 'unknown' }
	}
}

fn backend_label(b QueueBackend) string {
	return match b {
		.redis_stream { 'RedisStream' }
		.rabbitmq { 'RabbitMQ' }
		.nats { 'NATS' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct ConnectResponse {
	slot    int
	backend string
	state   string
}

struct StateResponse {
	slot      int
	state     string
	msg_count int
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn connect(backend_name string) !ConnectResponse {
	b := match backend_name {
		'redis_stream' { int(QueueBackend.redis_stream) }
		'rabbitmq' { int(QueueBackend.rabbitmq) }
		'nats' { int(QueueBackend.nats) }
		else { return error('unknown backend: ${backend_name}') }
	}
	slot := C.queue_connect(b)
	if slot < 0 {
		return error('no queue slots available')
	}
	return ConnectResponse{
		slot: slot
		backend: backend_name
		state: 'connected'
	}
}

pub fn subscribe(slot int) !string {
	result := C.queue_subscribe(slot)
	return match result {
		0 { 'subscribed on slot ${slot}' }
		-1 { return error('slot ${slot} not active or not connected') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn begin_consume(slot int) !string {
	result := C.queue_begin_consume(slot)
	return match result {
		0 { 'consuming on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot consume from current state (subscribed?)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn ack(slot int) !string {
	result := C.queue_ack(slot)
	return match result {
		0 { 'message acknowledged on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot ack from current state (consuming?)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn publish(slot int) !string {
	result := C.queue_publish(slot)
	return match result {
		0 { 'message published on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot publish from current state (connected?)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn unsubscribe(slot int) !string {
	result := C.queue_unsubscribe(slot)
	return match result {
		0 { 'unsubscribed from slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition (ack pending messages first)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn disconnect(slot int) !string {
	result := C.queue_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active or already disconnected') }
		-2 { return error('invalid state transition (unsubscribe first)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.queue_state(slot)
	mc := C.queue_msg_count(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
		msg_count: mc
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.queue_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.queue_reset()
}
