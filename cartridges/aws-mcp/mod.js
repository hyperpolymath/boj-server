// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// aws-mcp/mod.js -- aws gateway.

const BASE_URL = Deno.env.get("AWS_MCP_BACKEND_URL") ?? "http://127.0.0.1:7713";

async function post(path, payload) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 15000);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload), signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError") return { status: 504, data: { success: false, error: "aws-mcp backend timed out" } };
    return { status: 503, data: { success: false, error: `aws-mcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {

    case "aws_authenticate": {
      const { region, profile } = args ?? {};
      if (!region) return { status: 400, data: { error: "region is required" } };
      const payload = { region };
      if (profile !== undefined) payload.profile = profile;
      return post("/api/v1/authenticate", payload);
    }
    case "aws_s3_list": {
      const { bucket, prefix } = args ?? {};
      const payload = {  };
      if (bucket !== undefined) payload.bucket = bucket;
      if (prefix !== undefined) payload.prefix = prefix;
      return post("/api/v1/s3-list", payload);
    }
    case "aws_s3_get": {
      const { bucket, key } = args ?? {};
      if (!bucket || !key) return { status: 400, data: { error: "bucket is required" } };
      const payload = { bucket, key };
      return post("/api/v1/s3-get", payload);
    }
    case "aws_s3_put": {
      const { bucket, key, body } = args ?? {};
      if (!bucket || !key || !body) return { status: 400, data: { error: "bucket is required" } };
      const payload = { bucket, key, body };
      return post("/api/v1/s3-put", payload);
    }
    case "aws_ec2_list": {
      const { region, state } = args ?? {};
      const payload = {  };
      if (region !== undefined) payload.region = region;
      if (state !== undefined) payload.state = state;
      return post("/api/v1/ec2-list", payload);
    }
    case "aws_lambda_invoke": {
      const { function_name, payload } = args ?? {};
      if (!function_name) return { status: 400, data: { error: "function_name is required" } };
      const payload = { function_name };
      if (payload !== undefined) payload.payload = payload;
      return post("/api/v1/lambda-invoke", payload);
    }
    case "aws_session_state": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/session-state", payload);
    }
    case "aws_deauthenticate": {
      const { slot } = args ?? {};
      if (!slot) return { status: 400, data: { error: "slot is required" } };
      const payload = { slot };
      return post("/api/v1/deauthenticate", payload);
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
