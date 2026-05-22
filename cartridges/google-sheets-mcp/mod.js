// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// google-sheets-mcp/mod.js -- Google Sheets cartridge implementation.
//
// Provides MCP tool handlers for the Google Sheets API v4:
//   - Spreadsheet metadata retrieval
//   - Cell range reading (single and batch)
//   - Sheet (tab) listing
//   - Named range access
//   - Cell value writing
//   - Row appending
//   - Sheet creation
//   - Conditional format listing
//   - Pivot table access
//
// Auth: OAuth2 Bearer token via GOOGLE_SHEETS_ACCESS_TOKEN (required).
// API docs: https://developers.google.com/sheets/api/reference/rest/v4
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://sheets.googleapis.com/v4";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Google OAuth2 access token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("GOOGLE_SHEETS_ACCESS_TOKEN")
    : process.env.GOOGLE_SHEETS_ACCESS_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Google Sheets API headers,
// OAuth2 bearer auth, and error normalization.
// ---------------------------------------------------------------------------

async function sheetsFetch(path, queryParams, method, body) {
  const url = new URL(`${API_BASE}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        if (Array.isArray(value)) {
          for (const v of value) url.searchParams.append(key, v);
        } else {
          url.searchParams.set(key, String(value));
        }
      }
    }
  }

  const headers = {
    "Accept": "application/json",
    "User-Agent": "boj-server/google-sheets-mcp/0.2.0",
  };

  const token = getToken();
  if (!token) {
    return { status: 401, error: "GOOGLE_SHEETS_ACCESS_TOKEN not set." };
  }
  headers["Authorization"] = `Bearer ${token}`;

  const fetchOpts = { method: method || "GET", headers };

  if (body) {
    headers["Content-Type"] = "application/json";
    fetchOpts.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), fetchOpts);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    return {
      status: 429,
      error: `Rate limited. Retry after ${retryAfter || "unknown"} seconds.`,
      retryAfter,
    };
  }

  const data = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errorMessage = data.error?.message || data.message || `HTTP ${response.status}`;
    return { status: response.status, error: errorMessage, data };
  }

  return { status: response.status, data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Google Sheets API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Spreadsheet metadata ---

    case "gsheets_get_spreadsheet": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      return sheetsFetch(`/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}`, {
        fields: "spreadsheetId,properties,sheets.properties,namedRanges",
      });
    }

    // --- Read range ---

    case "gsheets_read_range": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      if (!args.range) return { error: "Missing required field: range" };
      return sheetsFetch(
        `/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}/values/${encodeURIComponent(args.range)}`,
        { valueRenderOption: args.value_render || "FORMATTED_VALUE" },
      );
    }

    // --- List sheets ---

    case "gsheets_list_sheets": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      const result = await sheetsFetch(`/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}`, {
        fields: "sheets.properties",
      });
      if (result.error) return result;
      return { status: result.status, data: { sheets: (result.data.sheets || []).map((s) => s.properties) } };
    }

    // --- Named ranges ---

    case "gsheets_get_named_ranges": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      const result = await sheetsFetch(`/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}`, {
        fields: "namedRanges",
      });
      if (result.error) return result;
      return { status: result.status, data: { namedRanges: result.data.namedRanges || [] } };
    }

    // --- Write range ---

    case "gsheets_write_range": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      if (!args.range) return { error: "Missing required field: range" };
      if (!args.values) return { error: "Missing required field: values" };
      const values = typeof args.values === "string" ? JSON.parse(args.values) : args.values;
      return sheetsFetch(
        `/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}/values/${encodeURIComponent(args.range)}`,
        { valueInputOption: args.value_input || "USER_ENTERED" },
        "PUT",
        { range: args.range, majorDimension: "ROWS", values },
      );
    }

    // --- Append rows ---

    case "gsheets_append_rows": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      if (!args.range) return { error: "Missing required field: range" };
      if (!args.values) return { error: "Missing required field: values" };
      const values = typeof args.values === "string" ? JSON.parse(args.values) : args.values;
      return sheetsFetch(
        `/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}/values/${encodeURIComponent(args.range)}:append`,
        {
          valueInputOption: args.value_input || "USER_ENTERED",
          insertDataOption: "INSERT_ROWS",
        },
        "POST",
        { range: args.range, majorDimension: "ROWS", values },
      );
    }

    // --- Create sheet ---

    case "gsheets_create_sheet": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      if (!args.title) return { error: "Missing required field: title" };
      return sheetsFetch(
        `/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}:batchUpdate`,
        null,
        "POST",
        {
          requests: [{
            addSheet: {
              properties: {
                title: args.title,
                gridProperties: {
                  rowCount: args.row_count || 1000,
                  columnCount: args.column_count || 26,
                },
              },
            },
          }],
        },
      );
    }

    // --- Batch read ---

    case "gsheets_batch_read": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      if (!args.ranges) return { error: "Missing required field: ranges" };
      const ranges = args.ranges.split(",").map((r) => r.trim());
      return sheetsFetch(
        `/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}/values:batchGet`,
        {
          ranges,
          valueRenderOption: args.value_render || "FORMATTED_VALUE",
        },
      );
    }

    // --- Conditional formats ---

    case "gsheets_get_conditional_formats": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      if (args.sheet_id === undefined) return { error: "Missing required field: sheet_id" };
      const result = await sheetsFetch(`/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}`, {
        fields: "sheets(properties,conditionalFormats)",
      });
      if (result.error) return result;
      const sheet = (result.data.sheets || []).find((s) => s.properties.sheetId === args.sheet_id);
      return { status: result.status, data: { conditionalFormats: sheet?.conditionalFormats || [] } };
    }

    // --- Pivot tables ---

    case "gsheets_get_pivot_tables": {
      if (!args.spreadsheet_id) return { error: "Missing required field: spreadsheet_id" };
      const result = await sheetsFetch(`/spreadsheets/${encodeURIComponent(args.spreadsheet_id)}`, {
        fields: "sheets(properties,data.rowData.values.pivotTable)",
      });
      if (result.error) return result;
      const pivots = [];
      for (const sheet of result.data.sheets || []) {
        if (sheet.data) {
          for (const rowData of sheet.data) {
            for (const row of rowData.rowData || []) {
              for (const cell of row.values || []) {
                if (cell.pivotTable) pivots.push({ sheet: sheet.properties.title, pivotTable: cell.pivotTable });
              }
            }
          }
        }
      }
      return { status: result.status, data: { pivotTables: pivots } };
    }

    default:
      return { error: `Unknown google-sheets-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "google-sheets-mcp",
  version: "0.2.0",
  domain: "Productivity",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
