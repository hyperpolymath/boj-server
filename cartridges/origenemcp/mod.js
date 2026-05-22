// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// origenemcp/mod.js — OrigenesMCP biomedical research cartridge.
//
// Delegates to backend at http://127.0.0.1:8788 (override with ORIGENE_URL).
// Auth: ORIGENE_API_KEY (required for all operations).
// Integrates UniProt, ChEMBL, PubChem, OpenTargets, Monarch, PDB, ClinicalTrials.

const BASE_URL = Deno.env.get("ORIGENE_URL") ?? "http://127.0.0.1:8788";
const TIMEOUT_MS = 30_000; // biomedical DB queries can be slow

function getKey() {
  return Deno.env.get("ORIGENE_API_KEY") ?? null;
}

function authHeaders() {
  const key = getKey();
  if (!key) return null;
  return { "Content-Type": "application/json", "X-API-Key": key };
}

async function post(path, payload) {
  const headers = authHeaders();
  if (!headers)
    return { status: 401, data: { success: false, error: "ORIGENE_API_KEY env var is required" } };

  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    const data = await r.json().catch(() => ({ success: false, error: "non-JSON response" }));
    return { status: r.status, data };
  } catch (e) {
    if (e.name === "AbortError")
      return { status: 504, data: { success: false, error: "origenemcp backend timed out" } };
    return { status: 503, data: { success: false, error: `origenemcp backend unavailable: ${e.message}` } };
  } finally { clearTimeout(t); }
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "origenemcp_get_gene_info": {
      const { gene_name, species } = args ?? {};
      if (!gene_name) return { status: 400, data: { error: "gene_name is required" } };
      const payload = { gene_name };
      if (species !== undefined) payload.species = species;
      return post("/api/v1/gene/info", payload);
    }

    case "origenemcp_search_compound": {
      const { compound_name, database } = args ?? {};
      if (!compound_name) return { status: 400, data: { error: "compound_name is required" } };
      const payload = { compound_name };
      if (database !== undefined) payload.database = database;
      return post("/api/v1/compound/search", payload);
    }

    case "origenemcp_get_disease_info": {
      const { disease_name, database } = args ?? {};
      if (!disease_name) return { status: 400, data: { error: "disease_name is required" } };
      const payload = { disease_name };
      if (database !== undefined) payload.database = database;
      return post("/api/v1/disease/info", payload);
    }

    case "origenemcp_search_clinical_trials": {
      const { query, status } = args ?? {};
      if (!query) return { status: 400, data: { error: "query is required" } };
      const payload = { query };
      if (status !== undefined) payload.status = status;
      return post("/api/v1/trials/search", payload);
    }

    case "origenemcp_get_protein_structure": {
      const { pdb_id } = args ?? {};
      if (!pdb_id) return { status: 400, data: { error: "pdb_id is required" } };
      return post("/api/v1/protein/structure", { pdb_id });
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
