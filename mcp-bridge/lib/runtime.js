// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Runtime abstraction layer
//
// Provides a unified interface for Deno and Node.js environments.
// Supports the "Deno > Bun > NPM" hierarchy while maintaining
// compatibility with Node-only MCP clients like Glama.

const isDeno = typeof globalThis.Deno !== "undefined";

/** @type {{ get: (name: string) => string|undefined }} */
export const env = {
  get(name) {
    if (isDeno) return globalThis.Deno.env.get(name);
    // @ts-ignore: process is global in Node
    return typeof process !== "undefined" ? process.env[name] : undefined;
  }
};

const encoder = new TextEncoder();

export const stdout = {
  /** @param {Uint8Array|string} data */
  writeSync(data) {
    const buf = typeof data === "string" ? encoder.encode(data) : data;
    if (isDeno) {
      globalThis.Deno.stdout.writeSync(buf);
    } else if (typeof process !== "undefined") {
      process.stdout.write(buf);
    }
  }
};

export const stderr = {
  /** @param {Uint8Array|string} data */
  writeSync(data) {
    const buf = typeof data === "string" ? encoder.encode(data) : data;
    if (isDeno) {
      globalThis.Deno.stderr.writeSync(buf);
    } else if (typeof process !== "undefined") {
      process.stderr.write(buf);
    }
  }
};

export { isDeno };
