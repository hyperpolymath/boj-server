# Typed-WASM MCP Bridge Design

**Status**: Proposed (not yet implemented)
**Goal**: Replace the JavaScript (Deno) MCP bridge with a Typed-WASM implementation.

## Motivation
1. **Eliminate JavaScript**: Remove Node.js/Deno dependency from the server.
2. **Performance**: WASM can offer better performance and lower memory footprint.
3. **Security**: Typed-WASM provides stronger type safety and memory safety guarantees.
4. **Portability**: WASM runs in any WASI-compatible runtime (e.g., Wasmtime, Wasmer).

## Design

### 1. Architecture
```
┌───────────────────────────────────────────────────────────────┐
│                        BoJ Server                             │
├─────────────────┬─────────────────┬─────────────────┬─────────────┤
│   Cartridges    │  Zig FFI Layer  │  WASM Bridge   │  Clients   │
│  (Idris2 + Zig) │  (Zig)          │  (Typed-WASM)  │  (MCP)      │
└─────────────────┴─────────────────┴─────────────────┴─────────────┘
                                      ▲
                                      │
                                      │
┌───────────────────────────────────────────────────────────────┐
│                        WASI Runtime                            │
│  (e.g., Wasmtime, Wasmer, Node.js, Deno, Browser)             │
└───────────────────────────────────────────────────────────────┘
```

### 2. Components

#### 2.1 WASM Module
- **Language**: Zig (compiled to WASM) or Rust.
- **Input**: MCP JSON-RPC messages (stdio or WebSocket).
- **Output**: MCP JSON-RPC responses.
- **Dependencies**: None (self-contained WASM).

#### 2.2 WASI Interface
- **stdio**: For MCP stdio transport.
- **sockets**: For WebSocket transport (if needed).
- **clock**: For timeouts and retries.
- **random**: For session IDs and nonces.

#### 2.3 Typed-WASM Features
- **Linear memory**: For efficient JSON parsing.
- **Type imports/exports**: For strict type checking.
- **Memory safety**: No undefined behavior.

### 3. Implementation Steps

#### Step 1: Zig WASM Module
```zig
// mcp_bridge_wasm.zig
const std = @import("std");

pub export fn mjr_mcp_bridge_init() void {
    // Initialize the MCP bridge
}

pub export fn mjr_mcp_bridge_handle_input(input: []const u8) []const u8 {
    // Parse MCP JSON-RPC input
    // Route to cartridge
    // Return MCP JSON-RPC response
}

pub export fn mjr_mcp_bridge_deinit() void {
    // Cleanup
}
```

#### Step 2: Build Script
```bash
# build_wasm.sh
zig build-lib -target wasm32-wasi -O ReleaseSmall mcp_bridge_wasm.zig -o mjr_mcp_bridge.wasm
```

#### Step 3: WASI Runtime Integration
```javascript
// Example: Node.js WASI integration
import { WASI } from 'wasi';
const wasi = new WASI();
const wasm = await WebAssembly.instantiate(fs.readFileSync('mjr_mcp_bridge.wasm'), { wasi_snapshot_preview1: wasi.wasiImport });
wasi.start(wasm.instance);
```

### 4. Testing

#### 4.1 Unit Tests
- Test JSON-RPC parsing.
- Test cartridge routing.
- Test error handling.

#### 4.2 Integration Tests
- Test with real cartridges (database-mcp, fleet-mcp).
- Test stdio transport.
- Test WebSocket transport (if implemented).

#### 4.3 Benchmarks
- Compare performance with JavaScript bridge.
- Measure memory usage.
- Test under load (1000+ requests/sec).

### 5. Migration Plan

#### Phase 1: Parallel Deployment
- Deploy WASM bridge alongside JavaScript bridge.
- Route a subset of traffic to WASM bridge.
- Monitor for errors and performance.

#### Phase 2: Full Cutover
- Replace JavaScript bridge with WASM bridge.
- Update documentation.
- Remove JavaScript bridge code.

#### Phase 3: Optimization
- Profile WASM bridge.
- Optimize hot paths.
- Reduce WASM module size.

### 6. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| WASM performance not better than JavaScript | Profile and optimize. Fall back to JavaScript if needed. |
| WASI not widely supported | Use polyfills (e.g., WASI shims for Node.js). |
| Debugging WASM is harder | Use source maps and WASM-specific tools (e.g., wasm-gdb). |
| Memory management | Use Zig's allocator or Rust's ownership model. |

### 7. Open Questions
1. Should the WASM bridge support WebSocket transport, or only stdio?
2. Should the WASM bridge be compiled from Zig or Rust?
3. Should the WASM bridge be bundled with the server, or loaded dynamically?

### 8. References
- [WASI Specification](https://wasi.dev/)
- [Zig WASM Support](https://ziglang.org/documentation/master/#WASM)
- [Typed-WASM](https://github.com/WebAssembly/typed-wasm)
- [MCP Specification](https://mcp.boj.dev/)
