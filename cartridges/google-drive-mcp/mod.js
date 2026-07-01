// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// google-drive-mcp/mod.js -- Google Drive cartridge implementation.
//
// Provides MCP tool handlers for the Google Drive API v3:
//   - Full-query search (files.list q=) incl. shared drives + pagination
//   - Export-aware content reading (Docs->markdown/text, Sheets->CSV)
//   - Explicit format export (pdf/docx/md/csv/...)
//   - Metadata, folder listing, recents, revisions, storage quota
//   - Permissions listing and granting (share)
//   - Copy, create (with inline content), update content, move, rename
//   - REVERSIBLE trash/restore -- permanent files.delete is deliberately
//     NOT implemented (fail-safe: recovery is always possible)
//   - Shared-drive enumeration
//
// Auth: OAuth2 Bearer token via GOOGLE_DRIVE_ACCESS_TOKEN (required).
// API docs: https://developers.google.com/drive/api/reference/rest/v3
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const DRIVE_API_BASE = "https://www.googleapis.com/drive/v3";
const UPLOAD_API_BASE = "https://www.googleapis.com/upload/drive/v3";

// Fields we ask for on file resources -- one place to keep them consistent.
const FILE_FIELDS =
  "id,name,mimeType,size,createdTime,modifiedTime,owners(displayName,emailAddress)," +
  "parents,shared,webViewLink,iconLink,trashed,capabilities(canEdit,canShare,canTrash)";

// Google-native types and their default export mappings.
const EXPORT_DEFAULTS = {
  "application/vnd.google-apps.document": { md: "text/markdown", plain: "text/plain" },
  "application/vnd.google-apps.spreadsheet": { md: "text/csv", plain: "text/csv" },
  "application/vnd.google-apps.presentation": { md: "text/plain", plain: "text/plain" },
};

// ---------------------------------------------------------------------------
// Auth helper -- retrieves the Google OAuth2 access token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("GOOGLE_DRIVE_ACCESS_TOKEN")
    : process.env.GOOGLE_DRIVE_ACCESS_TOKEN;
  return token || null;
}

// ---------------------------------------------------------------------------
// HTTP request helpers -- wrap fetch with Google API headers, OAuth2 bearer
// auth, and error normalisation. driveFetch returns JSON; driveFetchRaw
// returns the raw body (for content download/export).
// ---------------------------------------------------------------------------

