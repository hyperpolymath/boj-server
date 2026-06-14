// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Runtime abstraction layer
//
// Provides a unified interface for Deno and Node.js environments.
// Supports the "Deno > Bun > NPM" hierarchy while maintaining
// compatibility with Node-only MCP clients like Glama.

import { writeSync as writeFdSync } from "node:fs";

const isDeno = typeof globalThis.Deno !== "undefined";

/** @type {{ get: (name: string) => string|undefined }} */
export const env = {
  get(name) {
    if (isDeno) return globalThis.Deno.env.get(name);
    // @ts-ignore: process is global in Node
    return typeof process !== "undefined" ? process.env[name] : undefined;
  }
};

/** Current process id, portable across Deno and Node. */
export const pid = isDeno
  ? globalThis.Deno.pid
  : (typeof process !== "undefined" ? process.pid : 0);

const encoder = new TextEncoder();

export const stdout = {
  /** @param {Uint8Array|string} data */
  writeSync(data) {
    const buf = typeof data === "string" ? encoder.encode(data) : data;
    if (isDeno) {
      globalThis.Deno.stdout.writeSync(buf);
    } else if (typeof process !== "undefined") {
      writeFdSync(process.stdout.fd, buf);
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
      writeFdSync(process.stderr.fd, buf);
    }
  }
};

export { isDeno };
