<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Cartridge Template

This template provides a starting point for creating new cartridges for the BoJ server.

## Structure

```
cartridge-template/
├── README.md          # This file
├── cartridge.json      # Cartridge metadata
├── abi/
│   └── README.adoc     # ABI layer documentation
├── ffi/
│   ├── README.adoc     # FFI layer documentation
│   ├── build.zig       # Build configuration
│   └── cartridge_ffi.zig # FFI implementation
└── adapter/
    └── README.adoc     # Adapter layer documentation
```

## Getting Started

1. **Copy the Template**:
   ```bash
   cp -r templates/cartridge-template cartridges/my-new-cartridge
   ```

2. **Update Metadata**:
   - Edit `cartridge.json` to reflect your cartridge's metadata.
   - Update the `name`, `version`, `description`, and other fields.

3. **Implement the ABI Layer**:
   - Define the abstract interfaces and types in the `abi/` directory.
   - Use Idris2 for type safety and correctness.

4. **Implement the FFI Layer**:
   - Implement the foreign function interface in the `ffi/` directory.
   - Use Zig for high-performance bindings.

5. **Implement the Adapter Layer**:
   - Implement the actual functionality in the `adapter/` directory.
   - Use Zig for the adapter layer.

6. **Add Tests**:
   - Add tests to the `ffi/` directory to ensure your cartridge works as expected.
   - Use Zig's testing framework.

7. **Update Documentation**:
   - Update the `README.adoc` files in each directory to reflect your cartridge's purpose, boundaries, invariants, and execution surfaces.

## Cartridge Metadata

The `cartridge.json` file contains metadata about your cartridge. Here's an example:

```json
{
  "name": "my-new-cartridge",
  "version": "0.1.0",
  "description": "A brief description of your cartridge",
  "domain": "Domain",
  "tier": "Ayo",
  "protocols": ["MCP", "REST"],
  "auth": {
    "method": "none"
  },
  "ports": {
    "allowed": [],
    "denied": []
  },
  "tools": [
    {
      "name": "tool_name",
      "description": "A brief description of the tool",
      "inputSchema": {
        "type": "object",
        "properties": {},
        "required": []
      }
    }
  ]
}
```

## FFI Implementation

The `ffi/cartridge_ffi.zig` file contains the FFI implementation. Here's a basic template:

```zig
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Your Name <your.email@example.com>

const std = @import("std");
const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "my-new-cartridge";
const CARTRIDGE_VERSION_PTR: [*:0]const u8 = "0.1.0";

export fn boj_cartridge_init() callconv(.c) c_int {
    return 0;
}

export fn boj_cartridge_deinit() callconv(.c) void {}

export fn boj_cartridge_name() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_NAME_PTR;
}

export fn boj_cartridge_version() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_VERSION_PTR;
}

export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;

    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "tool_name"))
        "{\"result\":{}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
test "boj_cartridge_name returns my-new-cartridge" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("my-new-cartridge", n);
}

test "boj_cartridge_version returns semver" {
    const v = std.mem.span(boj_cartridge_version());
    try std.testing.expectEqualStrings("0.1.0", v);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke unknown tool returns -1" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke known tool writes JSON and returns 0" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("tool_name", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "result") != null);
}

test "invoke with too-small buffer returns -3 and sets required length" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("tool_name", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
```

## Build Configuration

The `ffi/build.zig` file contains the build configuration. Here's a basic template:

```zig
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi_mod = b.addModule("my_new_cartridge", .{
        .root_source_file = b.path("cartridge_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "my_new_cartridge",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = ffi_mod });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run FFI tests");
    test_step.dependOn(&run_tests.step);
}
```

## Documentation

Update the `README.adoc` files in each directory to reflect your cartridge's purpose, boundaries, invariants, and execution surfaces. Here's an example for the `ffi/` directory:

```adoc
= My New Cartridge FFI Layer

== Purpose

This layer provides the foreign function interface for the My New Cartridge cartridge. It bridges the Idris2 ABI layer with the Zig adapter layer.

== Boundaries

- **Input**: JSON arguments from the MCP bridge.
- **Output**: JSON responses to the MCP bridge.
- **Dependencies**: None.

== Invariants

- The FFI layer must be thread-safe.
- The FFI layer must handle errors gracefully.
- The FFI layer must validate input arguments.

== Execution Surfaces

- **Entry Points**: `boj_cartridge_init`, `boj_cartridge_deinit`, `boj_cartridge_name`, `boj_cartridge_version`, `boj_cartridge_invoke`.
- **Error Handling**: Returns appropriate error codes for invalid inputs or failed operations.
- **Testing**: Unit tests for each function.
```

## Testing

Run the tests using the following command:

```bash
cd ffi && zig build test
```

## Building

Build the shared library using the following command:

```bash
cd ffi && zig build
```

## License

This cartridge is licensed under the MPL-2.0 license. See the LICENSE file for more information.
