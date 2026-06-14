// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Minimal OTLP/HTTP+JSON span emitter
//
// Zero runtime dependencies. Disabled unless OTEL_EXPORTER_OTLP_ENDPOINT
// is set. Spans are buffered and flushed via fire-and-forget POST to
// `${endpoint}/v1/traces` at a configurable batch interval (default 5s)
// and on `before-exit` / SIGTERM / SIGINT.
//
// Why hand-rolled (no @opentelemetry/api)?
// - Bridge has zero runtime deps by policy (see package.json + CLAUDE.md).
//   Adding ~30 transitive packages for what is structurally a couple of
//   JSON-RPC wrappers is not proportionate.
// - OTLP/HTTP JSON is a stable, externally-documented wire format. Any
//   conformant collector (Jaeger, Tempo, Honeycomb, Grafana Agent,
//   OTel Collector itself) accepts these payloads.
//
// Span shape conforms to OTLP/JSON v1.0:
//   https://opentelemetry.io/docs/specs/otlp/#otlphttp
//
// Pairs naturally with the observe-mcp / grafana-mcp / prometheus-mcp
// cartridges — same telemetry destination, unified pane.

import { env } from "./runtime.js";

const ENDPOINT = env.get("OTEL_EXPORTER_OTLP_ENDPOINT") ?? "";
const SERVICE_NAME = env.get("OTEL_SERVICE_NAME") ?? "boj-server";
const SERVICE_VERSION = env.get("OTEL_SERVICE_VERSION") ?? "0.4.7";
const BATCH_MS = parseInt(env.get("OTEL_BATCH_MS") ?? "5000", 10) || 5000;
const HEADERS_RAW = env.get("OTEL_EXPORTER_OTLP_HEADERS") ?? "";

const ENABLED = ENDPOINT.length > 0;

const customHeaders = {};
if (HEADERS_RAW) {
  for (const pair of HEADERS_RAW.split(",")) {
    const idx = pair.indexOf("=");
    if (idx > 0) {
      customHeaders[pair.slice(0, idx).trim()] = pair.slice(idx + 1).trim();
    }
  }
}

const traceUrl = ENABLED
  ? ENDPOINT.replace(/\/$/, "") + "/v1/traces"
  : null;

const pendingSpans = [];

function randHex(bytes) {
  let s = "";
  for (let i = 0; i < bytes; i++) {
    s += Math.floor(Math.random() * 256).toString(16).padStart(2, "0");
  }
  return s;
}

function nowNs() {
  // Number → BigInt-safe nanoseconds. Date.now() is ms; multiply by 1e6.
  // OTLP accepts string-encoded nanoseconds.
  return String(BigInt(Date.now()) * 1000000n);
}

function attributesToOtlp(attrs) {
  const out = [];
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null) continue;
    if (typeof v === "string") {
      out.push({ key: k, value: { stringValue: v } });
    } else if (typeof v === "number") {
      if (Number.isInteger(v)) {
        out.push({ key: k, value: { intValue: String(v) } });
      } else {
        out.push({ key: k, value: { doubleValue: v } });
      }
    } else if (typeof v === "boolean") {
      out.push({ key: k, value: { boolValue: v } });
    } else {
      out.push({ key: k, value: { stringValue: JSON.stringify(v) } });
    }
  }
  return out;
}

/**
 * Start a span. Returns an opaque handle to pass to endSpan.
 * If telemetry is disabled, returns a no-op handle that endSpan ignores.
 *
 * @param {string} name — span name (e.g. "tools/call", "resources/read")
 * @param {Record<string, any>} attributes — initial attributes
 * @returns {{traceId:string,spanId:string,startNs:string,name:string,attributes:object} | null}
 */
function startSpan(name, attributes = {}) {
  if (!ENABLED) return null;
  return {
    traceId: randHex(16),
    spanId: randHex(8),
    startNs: nowNs(),
    name,
    attributes: { ...attributes },
  };
}

