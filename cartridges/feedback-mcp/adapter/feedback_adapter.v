// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Feedback-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (feedback_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides channel registration, feedback submission, sentiment tracking,
// and state machine inspection via the BoJ triple adapter.

module feedback_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against feedback_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.fb_register(channel_type int) int
fn C.fb_start_collecting(slot_idx int) int
fn C.fb_submit(slot_idx int, sentiment int) int
fn C.fb_state(slot_idx int) int
fn C.fb_count(slot_idx int) int
fn C.fb_positive_count(slot_idx int) int
fn C.fb_negative_count(slot_idx int) int
fn C.fb_neutral_count(slot_idx int) int
fn C.fb_deregister(slot_idx int) int
fn C.fb_can_transition(from int, to int) int
fn C.fb_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum FeedbackState {
	inactive = 0
	channel_registered = 1
	collecting = 2
	processing = 3
	feedback_error = 4
}

enum FeedbackChannel {
	web_form = 1
	api_endpoint = 2
	email = 3
	irc = 4
	mastodon = 5
	gitea = 6
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'inactive' }
		1 { 'channel_registered' }
		2 { 'collecting' }
		3 { 'processing' }
		4 { 'error' }
		else { 'unknown' }
	}
}

fn channel_label(c FeedbackChannel) string {
	return match c {
		.web_form { 'WebForm' }
		.api_endpoint { 'ApiEndpoint' }
		.email { 'Email' }
		.irc { 'IRC' }
		.mastodon { 'Mastodon' }
		.gitea { 'Gitea' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct RegisterResponse {
	slot    int
	channel string
	state   string
}

struct SentimentResponse {
	slot           int
	total          int
	positive       int
	negative       int
	neutral        int
	satisfaction   string // "good", "mixed", "poor"
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn register_channel(channel_name string) !RegisterResponse {
	c := match channel_name {
		'web_form' { int(FeedbackChannel.web_form) }
		'api' { int(FeedbackChannel.api_endpoint) }
		'email' { int(FeedbackChannel.email) }
		'irc' { int(FeedbackChannel.irc) }
		'mastodon' { int(FeedbackChannel.mastodon) }
		'gitea' { int(FeedbackChannel.gitea) }
		else { return error('unknown channel: ${channel_name}') }
	}
	slot := C.fb_register(c)
	if slot < 0 {
		return error('no channel slots available')
	}
	return RegisterResponse{
		slot: slot
		channel: channel_name
		state: 'channel_registered'
	}
}

pub fn submit_feedback(slot int, sentiment int) !string {
	result := C.fb_submit(slot, sentiment)
	if result == -1 { return error('slot ${slot} not active') }
	if result == -2 { return error('channel not in collecting state') }
	return 'feedback submitted (total: ${result})'
}

pub fn get_sentiment(slot int) SentimentResponse {
	total := C.fb_count(slot)
	pos := C.fb_positive_count(slot)
	neg := C.fb_negative_count(slot)
	neu := C.fb_neutral_count(slot)
	sat := if total == 0 { 'no data' }
		else if pos > neg * 2 { 'good' }
		else if neg > pos { 'poor' }
		else { 'mixed' }
	return SentimentResponse{
		slot: slot
		total: total
		positive: pos
		negative: neg
		neutral: neu
		satisfaction: sat
	}
}

pub fn deregister(slot int) !string {
	result := C.fb_deregister(slot)
	return match result {
		0 { 'deregistered channel on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot deregister: channel must be in collecting state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.fb_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.fb_reset()
}
