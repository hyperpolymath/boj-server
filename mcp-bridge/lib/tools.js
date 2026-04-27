// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP tool definitions
//
// Builds the MCP tool list from cartridge data. Separates tool schema
// definitions from transport and dispatch logic.

/**
 * Build the full MCP tool list.
 * @returns {Array<{name: string, description: string, inputSchema: object}>}
 */
function buildToolList() {
  const tools = [];

  // Core server tools
  tools.push({
    name: "boj_health",
    description: "Ping the BoJ server and report liveness. Returns `{status:\"ok\", uptime_s, version}` when the REST backend at BOJ_URL is reachable; returns a structured error hint when the backend is offline. Zero-argument, read-only, no side effects — safe to call at any time. Use before invoking any other boj_* tool to confirm the cartridge fleet is live.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  });

  tools.push({
    name: "boj_menu",
    description: "List every installed BoJ cartridge grouped by trust tier (Teranga, Shield, Ayo) with name, version, domain, supported protocols, and availability flag. Read-only snapshot — no side effects. Returns offline static manifest when the backend is unreachable, so the tool is always inspectable. Use this as the first call when an agent needs to discover what capabilities are mounted; follow with `boj_cartridge_info` for a specific cartridge's tools.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  });

  tools.push({
    name: "boj_cartridges",
    description: "Return the BoJ capability matrix — a `protocol × domain` grid marking which cartridges serve each combination (e.g. MCP+Database → database-mcp). Complements `boj_menu` (flat list) with a two-dimensional view optimised for routing decisions. Read-only; no side effects. Use when selecting a cartridge by protocol (MCP / REST / gRPC / GraphQL / LSP / DAP / BSP) rather than by name.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  });

  tools.push({
    name: "boj_cartridge_info",
    description: "Return the full manifest of a single cartridge. Read-only; no side effects. Includes declared tools, input schemas, version, domain, auth model, supported protocols, and health endpoint. Returns the manifest object or `{error:\"not found\", hint}` for unknown cartridge names. Use after `boj_menu` to inspect a cartridge's specific tool surface before invocation.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Exact cartridge identifier, e.g. `database-mcp`, `container-mcp`, `git-mcp`, `local-coord-mcp`. Discoverable via `boj_menu`. Case-sensitive; must match the `-mcp` suffix convention.",
          minLength: 1,
          maxLength: 64,
          pattern: "^[a-z0-9][a-z0-9-]*-mcp$",
        },
      },
      required: ["name"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "boj_cartridge_invoke",
    description: "Generic cartridge invocation — forward a typed command to a specific cartridge's REST endpoint and return its JSON response. Side-effectful: the downstream cartridge may read or mutate external state (DB writes, git ops, container starts, etc.). Returns the raw JSON response from the cartridge. For tier-2+ operations, prefer the explicit `boj_<domain>_*` tools which declare richer input schemas and trigger stronger field validation.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Target cartridge identifier (see `boj_menu`). Case-sensitive.",
          minLength: 1,
          maxLength: 64,
          pattern: "^[a-z0-9][a-z0-9-]*-mcp$",
        },
        params: {
          type: "object",
          description: "Cartridge-specific parameter object. Shape is defined by the target cartridge's manifest — call `boj_cartridge_info` first to discover the expected schema for this specific cartridge.",
        },
      },
      required: ["name"],
      additionalProperties: false,
    },
  });

  // Cloud providers
  tools.push({
    name: "boj_cloud_verpex",
    description: "Manage Verpex (cPanel UAPI) hosting resources including domains, DNS records, email accounts, MySQL databases, SSL certificates, cron jobs, and resource metrics. Side-effectful for `dns-add`/`dns-remove`/`email-create`/`database-create` ops; Read-only for list/status/metrics ops. Returns structured JSON or `{error, hint}` on auth failure or missing parameters. `authenticate` stores credentials for subsequent reuse.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-domains", "dns-list", "dns-add", "dns-remove", "email-list", "email-create", "databases-list", "database-create", "ssl-status", "cron-list", "metrics"], description: "Which Verpex op to run. `authenticate` must be called first with valid credentials." },
        hostname: { type: "string", description: "cPanel hostname for `authenticate` (e.g. `panel.example.com`). Ignored on other ops." },
        username: { type: "string", description: "cPanel username for `authenticate`. Ignored on other ops." },
        api_token: { type: "string", description: "cPanel API token for `authenticate`. Ignored on other ops." },
        domain: { type: "string", description: "Domain name, required for DNS and SSL operations." },
        params: { type: "object", description: "Op-specific payload: `dns-add` → {name, type, value, ttl?}; `email-create` → {email, password}; `database-create` → {name}; `metrics` → {window?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "boj_cloud_cloudflare",
    description: "Manage Cloudflare edge resources including Workers scripts, D1 SQLite databases, KV namespaces, R2 object buckets, and DNS records. Side-effectful for mutations (`kv-put`, `add-dns-record`, `query-d1` write ops); Read-only for list and get ops. Returns the direct Cloudflare API response or `{error, hint}`. `authenticate` stores an API token for subsequent reuse within the session.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-workers", "get-worker", "list-d1", "query-d1", "list-kv", "kv-get", "kv-put", "list-r2", "list-dns-zones", "list-dns-records", "add-dns-record"], description: "Which Cloudflare op to run. `authenticate` must be called first with a scoped API token." },
        api_token: { type: "string", description: "Cloudflare API token with scope matching the requested op. Required for `authenticate`; ignored afterwards." },
        params: { type: "object", description: "Op-specific payload: `get-worker` → {script_name}; `query-d1` → {database_id, sql, bindings?}; `kv-get`/`kv-put` → {namespace_id, key, value?}; `add-dns-record` → {zone_id, type, name, content, ttl?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "boj_cloud_vercel",
    description: "Manage Vercel projects, deployments, custom domains, environment variables, build logs, and serverless functions. Read-only; no create/delete operations supported through this tool (use Vercel dashboard for destructive actions). Returns the direct Vercel API response or `{error, hint}` on failure. `authenticate` stores an API token for subsequent reuse.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-projects", "get-project", "list-deployments", "get-deployment", "list-domains", "list-env-vars", "deployment-logs", "list-functions"], description: "Which Vercel op to run. `authenticate` must be called first with a valid Vercel API token." },
        api_token: { type: "string", description: "Vercel API token. Required for `authenticate`; ignored afterwards." },
        params: { type: "object", description: "Op-specific payload: `get-project`/`list-env-vars`/`list-functions` → {project_id}; `get-deployment`/`deployment-logs` → {deployment_id}; `list-deployments` → {project_id?, limit?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // Communications
  tools.push({
    name: "boj_comms_gmail",
    description: "Gmail operations via the comms-mcp cartridge including send, read, search, and label management. `authenticate` exchanges an OAuth2 token once; subsequent calls reuse the stored credential. Side-effectful for `send` (delivers mail) and `labels` (mutates account state); Read-only for `read` and `search` ops. Returns structured JSON containing message/thread data or `{error, hint}` on failure. Essential for managing email-based workflows.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "send", "read", "search", "labels"], description: "Which Gmail operation to run. `authenticate` must be called first to establish a session." },
        oauth_token: { type: "string", description: "OAuth2 bearer token. Required for `authenticate`; ignored on subsequent operations that reuse the stored credential." },
        params: { type: "object", description: "Op-specific payload: `send` → {to, subject, body, cc?, bcc?}; `read` → {message_id}; `search` → {query, max?}; `labels` → {action:'list'|'add'|'remove', label?, message_id?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "boj_comms_calendar",
    description: "Google Calendar operations via the comms-mcp cartridge — list upcoming events, create new events, and check free/busy windows. `authenticate` exchanges an OAuth2 token once; subsequent calls reuse the stored credential. `create-event` is side-effectful; `list-events` and `free-busy` are read-only. Returns structured JSON with event arrays or detailed availability windows. Useful for automated scheduling and coordination.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-events", "create-event", "free-busy"], description: "Which Calendar operation to run. `authenticate` must be called first with a valid token." },
        oauth_token: { type: "string", description: "OAuth2 bearer token. Required for `authenticate`; ignored on subsequent operations." },
        params: { type: "object", description: "Op-specific payload: `list-events` → {calendar_id?, time_min?, time_max?, max?}; `create-event` → {calendar_id?, summary, start, end, attendees?}; `free-busy` → {calendars[], time_min, time_max}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // ML/AI
  tools.push({
    name: "boj_ml_huggingface",
    description: "Hugging Face Hub operations via the ml-mcp cartridge — search models/datasets/spaces, fetch model cards, and run hosted inference. `authenticate` stores an HF API token once; subsequent calls reuse it. `inference` is side-effectful on the HF backend (counts against quota) but idempotent locally; list/info ops are read-only. Returns structured JSON containing model metadata or inference results. Powerful for integrating open-source models into automated workflows.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-models", "model-info", "inference", "list-spaces", "list-datasets"], description: "Which HF operation to run. `authenticate` must be called first unless a stored token is present." },
        api_token: { type: "string", description: "Hugging Face API token with appropriate scope. Required for `authenticate`; ignored afterwards." },
        params: { type: "object", description: "Op-specific payload: `search-models`/`list-spaces`/`list-datasets` → {query, limit?, filter?}; `model-info` → {model_id}; `inference` → {model_id, inputs, parameters?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // Browser automation — all routed through browser-mcp to the Firefox WebDriver session
  tools.push({
    name: "boj_browser_navigate",
    description: "Drive the controlled Firefox session to a new URL. Side-effectful; replaces the active tab's document and resets the click/type state machine. Waits for the browser `load` event before returning. Returns `{ok:true, final_url, title}` on success or `{error, hint}` on network failure. Always use this tool first when orienting to a new page before attempting clicks or text extraction.",
    inputSchema: { type: "object", properties: { url: { type: "string", description: "Absolute URL (http/https) to navigate to. Relative paths are rejected.", minLength: 7 } }, required: ["url"], additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_click",
    description: "Click the first element matching a CSS selector on the current page. Side-effectful; may trigger navigation, form submission, or JavaScript event handlers. Waits for the target element to be both visible and enabled before clicking. Returns `{ok:true, selector}` on success or `{error:\"not found\"|\"not visible\"}`. Use after `boj_browser_navigate` has settled and the page structure is known.",
    inputSchema: { type: "object", properties: { selector: { type: "string", description: "CSS selector of the target element, e.g. `button#submit`, `a[href$='.pdf']`. Must match at least one visible element.", minLength: 1 } }, required: ["selector"], additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_type",
    description: "Type literal text into the first input, textarea, or contenteditable element matching a CSS selector. Side-effectful; fires `input` and `change` events as each character is delivered. Returns `{ok:true, selector}` on success or `{error:\"not editable\"|\"not found\"}`. Does not automatically submit forms; pair with `boj_browser_click` on the submit button for full interaction.",
    inputSchema: { type: "object", properties: { selector: { type: "string", description: "CSS selector of the target input element.", minLength: 1 }, text: { type: "string", description: "Literal text to deliver. Special keys like Enter or Tab are not interpreted; use `boj_browser_execute_js` for synthetic keyboard events.", minLength: 1 } }, required: ["selector", "text"], additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_read_page",
    description: "Extract the visible text content of the active tab. Read-only; no side effects. Concatenates body text, strips scripts/styles, and preserves rough reading order. Returns `{url, title, text, text_length}` with content capped at ~1 MB for context efficiency. Use after navigation has settled to provide page content to the LLM for analysis.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_screenshot",
    description: "Capture a PNG screenshot of the active tab's current viewport. Read-only; no side effects. Returns base64-encoded image bytes under `{ok:true, image_base64, mime:\"image/png\"}`. Use when text extraction via `boj_browser_read_page` is insufficient, such as for analyzing complex layouts, charts, or visual bugs.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_tabs",
    description: "Manage browser tabs within the active session. `list` is read-only; `create` and `close` are side-effectful. Returns `{ok:true, tabs:[...]}` for list, `{ok:true, tab_id}` for create, or `{ok:true}` for close. Use to orchestrate multi-page workflows or to isolate different investigations without losing the state of the primary tab.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["list", "create", "close"], description: "Tab operation to perform: `list` returns all open tabs, `create` opens a new tab, `close` terminates the specified tab." },
        url: { type: "string", description: "Optional initial URL for the `create` operation. Ignored for list and close." },
        tab_id: { type: "number", description: "Numeric tab ID returned by a prior `list` operation. Required for `close`, ignored otherwise.", minimum: 0 },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });
  tools.push({
    name: "boj_browser_execute_js",
    description: "Execute a JavaScript snippet in the context of the active tab and return the value of the last expression. Side-effectful; can mutate the DOM, fire events, or inspect internal JS state. Returns `{ok:true, result}` (result must be JSON-serialisable) or `{error, stack}` on exception. Sandboxed to the target origin for security. Use when declarative actions like click or type are insufficient for complex interactions.",
    inputSchema: { type: "object", properties: { script: { type: "string", description: "JavaScript source code to execute. The last expression's value is returned; use an IIFE for multi-statement logic.", minLength: 1 } }, required: ["script"], additionalProperties: false },
  });

  // GitHub API tools — all routed via the authenticated backend token; read-only unless noted.
  const ghTools = [
    { name: "boj_github_list_repos", desc: "List repositories owned by or accessible to the authenticated GitHub user. Read-only; no side effects. Paginated; default 30, max 100 per page. Use `sort` to order by last-activity axis. Returns an array of repository objects `[{name, full_name, private, default_branch, ...}]`. Useful for project discovery.", props: { per_page: { type: "number", minimum: 1, maximum: 100, description: "Results per page (1..100, default 30)." }, sort: { type: "string", enum: ["updated", "created", "pushed", "full_name"], description: "Sort key: `updated` (metadata), `pushed` (commits), `created`, `full_name`." } } },
    { name: "boj_github_get_repo", desc: "Fetch detailed metadata for a single GitHub repository. Read-only; no side effects. Includes description, default branch, topics, visibility, stars, and language breakdown. Returns a full repository object or `{error, status}`. Use before operations that need `default_branch` (e.g. `boj_github_create_pr` with `base` omitted) to ensure correct targeting.", props: { owner: { type: "string", description: "Repo owner login (user or org)." }, repo: { type: "string", description: "Repo name (without owner prefix)." } }, req: ["owner", "repo"] },
    { name: "boj_github_create_issue", desc: "Open a new issue on a GitHub repository. Side-effectful; creates a new record. Returns the created issue metadata `{number, html_url, state, ...}` on success. Pair with `boj_github_comment_issue` for subsequent follow-ups or automated status updates.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, title: { type: "string", description: "Issue title. Keep under 80 chars.", minLength: 1 }, body: { type: "string", description: "Markdown body. Optional but recommended." }, labels: { type: "array", items: { type: "string" }, description: "Label names to attach. Labels must already exist on the repo." } }, req: ["owner", "repo", "title"] },
    { name: "boj_github_list_issues", desc: "List issues on a GitHub repository, filtered by state (open, closed, all). Read-only; no side effects. Does NOT include pull requests (use `boj_github_list_prs` for those). Paginated; default 30. Returns an array of issue objects `[{number, title, state, user, labels, ...}]`. Useful for triaging project status and checking open tasks.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, state: { type: "string", enum: ["open", "closed", "all"], description: "Issue state filter (default `open`)." }, per_page: { type: "number", minimum: 1, maximum: 100, description: "Results per page (1..100)." } }, req: ["owner", "repo"] },
    { name: "boj_github_get_issue", desc: "Fetch a single issue's full details. Read-only; no side effects. Includes title, body, state, labels, assignees, and comments count. Returns the issue object or `{error, status}`. Use before `boj_github_comment_issue` to confirm the issue is still open and to gather context from the description.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, issue_number: { type: "number", minimum: 1, description: "Issue number as shown in the URL `#<n>`." } }, req: ["owner", "repo", "issue_number"] },
    { name: "boj_github_comment_issue", desc: "Post a new Markdown comment on a GitHub issue. Side-effectful; visible to all watchers and triggers notifications. Returns the created comment metadata `{id, html_url, user, ...}` on success. Useful for automated updates or recording investigation findings.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, issue_number: { type: "number", minimum: 1, description: "Issue number." }, body: { type: "string", description: "Markdown comment body. Supports full GitHub-flavored Markdown.", minLength: 1 } }, req: ["owner", "repo", "issue_number", "body"] },
    { name: "boj_github_create_pr", desc: "Open a pull request between two branches. Side-effectful; triggers CI workflows and notifies reviewers. `head` must already be pushed to the remote. Returns the created PR metadata `{number, html_url, state, ...}` on success. Essential for submitting code changes for review.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, title: { type: "string", description: "PR title (keep under 70 chars).", minLength: 1 }, body: { type: "string", description: "Markdown body — should include a summary of changes and a test plan." }, head: { type: "string", description: "Source branch (same-repo) or `owner:branch` (cross-fork)." }, base: { type: "string", description: "Target branch, usually `main`. Defaults to repo's `default_branch` when omitted." } }, req: ["owner", "repo", "title", "head"] },
    { name: "boj_github_list_prs", desc: "List pull requests on a GitHub repository, filtered by state. Read-only; no side effects. Does NOT include non-PR issues (use `boj_github_list_issues` for those). Returns an array of PR summary objects `[{number, title, state, user, head, base, html_url, ...}]`. Useful for monitoring active development and code reviews.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, state: { type: "string", enum: ["open", "closed", "all"], description: "PR state filter (default `open`)." } }, req: ["owner", "repo"] },
    { name: "boj_github_get_pr", desc: "Fetch a single pull request's detailed metadata. Read-only; no side effects. Includes title, body, state, head/base refs, mergeable state, and a summary of CI checks. Returns the PR object or `{error, status}`. Use before `boj_github_merge_pr` to confirm CI is green and the branch is mergeable.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, pull_number: { type: "number", minimum: 1, description: "PR number as shown in the URL." } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_merge_pr", desc: "Merge a pull request into the base branch. Side-effectful and hard-to-reverse; triggers branch deletion (if configured) and deployment workflows. Requires CI status to be green and mergeability confirmed. Returns `{sha, merged:true}` on success. Prefer `squash` for a cleaner linear history on the main branch.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, pull_number: { type: "number", minimum: 1, description: "PR number." }, method: { type: "string", enum: ["merge", "squash", "rebase"], description: "Merge strategy (default `merge`). `squash` collapses all commits into one; `rebase` replays commits linearly." } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_search_code", desc: "Search code across GitHub using the Code Search API v2. Read-only; no side effects. Query syntax supports `repo:`, `language:`, `path:`, `symbol:` qualifiers. Returns an object with `total_count` and an `items` array of match results. Rate-limited to 30 requests per minute. Excellent for finding usage patterns or specific symbols across repositories.", props: { query: { type: "string", description: "Code search query, e.g. `repo:hyperpolymath/boj-server \"coord_register\"`. See GitHub's Code Search syntax documentation.", minLength: 1 } }, req: ["query"] },
    { name: "boj_github_search_issues", desc: "Search issues and pull requests across GitHub. Read-only; no side effects. Query syntax supports `repo:`, `is:issue|pr`, `is:open|closed`, `author:`, `label:`. Returns an object with `total_count` and an `items` array of issues/PRs. Useful for finding existing reports or discussions related to a specific topic.", props: { query: { type: "string", description: "Issues search query, e.g. `repo:foo/bar is:pr is:open label:security`.", minLength: 1 } }, req: ["query"] },
    { name: "boj_github_get_file", desc: "Read a file's contents from a GitHub repository at a specific branch, tag, or commit. Read-only; no side effects. Decodes base64 content automatically for text files. Returns `{path, content, sha, encoding:\"utf-8\"}`. Binary files preserve the raw base64 encoding. Useful for inspecting code or reading configuration files without cloning.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, path: { type: "string", description: "Repo-relative path (no leading slash), e.g. `src/main.js`." }, ref: { type: "string", description: "Branch, tag, or commit SHA. Defaults to the repo's default branch if omitted." } }, req: ["owner", "repo", "path"] },
    { name: "boj_github_graphql", desc: "Execute an arbitrary GitHub GraphQL v4 query. Can be Read-only or Side-effectful depending on the query (query vs mutation). Use when REST endpoints are insufficient, such as for batching requests, fetching nested fragments, or custom data aggregates. Returns the raw GraphQL response `{data, errors?}`. Requires a valid schema-compliant query string.", props: { query: { type: "string", description: "GraphQL document. Supports `query` and `mutation` operations.", minLength: 1 }, variables: { type: "object", description: "Optional GraphQL variables object, keyed by `$name` references inside the query." } }, req: ["query"] },
  ];
  for (const t of ghTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [], additionalProperties: false } });
  }

  // GitLab API tools — routed via authenticated backend token; read-only unless noted.
  const glTools = [
    { name: "boj_gitlab_list_projects", desc: "List GitLab projects accessible to the authenticated user. Read-only; no side effects. Includes personal, group, and starred projects. Paginated; default 20 per page. Returns an array of project objects `[{id, path_with_namespace, visibility, default_branch, ...}]`. Useful for finding projects within a GitLab instance.", props: { per_page: { type: "number", minimum: 1, maximum: 100, description: "Results per page (1..100, default 20)." } } },
    { name: "boj_gitlab_get_project", desc: "Fetch metadata for a single GitLab project. Read-only; no side effects. Includes description, default branch, visibility, topics, and repository statistics. Returns the project object or `{error, status}`. Use before operations that need `default_branch` or `web_url` to ensure correct targeting.", props: { project_id: { type: "string", description: "Either numeric project id or the URL-encoded full path (e.g. `group%2Fsubgroup%2Frepo`).", minLength: 1 } }, req: ["project_id"] },
    { name: "boj_gitlab_create_issue", desc: "Open a new issue on a GitLab project. Side-effectful; creates a new record. Returns the created issue metadata `{iid, web_url, state, ...}` on success. Pair with follow-up comments via the GitLab GraphQL API for complex discussions.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, title: { type: "string", description: "Issue title. Keep under 80 chars.", minLength: 1 }, description: { type: "string", description: "Markdown description. Optional but recommended." } }, req: ["project_id", "title"] },
    { name: "boj_gitlab_list_issues", desc: "List issues on a GitLab project, filtered by state. Read-only; no side effects. Does NOT include merge requests (use `boj_gitlab_list_mrs` for those). Returns an array of issue objects `[{iid, title, state, author, ...}]`. Useful for project tracking and identifying open tasks.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, state: { type: "string", enum: ["opened", "closed", "all"], description: "Issue state filter (default `opened`)." } }, req: ["project_id"] },
    { name: "boj_gitlab_create_mr", desc: "Open a merge request (MR) on a GitLab project. Side-effectful; triggers CI/CD pipelines and notifies reviewers. `source` branch must already be pushed. Returns the created MR metadata `{iid, web_url, state, ...}` on success. Essential for submitting code for review and integration.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, title: { type: "string", description: "MR title (keep under 70 chars).", minLength: 1 }, source: { type: "string", description: "Source branch name.", minLength: 1 }, target: { type: "string", description: "Target branch. Defaults to the project's default branch if omitted." } }, req: ["project_id", "title", "source"] },
    { name: "boj_gitlab_list_mrs", desc: "List merge requests on a GitLab project, filtered by state. Read-only; no side effects. Returns an array of MR summary objects `[{iid, title, state, author, source_branch, target_branch, ...}]`. Useful for monitoring code review progress and integration status.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, state: { type: "string", enum: ["opened", "closed", "merged", "all"], description: "MR state filter (default `opened`)." } }, req: ["project_id"] },
    { name: "boj_gitlab_list_pipelines", desc: "List recent CI/CD pipelines for a GitLab project. Read-only; no side effects. Returns an array of pipeline objects `[{id, status, ref, sha, web_url, created_at}]`. Use after a push or MR creation to monitor automated build and test status.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." } }, req: ["project_id"] },
    { name: "boj_gitlab_setup_mirror", desc: "Configure a GitLab project to mirror its repository to an external URL. Side-effectful; subsequent pushes to GitLab will be automatically mirrored. Returns `{mirror_id, enabled:true}` on success. Confirm destination repository ownership before invoking to avoid unintentional data exposure.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, target_url: { type: "string", description: "External git URL to mirror to (e.g. `https://github.com/owner/repo.git`). Credentials can be embedded as `https://user:token@host/...`." } }, req: ["project_id", "target_url"] },
  ];
  for (const t of glTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [], additionalProperties: false } });
  }

  // Code Intelligence (CodeSeeker)
  tools.push({
    name: "boj_codeseeker",
    description: "CodeSeeker hybrid code-intelligence cartridge providing vector + BM25 + path-tier search fused via RRF, knowledge-graph traversal, and Graph-RAG capabilities. `index` is side-effectful (builds embeddings and graph context); all query operations are read-only. Returns structured results including relevant code snippets, symbol relations, or RAG-derived answers. Essential for understanding large codebases and performing semantic symbol discovery.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["index", "search", "traverse", "patterns", "graph-rag", "status", "close"], description: "CodeSeeker operation to perform: `index` builds the index; `search` runs hybrid retrieval; `traverse` walks the knowledge graph; `graph-rag` answers questions using graph context." },
        codebase_path: { type: "string", description: "Absolute filesystem path to the codebase to index or query. Must be a directory readable by the backend." },
        slot: { type: "number", minimum: 0, description: "Session slot index returned by a prior `index` operation. Required for all non-index operations." },
        query: { type: "string", description: "Search query or natural language question for Graph-RAG. Required for `search` and `graph-rag`." },
        mode: { type: "string", enum: ["hybrid", "vector", "text", "path"], description: "Search mode — `hybrid` (RRF-fused, recommended) / `vector` / `text` / `path`." },
        symbol: { type: "string", description: "Symbol name or file path to traverse from. Required for the `traverse` operation." },
        relation: { type: "string", enum: ["imports", "calls", "extends", "implements", "uses"], description: "Graph edge type to walk during traversal. Required for `traverse`." },
        depth: { type: "number", minimum: 1, maximum: 10, description: "Traversal depth for graph walks (default 2, maximum 10)." },
        limit: { type: "number", minimum: 1, maximum: 100, description: "Maximum number of results to return (default 10, maximum 100)." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // Research
  tools.push({
    name: "boj_research",
    description: "Academic literature search via the research-mcp cartridge — access papers, citations, references, and author profiles across Semantic Scholar. Read-only; no side effects. `authenticate` stores an optional API key for increased rate limits. Returns structured JSON containing paper metadata, citation graphs, and author data. Essential for grounding AI tasks in peer-reviewed literature and academic context.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-papers", "paper-details", "citations", "references", "author-search", "author-papers"], description: "Which research operation to run. Use `search-papers` for keyword-based discovery." },
        api_key: { type: "string", description: "Research-backend API key. Required for `authenticate`; optional for other operations." },
        params: { type: "object", description: "Op-specific payload: `search-papers`/`author-search` → {query, limit?}; `paper-details`/`citations`/`references` → {paper_id}; `author-papers` → {author_id, limit?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // Local coordination (localhost multi-instance AI coordination — local-coord-mcp cartridge)
  tools.push({
    name: "coord_register",
    description: "Register this AI instance as a coordination peer on the loopback coord bus (127.0.0.1:7745). Side-effectful on the bus (creates peer entry + inbox); Loopback-only for security. Returns `{peer_id, token}` where the token must be passed to all subsequent coord_* calls. Optional `context` disambiguates windows; `declared_affinities` seeds the reassignment engine; `variant` sets the model identifier in one shot (otherwise call `coord_set_variant` later). Essential for multi-agent collaboration.",
    inputSchema: {
      type: "object",
      properties: {
        client_kind: { type: "string", enum: ["claude", "gemini", "copilot", "custom", "openai", "mistral"], description: "Client family prefix for the generated peer ID (`<kind>-<4hex>[@<context>]`). Task #33 extended `openai` + `mistral`; `custom` covers anything else." },
        context: { type: "string", description: "Optional disambiguator, e.g. current repo name. Alphanumeric + hyphen/underscore, max 32 bytes. Absent = plain `<kind>-<4hex>` form.", maxLength: 32, pattern: "^[A-Za-z0-9_-]*$" },
        declared_affinities: { type: "array", items: { type: "string", maxLength: 64 }, description: "Optional self-reported strength tags (e.g. ['proof-analysis', 'supervision']). Max 256 bytes as CSV; feeds reassignment-engine comparisons (DD-28)." },
        variant: { type: "string", description: "Optional free-form model/variant label set at register time (Task #33). Alphanumeric + `.`/`-`/`_`, max 32 bytes. e.g. `opus-4.7`, `flash-2.5`, `leanstral`. Equivalent to a follow-up `coord_set_variant` call.", maxLength: 32, pattern: "^[A-Za-z0-9._-]*$" },
      },
      required: ["client_kind"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_list_peers",
    description: "List all currently-registered peers on the coord bus. Read-only; no side effects. Includes peer_id, role (master/journeyman/apprentice), current status, and capabilities. Returns an array of peer objects. Essential for peer discovery before sending messages or claiming tasks within a multi-agent cluster.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_send",
    description: "Send a free-form (untyped) message to a specific peer or broadcast to all active peers. Side-effectful; enqueues the message in the recipient's inbox. No contract validation (use `coord_send_gated` for risk-tier validation). Returns `{status:\"queued\", recipients:[...]}` on success. Use for basic communication and signaling between AI instances.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        target: { type: "string", description: "Peer ID to send to (e.g. `claude-a1b2@repo`), or `*` for broadcast to all active peers." },
        message: { type: "string", description: "Message payload — free-form text, typically a JSON A2ML envelope.", maxLength: 65536 },
      },
      required: ["token", "target", "message"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_receive",
    description: "Dequeue the next message from this peer's FIFO inbox. Side-effectful; the message is removed from the queue upon retrieval. Read-only with respect to other peers' state. Returns `{from, message, ts}` when a message is available or `{empty:true}`. Essential for driving reactive behavior in an AI coordination loop.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_claim_task",
    description: "Attempt mutex-style ownership of a named task. Side-effectful; sets this peer as the holder and applies a watchdog TTL (apprentice 30s / journeyman 5m / master none). Returns `{holder, ttl_s}` or `{error:\"already claimed\"}`. Task difficulty and confidence feed the routing engine. Essential for preventing duplicate work in multi-agent environments.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        task: { type: "string", description: "Task identifier to claim (e.g. `audit-boj-server`). Free-form, max 128 bytes.", minLength: 1, maxLength: 128 },
        confidence: { type: "number", minimum: 0, maximum: 1, description: "Self-assessed fit 0.0-1.0. Feeds the overclaim detector (DD-28)." },
        dispatch_preference: { type: "string", enum: ["deliberate", "broadcast", "auto"], description: "Routing hint (DD-30). `auto` derives from `task_difficulty`." },
        task_difficulty: { type: "string", enum: ["trivial", "routine", "challenging", "novel"], description: "Difficulty label (DD-30)." },
      },
      required: ["token", "task"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_status",
    description: "Set this peer's current work-status string, visible to all other peers via `coord_list_peers`. Side-effectful; updates own entry on the bus. Returns `{ok:true}` on success. Use for coarse-grained progress signaling (e.g., `working on task X`, `idle, awaiting review`). For claim heartbeats, prefer `coord_progress` to refresh the watchdog TTL.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        status: { type: "string", description: "Human-readable current-work status (e.g. `claim:audit-boj-server` or `idle`). Max 256 bytes.", maxLength: 256 },
      },
      required: ["token", "status"],
      additionalProperties: false,
    },
  });

  // ── Supervision tools ──────────────────────────────────────────
  tools.push({
    name: "coord_promote_to_master",
    description: "Promote this peer from journeyman/apprentice to the master role. Side-effectful; secret-gated by the server's BOJ_MASTER_TOKEN env var. Only one master exists at a time; promotion demotes the previous master and emits an audit record. Returns `{role:\"master\"}` on success or `{error, hint}`. Essential for establishing the supervisor in a multi-agent cluster.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Own session token from `coord_register`." },
        secret: { type: "string", description: "Must match the server's BOJ_MASTER_TOKEN env var (BOJ_SUPERVISOR_TOKEN read as fallback)." },
      },
      required: ["token", "secret"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_send_gated",
    description: "Send a Nickel-contract-validated envelope with a declared risk tier (0-4). Side-effectful; tier 2+ messages from apprentice peers are diverted to the supervisor quarantine for manual review. Returns `{status:\"delivered\"}` or `{status:\"quarantined\", request_id}`. Essential for safe multi-agent execution where destructive operations require human or master-AI oversight.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        target: { type: "string", description: "Peer ID to send to, or `*` for broadcast." },
        message: { type: "string", description: "Message payload — typically a JSON A2ML envelope. Validated against `coord-messages.ncl` when strict mode is enabled.", maxLength: 65536 },
        risk_tier: { type: "integer", minimum: 0, maximum: 4, description: "Self-declared risk tier 0..4. 0=observational, 1=routine-read, 2=small-write, 3=major-write, 4=destructive/irreversible." },
      },
      required: ["token", "target", "message", "risk_tier"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_review",
    description: "List all currently-quarantined envelopes awaiting a master/journeyman decision. Read-only; master role sees all, journeyman sees their own. Returns an array of request objects including sender ID, risk tier, and message preview. Essential for triaging the quarantine queue before full inspection or approval/rejection.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Master (or journeyman) session token from `coord_register`." },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_review_entry",
    description: "Read the full body and metadata of a single quarantined envelope. Read-only; master role only. Returns full message payload, sender ID, risk tier, and arrival timestamp. The entry remains in the queue until approved or rejected. Essential for evaluating the safety and intent of a high-risk operation before granting execution permission.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Master session token from `coord_register`." },
        request_id: { type: "integer", minimum: 1, description: "Quarantine entry ID returned by `coord_review`." },
      },
      required: ["token", "request_id"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_approve",
    description: "Approve a quarantined envelope, delivering the original message to its target. Side-effectful; master role only. Removes the entry from the quarantine queue and triggers delivery. Returns `{ok:true, delivered_to}` on success. Essential for granting final permission to operations that were gated due to their high risk tier.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Master session token from `coord_register`." },
        request_id: { type: "integer", minimum: 1, description: "Quarantine entry ID returned by `coord_review`." },
      },
      required: ["token", "request_id"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_reject",
    description: "Reject a quarantined envelope with a human-readable reason. Side-effectful; master role only. Removes the entry from the queue without delivery and logs the decision to the audit stream. Returns `{ok:true}` on success. Essential for refusing high-risk operations that fail safety checks or are deemed inappropriate by the master.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Master session token from `coord_register`." },
        request_id: { type: "integer", minimum: 1, description: "Quarantine entry ID returned by `coord_review`." },
        reason: { type: "string", description: "Human-readable rejection reason; logged to the audit stream. Max 512 bytes.", minLength: 1, maxLength: 512 },
      },
      required: ["token", "request_id", "reason"],
      additionalProperties: false,
    },
  });

  // ── Track record / affinity tools (Task #13) ───────────────────
  tools.push({
    name: "coord_report_outcome",
    description: "Record the outcome of a completed claim or attempted operation against an affinity tag. Side-effectful; track-record is keyed on `client_kind` (DD-29) so it survives peer restarts. Drives the `effective_affinity` calculation and reassignment engine. Returns `{ok:true}` on success. Essential for building the performance history of each model family within the coordination bus.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        tag: { type: "string", description: "Affinity tag (e.g. `proof-analysis`, `routine-edit`). Max 64 bytes.", minLength: 1, maxLength: 64 },
        outcome: { type: "string", enum: ["success", "fail"], description: "Outcome label for the attempt." },
        risk_tier: { type: "integer", minimum: 0, maximum: 4, description: "Risk tier of the completed operation (0..4)." },
        duration_ms: { type: "integer", minimum: 0, description: "Optional wall-time duration in milliseconds." },
        confidence: { type: "number", minimum: 0, maximum: 1, description: "Optional self-assessed confidence at claim time (0.0-1.0); feeds the overclaim detector." },
      },
      required: ["token", "tag", "outcome", "risk_tier"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_get_affinities",
    description: "Return the computed `effective_affinity` scores for all known (client_kind, tag) pairs. Read-only; no side effects. Scores are computed over a trailing window of the larger of the last 20 attempts or 7 days. Returns `{affinities:[...]}`. Essential for attester selection (DD-27) and reviewing reassignment suggestions before application.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  // ── Reassignment engine (Task #14) ─────────────────────────────
  tools.push({
    name: "coord_set_declared_affinities",
    description: "Update this peer's self-reported strength tags. Side-effectful; feeds the reassignment engine which compares declarations against actual performance. Tags with high `effective_affinity` but absent here trigger `promote` suggestions. Returns `{ok:true, tags:[...]}`. Essential for aligning a peer's self-reported strengths with its actual track record.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        tags: { type: "array", items: { type: "string", maxLength: 64 }, description: "Array of tag names (e.g. ['proof-analysis', 'supervision']). Max 256 bytes total when joined as CSV." },
      },
      required: ["token", "tags"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_scan_suggestions",
    description: "Trigger a pass of the reassignment scanner to compare track records against declared affinities. Side-effectful; enqueues `fyi` or `clarify` envelopes in the quarantine and emits warnings on divergence. Returns `{scanned, enqueued}`. Essential for proactive multi-agent optimization and detecting model drift or overclaiming behavior.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token (master recommended; any active peer accepted)." },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  // ── Master handoff (Task #35) ──────────────────────────────────
  tools.push({
    name: "coord_transfer_master",
    description: "Pass authority from the current master to a named successor. Side-effectful; secret-gated by BOJ_MASTER_TOKEN. Successor must be a journeyman or master; apprentices are rejected. Emits a `MASTER_HANDOFF` audit record. Returns `{ok:true, new_master:<peer_id>}` on success. Essential for live supervisor transitions without requiring a process restart.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Current master's session token from `coord_register`." },
        new_peer_id: { type: "string", description: "Successor peer ID in the form `<kind>-<4hex>[@<context>]`." },
        secret: { type: "string", description: "Must match the server's BOJ_MASTER_TOKEN env var." },
      },
      required: ["token", "new_peer_id", "secret"],
      additionalProperties: false,
    },
  });

  // ── Variant + capability advertisement (Tasks #33 + #34) ───────
  tools.push({
    name: "coord_set_variant",
    description: "Set or update this peer's free-form model/variant label. Side-effectful; variant is broadcast-visible to all other peers. Feeds cold-start routing and identification. Returns `{ok:true}` on success or `{error:\"invalid variant\"}`. Essential for identifying specific model versions (e.g. `opus-4.7`, `sonnet-4.6`) within a heterogeneous AI cluster.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        variant: {
          type: "string",
          description: "Variant label — free-form model identifier, alphanumeric + `.`/`-`/`_`, max 32 bytes. Empty string clears the field.",
          maxLength: 32,
          pattern: "^[A-Za-z0-9._-]*$",
        },
      },
      required: ["token", "variant"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_set_capabilities",
    description: "Advertise this peer's capability profile including class, tier, and prover strengths. Side-effectful; used for cold-start routing before a track record is established. Returns `{ok:true}` on success. Essential for signaling model strengths (e.g. `reasoner`, `coder`, `mathematician`) to the routing layer for optimal task assignment.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        class: {
          type: "array",
          items: { type: "string" },
          description: "Capability classes (e.g. `reasoner`, `coder`, `mathematician`, `scribe`). Joined as CSV internally; max 128 bytes.",
        },
        tier: {
          type: "integer",
          minimum: 0,
          maximum: 5,
          description: "Advertised capability tier 1..5 (0 = unset/clear). Higher tier = more capable model.",
        },
        prover_strengths: {
          type: "array",
          items: { type: "string" },
          description: "Prover/verifier tags this peer is strong with (e.g. `lean4`, `agda`, `rocq`). Joined as CSV internally; max 256 bytes.",
        },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_get_peer_capabilities",
    description: "Read another peer's advertised capability profile. Read-only; no side effects. Includes client_kind, variant, class, tier, and strengths. Returns a capability profile object or `{error:\"peer not found\"}`. Essential for selecting the most appropriate peer for a specific task during cold-start or manual assignment.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Own session token from `coord_register`." },
        peer_id: {
          type: "string",
          description: "Target peer ID in the form `<kind>-<4hex>[@<context>]`. Discover via `coord_list_peers`.",
        },
      },
      required: ["token", "peer_id"],
      additionalProperties: false,
    },
  });

  // ── Operational observability ──────────────────────────────────
  tools.push({
    name: "coord_health",
    description: "Fetch a read-only operational snapshot of the coordination bus. Read-only; no side effects. Includes peer counts, quarantine depth, active claim count, and track-record fill. Returns a status object. Essential for monitoring cluster health, smoke testing, and checking capacity before scaling up new sessions.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register` — any active peer may poll." },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_progress",
    description: "Signal activity and refresh the watchdog TTL for a held claim. Idempotent; resets the role-based deadline (30s for apprentice, 5m for journeyman). Returns `{ok:true, new_deadline_ms}` or `{error:\"not holder\"}`. Essential for preventing auto-release of long-running tasks due to TTL expiration.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        task: {
          type: "string",
          description: "Task identifier previously granted via `coord_claim_task` (must be the exact same string).",
        },
      },
      required: ["token", "task"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_sweep_watchdog",
    description: "Perform an explicit watchdog tick to release expired claims. Side-effectful; walks all active claims and auto-releases any whose holder has missed its TTL. Released claims emit audit records. Returns `{released:<count>}`. Useful for external monitoring loops or manual cleanup of stale cluster state.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register` — any active peer may invoke." },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  return tools;
}

export { buildToolList };