/**
 * End a span and queue it for export. No-op if span is null.
 *
 * @param {object|null} span — handle from startSpan
 * @param {{status?: "ok"|"error", error?: string, attributes?: object}} opts
 */
function endSpan(span, opts = {}) {
  if (!span || !ENABLED) return;
  const endNs = nowNs();
  const mergedAttrs = { ...span.attributes, ...(opts.attributes || {}) };

  // Status code per OTLP: 0=UNSET, 1=OK, 2=ERROR
  let statusCode = 0;
  let statusMessage;
  if (opts.status === "ok") statusCode = 1;
  if (opts.status === "error") {
    statusCode = 2;
    statusMessage = opts.error;
  }

  pendingSpans.push({
    traceId: span.traceId,
    spanId: span.spanId,
    name: span.name,
    kind: 1, // SPAN_KIND_INTERNAL
    startTimeUnixNano: span.startNs,
    endTimeUnixNano: endNs,
    attributes: attributesToOtlp(mergedAttrs),
    status: {
      code: statusCode,
      ...(statusMessage ? { message: statusMessage } : {}),
    },
  });
}

function buildResourceSpansPayload(spans) {
  return {
    resourceSpans: [
      {
        resource: {
          attributes: attributesToOtlp({
            "service.name": SERVICE_NAME,
            "service.version": SERVICE_VERSION,
            "telemetry.sdk.name": "boj-server-otel",
            "telemetry.sdk.language": "javascript",
            "telemetry.sdk.version": "1.0",
          }),
        },
        scopeSpans: [
          {
            scope: { name: "boj-mcp-bridge", version: SERVICE_VERSION },
            spans,
          },
        ],
      },
    ],
  };
}

async function flush() {
  if (!ENABLED || pendingSpans.length === 0) return;
  const batch = pendingSpans.splice(0, pendingSpans.length);
  const payload = buildResourceSpansPayload(batch);
  try {
    const resp = await fetch(traceUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...customHeaders,
      },
      body: JSON.stringify(payload),
    });
    if (!resp.ok) {
      // Re-buffer so we try again next tick. Cap at 10k to avoid runaway.
      if (pendingSpans.length < 10_000) {
        pendingSpans.push(...batch);
      }
    }
  } catch {
    // Network failure — re-buffer (best-effort; bounded).
    if (pendingSpans.length < 10_000) {
      pendingSpans.push(...batch);
    }
  }
}

let intervalHandle = null;
let shutdownInstalled = false;

function startBatchFlush() {
  if (!ENABLED || intervalHandle) return;
  intervalHandle = setInterval(() => {
    flush().catch(() => {});
  }, BATCH_MS);
  // setInterval keeps the process alive in Node; unref so stdio handles
  // process lifetime. Deno doesn't expose unref but treats it as no-op.
  if (typeof intervalHandle?.unref === "function") {
    intervalHandle.unref();
  }
}

function installShutdownHooks() {
  if (!ENABLED || shutdownInstalled) return;
  shutdownInstalled = true;

  const finalFlush = () => flush().catch(() => {});

  if (typeof process !== "undefined" && typeof process.on === "function") {
    process.on("beforeExit", finalFlush);
    process.on("SIGTERM", finalFlush);
    process.on("SIGINT", finalFlush);
  }
  // Deno: signal handlers via Deno.addSignalListener if available.
  if (typeof globalThis.Deno !== "undefined" && globalThis.Deno?.addSignalListener) {
    try { globalThis.Deno.addSignalListener("SIGTERM", finalFlush); } catch {}
    try { globalThis.Deno.addSignalListener("SIGINT", finalFlush); } catch {}
  }
}

function init() {
  if (!ENABLED) return;
  startBatchFlush();
  installShutdownHooks();
}

function isEnabled() {
  return ENABLED;
}

export { startSpan, endSpan, flush, init, isEnabled };
