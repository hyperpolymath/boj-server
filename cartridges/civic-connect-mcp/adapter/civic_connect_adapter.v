// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// CivicConnect V-lang adapter — bridges Zig FFI to REST endpoints.

module civic_connect_adapter

fn C.civic_connect_list_channels_count() u32
fn C.civic_connect_send_message(channel_id u32, body &u8) int
fn C.civic_connect_get_poll(poll_id u32) u32

struct Response {
	ok   bool
	data string
}

pub fn handle_list_channels() Response {
	count := C.civic_connect_list_channels_count()
	return Response{ ok: true, data: '${count} channels' }
}

pub fn handle_send_message(channel_id u32, body string) Response {
	rc := C.civic_connect_send_message(channel_id, body.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'sent' } else { 'send failed' } }
}

pub fn handle_get_poll(poll_id u32) Response {
	votes := C.civic_connect_get_poll(poll_id)
	if poll_id == 0 {
		return Response{ ok: false, data: 'poll not found' }
	}
	return Response{ ok: true, data: '${votes} votes' }
}
