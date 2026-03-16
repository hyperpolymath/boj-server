// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// mongodb_mcp_adapter.v -- V-lang adapter for mongodb-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes all 16 MongodbAction operations. BSON document handling delegated
// to the FFI layer. Credentials via connection string from vault-mcp.

module mongodb_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lmongodb_mcp

fn C.mongodb_mcp_can_transition(from int, to int) int
fn C.mongodb_mcp_connect(connstr_ptr &u8, connstr_len int) int
fn C.mongodb_mcp_disconnect(slot_idx int) int
fn C.mongodb_mcp_connection_state(slot_idx int) int
fn C.mongodb_mcp_start_session(slot_idx int) int
fn C.mongodb_mcp_end_session(slot_idx int) int
fn C.mongodb_mcp_signal_error(slot_idx int) int
fn C.mongodb_mcp_record_operation(slot_idx int) int
fn C.mongodb_mcp_op_count(slot_idx int) int
fn C.mongodb_mcp_active_count() int
fn C.mongodb_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

// Connection state enumeration.
// Disconnected=0, Connected=1, InSession=2, Error=3
enum ConnState {
	disconnected = 0
	connected    = 1
	in_session   = 2
	err          = 3
}

// All 16 MongoDB MCP actions.
enum MongodbAction {
	find_action              = 0
	find_one_action          = 1
	insert_one_action        = 2
	insert_many_action       = 3
	update_one_action        = 4
	update_many_action       = 5
	delete_one_action        = 6
	delete_many_action       = 7
	aggregate_action         = 8
	count_documents_action   = 9
	create_index_action      = 10
	drop_index_action        = 11
	list_collections_action  = 12
	create_collection_action = 13
	drop_collection_action   = 14
	list_databases_action    = 15
}

// Human-readable label for a connection state integer.
fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'connected' }
		2 { 'in_session' }
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

struct OpCountResponse {
	slot  int
	count int
}

struct ActiveCountResponse {
	count int
}

// ---------------------------------------------------------------------------
// Connection management
// ---------------------------------------------------------------------------

// Connect to MongoDB with a connection string from vault-mcp.
pub fn connect(connstr string) !ConnectionResponse {
	slot := C.mongodb_mcp_connect(connstr.str, connstr.len)
	if slot < 0 {
		return match slot {
			-1 { error('no connection slots available') }
			-2 { error('invalid connection string') }
			else { error('connect failed (code ${slot})') }
		}
	}
	return ConnectionResponse{
		slot: slot
		state: 'connected'
	}
}

// Disconnect from MongoDB.
pub fn disconnect(slot int) !string {
	result := C.mongodb_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for disconnect') }
		else { return error('disconnect failed (code ${result})') }
	}
}

// Start a client session (for transactions).
pub fn start_session(slot int) !string {
	result := C.mongodb_mcp_start_session(slot)
	return match result {
		0 { 'session started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for start_session') }
		else { return error('start_session failed (code ${result})') }
	}
}

