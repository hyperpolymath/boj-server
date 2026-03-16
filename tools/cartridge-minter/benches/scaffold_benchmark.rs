// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Benchmarks for cartridge-minter scaffolding operations.

use criterion::{Criterion, criterion_group, criterion_main};
use std::fs;
use tempfile::TempDir;

fn setup_fake_boj() -> (TempDir, std::path::PathBuf) {
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().to_path_buf();
    fs::create_dir_all(root.join("cartridges")).unwrap();
    fs::create_dir_all(root.join(".machine_readable/servers")).unwrap();
    fs::write(root.join("0-AI-MANIFEST.a2ml"), "# test").unwrap();
    fs::write(
        root.join(".machine_readable/servers/menu.a2ml"),
        "# menu\n",
    )
    .unwrap();
    (tmp, root)
}

fn bench_mint(c: &mut Criterion) {
    c.bench_function("mint_cartridge", |b| {
        b.iter_with_setup(
            || {
                let (tmp, root) = setup_fake_boj();
                (tmp, root)
            },
            |(_tmp, root)| {
                // Inline the scaffolding logic without importing private modules
                let cart_dir = root.join("cartridges/bench-mcp");
                fs::create_dir_all(cart_dir.join("abi/BenchMcp")).unwrap();
                fs::create_dir_all(cart_dir.join("ffi")).unwrap();
                fs::create_dir_all(cart_dir.join("adapter")).unwrap();
                fs::write(cart_dir.join("abi/BenchMcp/SafeCloud.idr"), "-- stub").unwrap();
                fs::write(cart_dir.join("ffi/bench_mcp_ffi.zig"), "// stub").unwrap();
                fs::write(cart_dir.join("ffi/build.zig"), "// stub").unwrap();
                fs::write(cart_dir.join("adapter/bench_mcp_adapter.v"), "// stub").unwrap();
                fs::write(cart_dir.join("README.adoc"), "= bench-mcp").unwrap();
            },
        );
    });
}

fn bench_validate(c: &mut Criterion) {
    c.bench_function("validate_cartridge", |b| {
        // Setup once
        let (_tmp, root) = setup_fake_boj();
        let cart_dir = root.join("cartridges/bench-mcp");
        fs::create_dir_all(cart_dir.join("abi/BenchMcp")).unwrap();
        fs::create_dir_all(cart_dir.join("ffi")).unwrap();
        fs::create_dir_all(cart_dir.join("adapter")).unwrap();
        fs::write(
            cart_dir.join("abi/BenchMcp/SafeCloud.idr"),
            "-- SPDX-License-Identifier: PMPL-1.0-or-later\n%default total\n",
        )
        .unwrap();
        fs::write(
            cart_dir.join("ffi/bench_mcp_ffi.zig"),
            "// SPDX-License-Identifier: PMPL-1.0-or-later\n",
        )
        .unwrap();
        fs::write(cart_dir.join("ffi/build.zig"), "// stub").unwrap();
        fs::write(
            cart_dir.join("abi/bench_mcp.ipkg"),
            "-- SPDX-License-Identifier: PMPL-1.0-or-later\npackage bench_mcp\n",
        )
        .unwrap();
        fs::write(
            cart_dir.join("adapter/bench_mcp_adapter.v"),
            "// SPDX-License-Identifier: PMPL-1.0-or-later\n",
        )
        .unwrap();
        fs::write(cart_dir.join("README.adoc"), "= bench-mcp").unwrap();

        b.iter(|| {
            // Walk the directory structure checking files
            let abi_dir = cart_dir.join("abi");
            let _ = fs::read_dir(&abi_dir);
            let _ = fs::read_to_string(cart_dir.join("abi/BenchMcp/SafeCloud.idr"));
        });
    });
}

criterion_group!(benches, bench_mint, bench_validate);
criterion_main!(benches);
