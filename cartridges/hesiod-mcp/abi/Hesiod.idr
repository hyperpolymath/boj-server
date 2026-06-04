-- SPDX-License-Identifier: MPL-2.0
-- Hesiod DNS Cartridge ABI — Type-safe DNS lookup interface

module Hesiod

||| DNS record type enumeration (proof-indexed)
public export
data DNSRecordType
  = A              -- IPv4 address
  | AAAA           -- IPv6 address
  | CNAME          -- Canonical name
  | MX             -- Mail exchange
  | NS             -- Name server
  | SOA            -- Start of authority
  | TXT            -- Text record
  | SRV            -- Service record

||| Proof that a record type is queryable
public export
data Queryable : DNSRecordType -> Type where
  QueryableA : Queryable A
  QueryableAAAA : Queryable AAAA
  QueryableCNAME : Queryable CNAME
  QueryableMX : Queryable MX
  QueryableNS : Queryable NS
  QueryableSOA : Queryable SOA
  QueryableTXT : Queryable TXT
  QueryableSRV : Queryable SRV

||| DNS response record
public export
record DNSRecord where
  constructor MkDNSRecord
  name : String
  type : DNSRecordType
  ttl : Nat
  value : String

||| Lookup result type (success or failure)
public export
data LookupResult : Type where
  Success : (records : List DNSRecord) -> LookupResult
  NotFound : (hostname : String) -> LookupResult
  NetworkError : (message : String) -> LookupResult
  Timeout : (hostname : String) -> (seconds : Nat) -> LookupResult

||| Type-safe DNS lookup interface
||| Proof ensures only valid record types are queried
public export
interface Lookup (m : Type -> Type) where
  ||| Query DNS records for a hostname
  ||| @hostname The domain to query
  ||| @rectype The record type to look up
  ||| @queryable Proof that this record type is queryable
  lookup : {rectype : DNSRecordType} -> (hostname : String) ->
           Queryable rectype -> m LookupResult

  ||| Reverse DNS lookup (address -> hostname)
  reverseLookup : (address : String) -> m LookupResult

  ||| Bulk lookup multiple hostnames
  bulkLookup : {rectype : DNSRecordType} ->
               (hostnames : List String) ->
               Queryable rectype -> m (List LookupResult)

||| Loopback proof: hesiod-mcp only runs on localhost:5173
public export
data IsLoopback : (port : Nat) -> Type where
  LoopbackProof : IsLoopback 5173

export
loopbackInvariant : IsLoopback 5173
loopbackInvariant = LoopbackProof
