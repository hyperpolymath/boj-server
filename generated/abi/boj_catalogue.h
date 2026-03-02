/* SPDX-License-Identifier: PMPL-1.0-or-later */
/* Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> */
/*
 * BoJ Catalogue C ABI Header
 *
 * Generated from src/abi/Catalogue.idr type definitions.
 * This header bridges the Idris2 ABI proofs with the Zig FFI layer.
 *
 * Integer encodings match the Idris2 *ToInt functions exactly.
 */

#ifndef BOJ_CATALOGUE_H
#define BOJ_CATALOGUE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ═══════════════════════════════════════════════════════════════════════ */
/* Type Encodings (from Idris2 ABI)                                      */
/* ═══════════════════════════════════════════════════════════════════════ */

/* CartridgeStatus (Catalogue.idr: statusToInt) */
#define BOJ_STATUS_DEVELOPMENT  0
#define BOJ_STATUS_READY        1
#define BOJ_STATUS_DEPRECATED   2
#define BOJ_STATUS_FAULTY       3

/* ProtocolType (Protocol.idr: protocolToInt) */
#define BOJ_PROTO_MCP      1
#define BOJ_PROTO_LSP      2
#define BOJ_PROTO_DAP      3
#define BOJ_PROTO_BSP      4
#define BOJ_PROTO_NESY     5
#define BOJ_PROTO_AGENTIC  6
#define BOJ_PROTO_FLEET    7
#define BOJ_PROTO_GRPC     8
#define BOJ_PROTO_REST     9

/* CapabilityDomain (Domain.idr: domainToInt) */
#define BOJ_DOMAIN_CLOUD      1
#define BOJ_DOMAIN_CONTAINER  2
#define BOJ_DOMAIN_DATABASE   3
#define BOJ_DOMAIN_K8S        4
#define BOJ_DOMAIN_GIT        5
#define BOJ_DOMAIN_SECRETS    6
#define BOJ_DOMAIN_QUEUES     7
#define BOJ_DOMAIN_IAC        8
#define BOJ_DOMAIN_OBSERVE    9
#define BOJ_DOMAIN_SSG       10
#define BOJ_DOMAIN_PROOF     11
#define BOJ_DOMAIN_FLEET     12
#define BOJ_DOMAIN_NESY      13

/* MenuTier */
#define BOJ_TIER_TERANGA  0
#define BOJ_TIER_SHIELD   1
#define BOJ_TIER_AYO      2

/* Region (Federation.idr: regionToInt) */
#define BOJ_REGION_OTHER          0
#define BOJ_REGION_EUROPE_WEST    1
#define BOJ_REGION_EUROPE_CENTRAL 2
#define BOJ_REGION_OCEANIA        3
#define BOJ_REGION_AMERICAS       4
#define BOJ_REGION_ASIA_EAST      5
#define BOJ_REGION_ASIA_SOUTH     6
#define BOJ_REGION_AFRICA         7

/* ═══════════════════════════════════════════════════════════════════════ */
/* Lifecycle                                                              */
/* ═══════════════════════════════════════════════════════════════════════ */

/* Initialise the catalogue. Returns 0 on success. */
int boj_catalogue_init(void);

/* Shut down the catalogue. Unmounts all cartridges. */
void boj_catalogue_deinit(void);

/* ═══════════════════════════════════════════════════════════════════════ */
/* Registration                                                           */
/* ═══════════════════════════════════════════════════════════════════════ */

/* Register a cartridge. Returns 0 on success, -1 on failure. */
int boj_catalogue_register(
    const char *name, size_t name_len,
    const char *version, size_t version_len,
    int status,   /* BOJ_STATUS_* */
    int tier,     /* BOJ_TIER_*   */
    int domain    /* BOJ_DOMAIN_* */
);

/* Add a protocol to the last registered cartridge. */
int boj_catalogue_add_protocol(int protocol /* BOJ_PROTO_* */);

/* ═══════════════════════════════════════════════════════════════════════ */
/* Mount / Unmount                                                        */
/* ═══════════════════════════════════════════════════════════════════════ */

/* Mount a cartridge. Only succeeds if status == BOJ_STATUS_READY. */
/* Returns 0 on success, -1 if not ready, -2 if not found. */
int boj_catalogue_mount(size_t index);

/* Unmount a cartridge. */
int boj_catalogue_unmount(size_t index);

/* Check if a cartridge is mounted. Returns 1/0/-1. */
int boj_catalogue_is_mounted(size_t index);

/* ═══════════════════════════════════════════════════════════════════════ */
/* Queries                                                                */
/* ═══════════════════════════════════════════════════════════════════════ */

/* Total registered cartridges. */
size_t boj_catalogue_count(void);

/* Count of ready cartridges. */
size_t boj_catalogue_count_ready(void);

/* Count of mounted cartridges. */
size_t boj_catalogue_count_mounted(void);

/* Get status of a cartridge by index. Returns BOJ_STATUS_* or -1. */
int boj_catalogue_status(size_t index);

/* Get the library version string. */
const char *boj_catalogue_version(void);

#ifdef __cplusplus
}
#endif

#endif /* BOJ_CATALOGUE_H */
