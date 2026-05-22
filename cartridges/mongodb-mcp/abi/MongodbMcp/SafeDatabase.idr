-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- MongodbMcp.SafeDatabase -- Type-safe ABI for mongodb-mcp cartridge.
--
-- Dependently-typed state machine modelling MongoDB connection lifecycle.
-- Transitions are proven valid at compile time. Credentials obtained from
-- vault-mcp via connection string (mongodb://user:pass@host:27017/db).
-- BSON document handling via the FFI layer.

module MongodbMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| MongoDB connection lifecycle states.
|||
||| @ Disconnected  No active connection to the MongoDB server.
||| @ Connected     Authenticated connection established; ready for operations.
||| @ InSession     Inside an explicit client session (for transactions).
||| @ Error         An error has occurred; must disconnect to recover.
public export
data ConnState
  = Disconnected
  | Connected
  | InSession
  | Error

||| Proof that a state transition is valid within the MongoDB protocol.
|||
||| The transition graph:
|||   Disconnected -> Connected    (connect with auth)
|||   Connected    -> InSession    (start session / begin transaction)
|||   InSession    -> Connected    (commit / abort / end session)
|||   Connected    -> Error        (connection or auth error)
|||   InSession    -> Error        (session or transaction error)
|||   Error        -> Disconnected (disconnect after error)
|||   Connected    -> Disconnected (graceful disconnect)
public export
data ValidTransition : ConnState -> ConnState -> Type where
  Connect       : ValidTransition Disconnected Connected
  Disconnect    : ValidTransition Connected Disconnected
  StartSession  : ValidTransition Connected InSession
  EndSession    : ValidTransition InSession Connected
  ConnError     : ValidTransition Connected Error
  SessionError  : ValidTransition InSession Error
  ErrorReset    : ValidTransition Error Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected = 0
connStateToInt Connected    = 1
connStateToInt InSession    = 2
connStateToInt Error        = 3

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Connected
intToConnState 2 = Just InSession
intToConnState 3 = Just Error
intToConnState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
mongodb_mcp_can_transition : Int -> Int -> Int
mongodb_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just Connected,    Just InSession)    => 1
    (Just InSession,    Just Connected)    => 1
    (Just Connected,    Just Error)        => 1
    (Just InSession,    Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- MongoDB actions
-- ---------------------------------------------------------------------------

||| Actions exposed via the mongodb-mcp MCP protocol.
|||
||| All 16 operations supported by this cartridge, covering CRUD,
||| aggregation, index management, and collection/database introspection.
public export
data MongodbAction
  = Find
  | FindOne
  | InsertOne
  | InsertMany
  | UpdateOne
  | UpdateMany
  | DeleteOne
  | DeleteMany
  | Aggregate
  | CountDocuments
  | CreateIndex
  | DropIndex
  | ListCollections
  | CreateCollection
  | DropCollection
  | ListDatabases

||| Encode action as C-compatible integer.
export
actionToInt : MongodbAction -> Int
actionToInt Find             = 0
actionToInt FindOne          = 1
actionToInt InsertOne        = 2
actionToInt InsertMany       = 3
actionToInt UpdateOne        = 4
actionToInt UpdateMany       = 5
actionToInt DeleteOne        = 6
actionToInt DeleteMany       = 7
actionToInt Aggregate        = 8
actionToInt CountDocuments   = 9
actionToInt CreateIndex      = 10
actionToInt DropIndex        = 11
actionToInt ListCollections  = 12
actionToInt CreateCollection = 13
actionToInt DropCollection   = 14
actionToInt ListDatabases    = 15

||| Decode integer back to action.
export
intToAction : Int -> Maybe MongodbAction
intToAction 0  = Just Find
intToAction 1  = Just FindOne
intToAction 2  = Just InsertOne
intToAction 3  = Just InsertMany
intToAction 4  = Just UpdateOne
intToAction 5  = Just UpdateMany
intToAction 6  = Just DeleteOne
intToAction 7  = Just DeleteMany
intToAction 8  = Just Aggregate
intToAction 9  = Just CountDocuments
intToAction 10 = Just CreateIndex
intToAction 11 = Just DropIndex
intToAction 12 = Just ListCollections
intToAction 13 = Just CreateCollection
intToAction 14 = Just DropCollection
intToAction 15 = Just ListDatabases
intToAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : MongodbAction -> Bool
actionRequiresConnection ListDatabases = False
actionRequiresConnection _             = True

||| Check whether an action requires an active session (transaction context).
export
actionRequiresSession : MongodbAction -> Bool
actionRequiresSession _ = False

||| Total number of actions in this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Authentication
-- ---------------------------------------------------------------------------

||| Authentication method for MongoDB connections.
||| Credentials are sourced from vault-mcp, never hardcoded.
public export
data AuthMethod
  = ConnectionString
  | VaultRef String

-- ---------------------------------------------------------------------------
-- BSON types
-- ---------------------------------------------------------------------------

||| BSON document field types used in wire protocol encoding.
public export
data BsonFieldType
  = BsonDouble
  | BsonString
  | BsonDocument
  | BsonArray
  | BsonBinary
  | BsonObjectId
  | BsonBool
  | BsonDateTime
  | BsonNull
  | BsonInt32
  | BsonInt64

||| Encode BSON field type as C-compatible integer.
export
bsonFieldTypeToInt : BsonFieldType -> Int
bsonFieldTypeToInt BsonDouble   = 1
bsonFieldTypeToInt BsonString   = 2
bsonFieldTypeToInt BsonDocument = 3
bsonFieldTypeToInt BsonArray    = 4
bsonFieldTypeToInt BsonBinary   = 5
bsonFieldTypeToInt BsonObjectId = 7
bsonFieldTypeToInt BsonBool     = 8
bsonFieldTypeToInt BsonDateTime = 9
bsonFieldTypeToInt BsonNull     = 10
bsonFieldTypeToInt BsonInt32    = 16
bsonFieldTypeToInt BsonInt64    = 18

||| Decode integer back to BSON field type.
export
intToBsonFieldType : Int -> Maybe BsonFieldType
intToBsonFieldType 1  = Just BsonDouble
intToBsonFieldType 2  = Just BsonString
intToBsonFieldType 3  = Just BsonDocument
intToBsonFieldType 4  = Just BsonArray
intToBsonFieldType 5  = Just BsonBinary
intToBsonFieldType 7  = Just BsonObjectId
intToBsonFieldType 8  = Just BsonBool
intToBsonFieldType 9  = Just BsonDateTime
intToBsonFieldType 10 = Just BsonNull
intToBsonFieldType 16 = Just BsonInt32
intToBsonFieldType 18 = Just BsonInt64
intToBsonFieldType _  = Nothing
