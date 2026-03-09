<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# BoJ Server — Stable API Contract v0.2

This document defines the stable API surface for the Bundle of Joy Server.
Endpoints listed here are subject to semantic versioning guarantees:
breaking changes require a major version bump.

## Versioning

- **Current**: v0.2 (Beta)
- **Stability**: Endpoints marked `stable` will not break within a major version
- **Experimental**: Endpoints marked `experimental` may change without notice

## Transport

| Protocol | Default Port | Content-Type |
|----------|-------------|--------------|
| REST | 7700 | `application/json` |
| gRPC-compat | 7701 | `application/json` (JSON-over-HTTP) |
| GraphQL | 7702 | `application/json` |
| Federation (UDP/QUIC) | 9999 | Binary wire format |

All ports are configurable via environment variables:
`BOJ_REST_PORT`, `BOJ_GRPC_PORT`, `BOJ_GRAPHQL_PORT`, `BOJ_FEDERATION_PORT`

## REST Endpoints

### System

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/health` | **stable** | Health check. Returns `{"status":"ok"}` |
| GET | `/status` | **stable** | Server status with uptime, node ID, cartridge counts |
| GET | `/version` | **stable** | Catalogue version string |

### Teranga Menu

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/menu` | **stable** | Full Teranga menu (3 tiers: Teranga, Shield, Ayo) |
| GET | `/menu/teranga` | **stable** | Tier 1: Core infrastructure cartridges |
| GET | `/menu/shield` | **stable** | Tier 2: Security and governance cartridges |
| GET | `/menu/ayo` | **stable** | Tier 3: Community and experimental cartridges |

### Cartridges

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/cartridges` | **stable** | List all registered cartridges |
| GET | `/cartridge/{name}` | **stable** | Get cartridge detail by name |
| POST | `/cartridges/{name}/load` | **stable** | Mount a cartridge (verify + activate) |
| POST | `/cartridges/{name}/unload` | **stable** | Unmount a cartridge |
| POST | `/cartridges/{name}/invoke` | **stable** | Invoke a cartridge tool |

#### Invoke Request Format

```json
{
  "tool": "tool_name",
  "params": { "key": "value" }
}
```

#### Invoke Response Format

```json
{
  "cartridge": "database-mcp",
  "tool": "list_octads",
  "result": "...",
  "latency_ms": 12
}
```

### Order Ticket (SCM Protocol)

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| POST | `/order` | **stable** | Place an order via the Order Ticket Protocol |
| GET | `/order/schema` | **stable** | Get the order ticket JSON schema |

### Matrix View

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/matrix` | **stable** | Full 2D capability matrix (protocols x domains) |

### Umoja Federation

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/umoja/status` | **stable** | Federation node status |
| GET | `/umoja/peers` | **stable** | List connected peers |
| POST | `/umoja/peers` | **stable** | Add a peer node |
| GET | `/umoja/transport` | **stable** | Current transport mode (quic/udp) |

#### Add Peer Request

```json
{
  "host": "192.168.1.100",
  "port": "9999"
}
```

### Coprocessor Dispatch

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/coprocessor/status` | experimental | Device detection and dispatch stats |
| POST | `/coprocessor/select` | experimental | Select best device for a cartridge |

#### Select Request

```json
{
  "cartridge": "nesy-mcp"
}
```

#### Select Response

```json
{
  "cartridge": "nesy-mcp",
  "device": "cuda",
  "fallback": "false"
}
```

### SLA Monitoring

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/sla/status` | **stable** | System SLA metrics (requests, errors, tracked cartridges) |

#### SLA Status Response

```json
{
  "total_requests": 1234,
  "total_errors": 5,
  "cartridges_tracked": 18
}
```

### Community Cartridge Submissions (Ayo Tier)

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/community/submissions` | **stable** | Count of submissions by status |
| POST | `/community/submit` | **stable** | Submit a community cartridge |

#### Submit Request

