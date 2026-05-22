// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// google-docs-mcp/mod.js -- Google Docs cartridge implementation.
//
// Provides MCP tool handlers for the Google Docs API v1:
//   - Document retrieval (full structure)
//   - Plain-text content extraction
//   - Heading extraction (table of contents)
//   - Text search within documents
//   - Comment listing (via Drive API)
//   - Suggestion browsing
//   - Revision history (via Drive API)
//   - Named range access
//   - Document creation
//   - Text insertion
//
// Auth: OAuth2 Bearer token via GOOGLE_DOCS_ACCESS_TOKEN (required).
// API docs: https://developers.google.com/docs/api/reference/rest/v1
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const DOCS_API_BASE = "https://docs.googleapis.com/v1";
const DRIVE_API_BASE = "https://www.googleapis.com/drive/v3";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Google OAuth2 access token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("GOOGLE_DOCS_ACCESS_TOKEN")
    : process.env.GOOGLE_DOCS_ACCESS_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helper — wraps fetch with Google API headers,
// OAuth2 bearer auth, and error normalization.
// ---------------------------------------------------------------------------

async function googleFetch(base, path, queryParams, method, body) {
  const url = new URL(`${base}${path}`);

  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const headers = {
    "Accept": "application/json",
    "User-Agent": "boj-server/google-docs-mcp/0.2.0",
  };

  const token = getToken();
  if (!token) {
    return { status: 401, error: "GOOGLE_DOCS_ACCESS_TOKEN not set." };
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
// Content extraction helpers
// ---------------------------------------------------------------------------

function extractPlainText(doc) {
  const body = doc.body;
  if (!body || !body.content) return "";
  let text = "";
  for (const element of body.content) {
    if (element.paragraph) {
      for (const el of element.paragraph.elements || []) {
        if (el.textRun) text += el.textRun.content;
      }
    }
  }
  return text;
}

function extractHeadings(doc) {
  const body = doc.body;
  if (!body || !body.content) return [];
  const headings = [];
  for (const element of body.content) {
    if (element.paragraph) {
      const style = element.paragraph.paragraphStyle;
      if (style && style.namedStyleType && style.namedStyleType.startsWith("HEADING_")) {
        const level = parseInt(style.namedStyleType.replace("HEADING_", ""), 10);
        let text = "";
        for (const el of element.paragraph.elements || []) {
          if (el.textRun) text += el.textRun.content;
        }
        headings.push({ level, text: text.trim(), startIndex: element.startIndex });
      }
    }
  }
  return headings;
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Google Docs API operations.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Document retrieval ---

    case "gdocs_get_document": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      return googleFetch(DOCS_API_BASE, `/documents/${encodeURIComponent(args.document_id)}`);
    }

    // --- Plain-text content ---

    case "gdocs_get_content": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      const result = await googleFetch(DOCS_API_BASE, `/documents/${encodeURIComponent(args.document_id)}`);
      if (result.error) return result;
      return { status: result.status, data: { title: result.data.title, content: extractPlainText(result.data) } };
    }

    // --- Headings ---

    case "gdocs_get_headings": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      const result = await googleFetch(DOCS_API_BASE, `/documents/${encodeURIComponent(args.document_id)}`);
      if (result.error) return result;
      return { status: result.status, data: { title: result.data.title, headings: extractHeadings(result.data) } };
    }

    // --- Search ---

    case "gdocs_search_content": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      if (!args.query) return { error: "Missing required field: query" };
      const result = await googleFetch(DOCS_API_BASE, `/documents/${encodeURIComponent(args.document_id)}`);
      if (result.error) return result;
      const text = extractPlainText(result.data);
      const matches = [];
      const queryLower = args.query.toLowerCase();
      const lines = text.split("\n");
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].toLowerCase().includes(queryLower)) {
          matches.push({ line: i + 1, text: lines[i].trim() });
        }
      }
      return { status: result.status, data: { query: args.query, matches } };
    }

    // --- Comments (Drive API) ---

    case "gdocs_list_comments": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      const params = { fields: "comments(id,content,author,resolved,createdTime)" };
      if (!args.include_resolved) params.includeDeleted = "false";
      return googleFetch(DRIVE_API_BASE, `/files/${encodeURIComponent(args.document_id)}/comments`, params);
    }

    // --- Suggestions ---

    case "gdocs_list_suggestions": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      const result = await googleFetch(DOCS_API_BASE, `/documents/${encodeURIComponent(args.document_id)}`, {
        suggestionsViewMode: "SUGGESTIONS_INLINE",
      });
      if (result.error) return result;
      const suggestions = result.data.suggestedDocumentStyleChanges || {};
      return { status: result.status, data: { suggestedChanges: suggestions } };
    }

    // --- Revisions (Drive API) ---

    case "gdocs_get_revisions": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      const params = {
        fields: "revisions(id,modifiedTime,lastModifyingUser)",
        pageSize: args.limit || 10,
      };
      return googleFetch(DRIVE_API_BASE, `/files/${encodeURIComponent(args.document_id)}/revisions`, params);
    }

    // --- Named ranges ---

    case "gdocs_get_named_ranges": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      const result = await googleFetch(DOCS_API_BASE, `/documents/${encodeURIComponent(args.document_id)}`);
      if (result.error) return result;
      return { status: result.status, data: { namedRanges: result.data.namedRanges || {} } };
    }

    // --- Create document ---

    case "gdocs_create_document": {
      if (!args.title) return { error: "Missing required field: title" };
      return googleFetch(DOCS_API_BASE, "/documents", null, "POST", { title: args.title });
    }

    // --- Insert text ---

    case "gdocs_insert_text": {
      if (!args.document_id) return { error: "Missing required field: document_id" };
      if (!args.text) return { error: "Missing required field: text" };
      if (args.index === undefined) return { error: "Missing required field: index" };
      return googleFetch(DOCS_API_BASE, `/documents/${encodeURIComponent(args.document_id)}:batchUpdate`, null, "POST", {
        requests: [{
          insertText: {
            location: { index: args.index },
            text: args.text,
          },
        }],
      });
    }

    default:
      return { error: `Unknown google-docs-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "google-docs-mcp",
  version: "0.2.0",
  domain: "Productivity",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 10,
};