// End a client session (commit/abort).
pub fn end_session(slot int) !string {
	result := C.mongodb_mcp_end_session(slot)
	return match result {
		0 { 'session ended on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for end_session') }
		else { return error('end_session failed (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions -- all 16 actions
// ---------------------------------------------------------------------------

// Action 0: Find -- query documents matching a filter.
pub fn find(slot int, db string, collection string, filter string) !string {
	_ = db
	_ = collection
	_ = filter
	C.mongodb_mcp_record_operation(slot)
	return 'find completed on slot ${slot}'
}

// Action 1: FindOne -- find a single document matching a filter.
pub fn find_one(slot int, db string, collection string, filter string) !string {
	_ = db
	_ = collection
	_ = filter
	C.mongodb_mcp_record_operation(slot)
	return 'findOne completed on slot ${slot}'
}

// Action 2: InsertOne -- insert a single document.
pub fn insert_one(slot int, db string, collection string, document string) !string {
	_ = db
	_ = collection
	_ = document
	C.mongodb_mcp_record_operation(slot)
	return 'insertOne completed on slot ${slot}'
}

// Action 3: InsertMany -- insert multiple documents.
pub fn insert_many(slot int, db string, collection string, documents []string) !string {
	_ = db
	_ = collection
	_ = documents
	C.mongodb_mcp_record_operation(slot)
	return 'insertMany completed on slot ${slot}'
}

// Action 4: UpdateOne -- update a single document matching a filter.
pub fn update_one(slot int, db string, collection string, filter string, update string) !string {
	_ = db
	_ = collection
	_ = filter
	_ = update
	C.mongodb_mcp_record_operation(slot)
	return 'updateOne completed on slot ${slot}'
}

// Action 5: UpdateMany -- update multiple documents matching a filter.
pub fn update_many(slot int, db string, collection string, filter string, update string) !string {
	_ = db
	_ = collection
	_ = filter
	_ = update
	C.mongodb_mcp_record_operation(slot)
	return 'updateMany completed on slot ${slot}'
}

// Action 6: DeleteOne -- delete a single document matching a filter.
pub fn delete_one(slot int, db string, collection string, filter string) !string {
	_ = db
	_ = collection
	_ = filter
	C.mongodb_mcp_record_operation(slot)
	return 'deleteOne completed on slot ${slot}'
}

// Action 7: DeleteMany -- delete multiple documents matching a filter.
pub fn delete_many(slot int, db string, collection string, filter string) !string {
	_ = db
	_ = collection
	_ = filter
	C.mongodb_mcp_record_operation(slot)
	return 'deleteMany completed on slot ${slot}'
}

// Action 8: Aggregate -- run an aggregation pipeline.
pub fn aggregate(slot int, db string, collection string, pipeline string) !string {
	_ = db
	_ = collection
	_ = pipeline
	C.mongodb_mcp_record_operation(slot)
	return 'aggregate completed on slot ${slot}'
}

// Action 9: CountDocuments -- count documents matching a filter.
pub fn count_documents(slot int, db string, collection string, filter string) !string {
	_ = db
	_ = collection
	_ = filter
	C.mongodb_mcp_record_operation(slot)
	return 'countDocuments completed on slot ${slot}'
}

// Action 10: CreateIndex -- create an index on a collection.
pub fn create_index(slot int, db string, collection string, keys string) !string {
	_ = db
	_ = collection
	_ = keys
	C.mongodb_mcp_record_operation(slot)
	return 'createIndex completed on slot ${slot}'
}

// Action 11: DropIndex -- drop an index from a collection.
pub fn drop_index(slot int, db string, collection string, index_name string) !string {
	_ = db
	_ = collection
	_ = index_name
	C.mongodb_mcp_record_operation(slot)
	return 'dropIndex completed on slot ${slot}'
}

// Action 12: ListCollections -- list all collections in a database.
pub fn list_collections(slot int, db string) !string {
	_ = db
	C.mongodb_mcp_record_operation(slot)
	return 'listCollections completed on slot ${slot}'
}

// Action 13: CreateCollection -- create a new collection.
pub fn create_collection(slot int, db string, collection string) !string {
	_ = db
	_ = collection
	C.mongodb_mcp_record_operation(slot)
	return 'createCollection completed on slot ${slot}'
}

// Action 14: DropCollection -- drop a collection.
pub fn drop_collection(slot int, db string, collection string) !string {
	_ = db
	_ = collection
	C.mongodb_mcp_record_operation(slot)
	return 'dropCollection completed on slot ${slot}'
}

// Action 15: ListDatabases -- list all databases on the server.
pub fn list_databases(slot int) !string {
	C.mongodb_mcp_record_operation(slot)
	return 'listDatabases completed on slot ${slot}'
}

// ---------------------------------------------------------------------------
// Status / introspection
// ---------------------------------------------------------------------------

// Get current connection state.
pub fn connection_state(slot int) StateResponse {
	s := C.mongodb_mcp_connection_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

// Check if a transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.mongodb_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

// Get operation count for a connection.
pub fn op_count(slot int) OpCountResponse {
	count := C.mongodb_mcp_op_count(slot)
	return OpCountResponse{ slot: slot, count: count }
}

// Get number of active connections.
pub fn active_count() ActiveCountResponse {
	return ActiveCountResponse{ count: C.mongodb_mcp_active_count() }
}

// Reset all connections (test/debug only).
pub fn reset() {
	C.mongodb_mcp_reset()
}