```json
{
  "name": "my-cool-mcp",
  "author": "Alice <alice@example.com>",
  "description": "A cool cartridge for testing",
  "hash": "a1b2c3...64-char-hex-sha256"
}
```

#### Submission State Machine

```
submitted → under_review → approved → suspended
                         ↘ rejected     ↓
                                    under_review
```

### Auto-SDP (Software Defined Perimeter)

| Method | Path | Stability | Description |
|--------|------|-----------|-------------|
| GET | `/sdp/status` | experimental | SDP perimeter status (peers, bans) |

## gRPC-compat Endpoints

The gRPC-compat adapter exposes the same functionality as REST using
service/method path conventions over JSON-over-HTTP:

| Path | Maps To |
|------|---------|
| `/boj.Catalogue/List` | `GET /cartridges` |
| `/boj.Catalogue/Get` | `GET /cartridge/{name}` |
| `/boj.Catalogue/Mount` | `POST /cartridges/{name}/load` |
| `/boj.Catalogue/Unmount` | `POST /cartridges/{name}/unload` |
| `/boj.Catalogue/Invoke` | `POST /cartridges/{name}/invoke` |
| `/boj.Order/Place` | `POST /order` |
| `/boj.Menu/Full` | `GET /menu` |

## GraphQL Schema

```graphql
type Query {
  status: Status
  menu: Menu
  cartridge(name: String!): Cartridge
}

type Mutation {
  order(input: OrderInput!): OrderResult
}
```

## Wire Format — Federation (QUIC/UDP)

Packets use a tagged binary format on UDP port 9999:

### Cleartext Packets (high bit = 0)

| Tag | Name | Payload |
|-----|------|---------|
| 0x01 | Heartbeat | `[node_id: 32]` |
| 0x02 | HeartbeatAck | `[node_id: 32]` |
| 0x03 | GossipDigest | `[digest: 32]` |
| 0x04 | GossipDigestAck | `[digest: 32]` |
| 0x05 | StateSync | `[node_id: 32][state: 1]` |
| 0x06 | Discovery | `[node_id: 32]` |
| 0x07 | DiscoveryResponse | `[node_id: 32]` |
| 0x08 | QuicKeyExchange | `[public_key: 32]` |
| 0x09 | QuicKeyReply | `[public_key: 32]` |

### Encrypted Packets (high bit = 1)

```
[0x80 | tag : 1][nonce : 12][ciphertext : N][auth_tag : 16]
```

- Key exchange: X25519 ECDH
- Encryption: ChaCha20-Poly1305 AEAD
- Nonce: 12-byte, monotonically increasing per peer session

## Error Responses

All error responses follow the format:

```json
{
  "error": "description of the error"
}
```

HTTP status codes:
- `400` — Bad request (malformed input)
- `404` — Unknown endpoint or cartridge not found
- `409` — Conflict (e.g., cartridge already mounted)
- `503` — Service unavailable (e.g., cartridge not mounted, FFI error)

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BOJ_REST_PORT` | `7700` | REST adapter port |
| `BOJ_GRPC_PORT` | `7701` | gRPC-compat adapter port |
| `BOJ_GRAPHQL_PORT` | `7702` | GraphQL adapter port |
| `BOJ_FEDERATION_PORT` | `9999` | Umoja federation UDP/QUIC port |
| `BOJ_QUIC` | `1` | Enable QUIC transport (`1`=yes, `0`=UDP only) |
| `BOJ_NODE_ID` | `local-0` | Node identifier for federation |
| `BOJ_REGION` | `local` | Geographic region label |
| `STAPELN_URL` | `http://localhost:4000` | Stapeln API proxy URL |
| `VERISIMDB_URL` | `http://localhost:8180` | VeriSimDB backing store URL |
| `BOJ_CUDA_DEVICES` | — | Override CUDA device count |
| `BOJ_ROCM_DEVICES` | — | Override ROCm device count |
| `BOJ_TPU_DEVICES` | — | Override TPU device count |
| `BOJ_FPGA_DEVICES` | — | Override FPGA device count |