async function driveRequest(base, path, queryParams, method, body, bodyContentType) {
  const url = new URL(`${base}${path}`);
  if (queryParams) {
    for (const [key, value] of Object.entries(queryParams)) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const token = getToken();
  if (!token) {
    return {
      error: "GOOGLE_DRIVE_ACCESS_TOKEN is not set. Provide an OAuth2 access token " +
        "with drive scope (via vault-mcp in production).",
    };
  }

  const headers = {
    "Accept": "*/*",
    "Authorization": `Bearer ${token}`,
    "User-Agent": "boj-server/google-drive-mcp/0.1.0",
  };
  if (body !== undefined && bodyContentType) headers["Content-Type"] = bodyContentType;

  let response;
  try {
    response = await fetch(url.toString(), {
      method: method || "GET",
      headers,
      body: body === undefined ? undefined
        : (typeof body === "string" ? body : JSON.stringify(body)),
    });
  } catch (err) {
    return { error: `Network error calling Google Drive API: ${err.message}` };
  }
  return { response };
}

async function driveFetch(path, queryParams, method, jsonBody) {
  const r = await driveRequest(
    DRIVE_API_BASE, path, queryParams, method,
    jsonBody === undefined ? undefined : jsonBody, "application/json",
  );
  if (r.error) return r;
  const { response } = r;
  let data = null;
  const text = await response.text();
  if (text) {
    try { data = JSON.parse(text); } catch { data = { raw: text }; }
  }
  if (!response.ok) {
    const message = data && data.error && data.error.message ? data.error.message : text;
    return { error: `Google Drive API ${response.status}: ${message}`, status: response.status };
  }
  return { status: response.status, data };
}

async function driveFetchRaw(path, queryParams) {
  const r = await driveRequest(DRIVE_API_BASE, path, queryParams, "GET");
  if (r.error) return r;
  const { response } = r;
  if (!response.ok) {
    const text = await response.text();
    return { error: `Google Drive API ${response.status}: ${text}`, status: response.status };
  }
  const contentType = response.headers.get("content-type") || "application/octet-stream";
  const bytes = new Uint8Array(await response.arrayBuffer());
  return { status: response.status, contentType, bytes };
}

function bytesToBase64(bytes) {
  let bin = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}

function isTextual(contentType) {
  return /^text\/|json|xml|csv|markdown|javascript/.test(contentType);
}

// Common list params for shared-drive-aware queries.
function sharedDriveParams(include) {
  return include === false
    ? {}
    : { supportsAllDrives: true, includeItemsFromAllDrives: true };
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  args = args || {};
  switch (toolName) {
    case "gdrive_search": {
      if (args.query === undefined) return { error: "Missing required field: query" };
      const params = {
        q: args.query,
        pageSize: Math.min(Math.max(args.page_size || 25, 1), 1000),
        pageToken: args.page_token,
        orderBy: args.order_by,
        fields: `nextPageToken,files(${FILE_FIELDS})`,
        ...sharedDriveParams(args.include_shared_drives),
      };
      if (args.drive_id) {
        params.driveId = args.drive_id;
        params.corpora = "drive";
      }
      return await driveFetch("/files", params);
    }

    case "gdrive_read_content": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      const maxBytes = args.max_bytes || 1048576;
      const meta = await driveFetch(`/files/${encodeURIComponent(args.file_id)}`, {
        fields: "id,name,mimeType,size", supportsAllDrives: true,
      });
      if (meta.error) return meta;
      const mime = meta.data.mimeType || "";
      const exportMap = EXPORT_DEFAULTS[mime];
      let raw;
      if (exportMap) {
        const target = args.prefer_markdown === false ? exportMap.plain : exportMap.md;
        raw = await driveFetchRaw(
          `/files/${encodeURIComponent(args.file_id)}/export`, { mimeType: target },
        );
      } else {
        if (meta.data.size && Number(meta.data.size) > maxBytes) {
          return {
            error: `File is ${meta.data.size} bytes, over the ${maxBytes}-byte cap. ` +
              "Raise max_bytes or use gdrive_export.",
          };
        }
        raw = await driveFetchRaw(
          `/files/${encodeURIComponent(args.file_id)}`, { alt: "media", supportsAllDrives: true },
        );
      }
      if (raw.error) return raw;
      if (raw.bytes.length > maxBytes) {
        return { error: `Content is ${raw.bytes.length} bytes, over the ${maxBytes}-byte cap.` };
      }
      if (isTextual(raw.contentType)) {
        return {
          status: raw.status,
          data: {
            name: meta.data.name, mimeType: mime, contentType: raw.contentType,
            content: new TextDecoder().decode(raw.bytes),
          },
        };
      }
      return {
        status: raw.status,
        data: {
          name: meta.data.name, mimeType: mime, contentType: raw.contentType,
          encoding: "base64", content: bytesToBase64(raw.bytes),
        },
      };
    }

    case "gdrive_export": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      if (!args.mime_type) return { error: "Missing required field: mime_type" };
      const raw = await driveFetchRaw(
        `/files/${encodeURIComponent(args.file_id)}/export`, { mimeType: args.mime_type },
      );
      if (raw.error) return raw;
      if (isTextual(raw.contentType)) {
        return {
          status: raw.status,
          data: { contentType: raw.contentType, content: new TextDecoder().decode(raw.bytes) },
        };
      }
      return {
        status: raw.status,
        data: { contentType: raw.contentType, encoding: "base64", content: bytesToBase64(raw.bytes) },
      };
    }

    case "gdrive_get_metadata": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      return await driveFetch(`/files/${encodeURIComponent(args.file_id)}`, {
        fields: FILE_FIELDS + ",description,starred,version,md5Checksum,quotaBytesUsed",
        supportsAllDrives: true,
      });
    }

    case "gdrive_list_recent": {
      return await driveFetch("/files", {
        q: "trashed = false",
        orderBy: "modifiedTime desc",
        pageSize: Math.min(args.page_size || 20, 100),
        fields: `files(${FILE_FIELDS})`,
        ...sharedDriveParams(args.include_shared_drives),
      });
    }

    case "gdrive_list_folder": {
      if (!args.folder_id) return { error: "Missing required field: folder_id" };
      return await driveFetch("/files", {
        q: `'${args.folder_id.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}' in parents and trashed = false`,
        orderBy: args.order_by || "folder,name",
        pageSize: Math.min(args.page_size || 50, 1000),
        pageToken: args.page_token,
        fields: `nextPageToken,files(${FILE_FIELDS})`,
        ...sharedDriveParams(true),
      });
    }

    case "gdrive_get_permissions": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      return await driveFetch(`/files/${encodeURIComponent(args.file_id)}/permissions`, {
        fields: "permissions(id,type,role,emailAddress,domain,displayName,expirationTime,deleted)",
        supportsAllDrives: true,
      });
    }

    case "gdrive_share": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      if (!args.role) return { error: "Missing required field: role" };
      if (!args.grantee_type) return { error: "Missing required field: grantee_type" };
      if (!["reader", "commenter", "writer"].includes(args.role)) {
        return { error: `Unsupported role '${args.role}' (owner transfer is deliberately not offered)` };
      }
      const permission = { type: args.grantee_type, role: args.role };
      if (args.grantee_type === "user" || args.grantee_type === "group") {
        if (!args.email) return { error: "email is required for user/group grants" };
        permission.emailAddress = args.email;
      } else if (args.grantee_type === "domain") {
        if (!args.domain) return { error: "domain is required for domain grants" };
        permission.domain = args.domain;
      }
      return await driveFetch(
        `/files/${encodeURIComponent(args.file_id)}/permissions`,
        {
          sendNotificationEmail: args.send_notification === true,
          supportsAllDrives: true,
        },
        "POST", permission,
      );
    }

    case "gdrive_copy": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      const body = {};
      if (args.name) body.name = args.name;
      if (args.parent_folder_id) body.parents = [args.parent_folder_id];
      return await driveFetch(
        `/files/${encodeURIComponent(args.file_id)}/copy`,
        { fields: FILE_FIELDS, supportsAllDrives: true }, "POST", body,
      );
    }

    case "gdrive_create_file": {
      if (!args.name) return { error: "Missing required field: name" };
      const mime = args.mime_type || (args.content !== undefined ? "text/plain" : undefined);
      const meta = { name: args.name };
      if (mime) meta.mimeType = mime;
      meta.parents = [args.parent_folder_id || "root"];

      if (args.content === undefined || mime === "application/vnd.google-apps.folder") {
        // Metadata-only create (folders, empty files, empty Google Docs).
        return await driveFetch("/files", { fields: FILE_FIELDS, supportsAllDrives: true }, "POST", meta);
      }

      // Multipart upload: metadata + inline text content in one call.
      const boundary = "boj-gdrive-" + Math.random().toString(36).slice(2);
      const contentMime = mime && !mime.startsWith("application/vnd.google-apps")
        ? mime : "text/plain";
      const multipart =
        `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n` +
        JSON.stringify(meta) +
        `\r\n--${boundary}\r\nContent-Type: ${contentMime}\r\n\r\n` +
        args.content +
        `\r\n--${boundary}--`;
      const r = await driveRequest(
        UPLOAD_API_BASE, "/files",
        { uploadType: "multipart", fields: FILE_FIELDS, supportsAllDrives: true },
        "POST", multipart, `multipart/related; boundary=${boundary}`,
      );
      if (r.error) return r;
      const text = await r.response.text();
      let data;
      try { data = JSON.parse(text); } catch { data = { raw: text }; }
      if (!r.response.ok) {
        return { error: `Google Drive API ${r.response.status}: ${text}`, status: r.response.status };
      }
      return { status: r.response.status, data };
    }

    case "gdrive_update_content": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      if (args.content === undefined) return { error: "Missing required field: content" };
      const r = await driveRequest(
        UPLOAD_API_BASE, `/files/${encodeURIComponent(args.file_id)}`,
        { uploadType: "media", supportsAllDrives: true },
        "PATCH", args.content, args.mime_type || "text/plain",
      );
      if (r.error) return r;
      const text = await r.response.text();
      let data;
      try { data = JSON.parse(text); } catch { data = { raw: text }; }
      if (!r.response.ok) {
        return { error: `Google Drive API ${r.response.status}: ${text}`, status: r.response.status };
      }
      return { status: r.response.status, data };
    }

    case "gdrive_move": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      if (!args.destination_folder_id) return { error: "Missing required field: destination_folder_id" };
      const meta = await driveFetch(`/files/${encodeURIComponent(args.file_id)}`, {
        fields: "parents", supportsAllDrives: true,
      });
      if (meta.error) return meta;
      const oldParents = (meta.data.parents || []).join(",");
      return await driveFetch(
        `/files/${encodeURIComponent(args.file_id)}`,
        {
          addParents: args.destination_folder_id,
          removeParents: oldParents,
          fields: FILE_FIELDS,
          supportsAllDrives: true,
        },
        "PATCH", {},
      );
    }

    case "gdrive_rename": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      if (!args.new_name) return { error: "Missing required field: new_name" };
      return await driveFetch(
        `/files/${encodeURIComponent(args.file_id)}`,
        { fields: FILE_FIELDS, supportsAllDrives: true },
        "PATCH", { name: args.new_name },
      );
    }

    case "gdrive_trash": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      // Reversible by design; files.delete (permanent) is deliberately absent.
      return await driveFetch(
        `/files/${encodeURIComponent(args.file_id)}`,
        { fields: "id,name,trashed", supportsAllDrives: true },
        "PATCH", { trashed: true },
      );
    }

    case "gdrive_restore": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      return await driveFetch(
        `/files/${encodeURIComponent(args.file_id)}`,
        { fields: "id,name,trashed", supportsAllDrives: true },
        "PATCH", { trashed: false },
      );
    }

    case "gdrive_list_revisions": {
      if (!args.file_id) return { error: "Missing required field: file_id" };
      return await driveFetch(`/files/${encodeURIComponent(args.file_id)}/revisions`, {
        pageSize: Math.min(args.page_size || 20, 200),
        fields: "revisions(id,modifiedTime,lastModifyingUser(displayName,emailAddress)," +
          "size,keepForever,originalFilename,exportLinks)",
      });
    }

    case "gdrive_storage_quota": {
      const result = await driveFetch("/about", { fields: "storageQuota,user(displayName,emailAddress)" });
      if (result.error) return result;
      const q = result.data.storageQuota || {};
      return {
        status: result.status,
        data: {
          user: result.data.user,
          limit: q.limit, usage: q.usage,
          usageInDrive: q.usageInDrive, usageInDriveTrash: q.usageInDriveTrash,
        },
      };
    }

    case "gdrive_list_shared_drives": {
      return await driveFetch("/drives", {
        pageSize: Math.min(args.page_size || 20, 100),
        pageToken: args.page_token,
        fields: "nextPageToken,drives(id,name,createdTime,capabilities(canManageMembers))",
      });
    }

    default:
      return { error: `Unknown google-drive-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export -- used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "google-drive-mcp",
  version: "0.1.0",
  domain: "Productivity",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 18,
};
