// SPDX-License-Identifier: PMPL-1.0-or-later
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
    description: "Return the full manifest of a single cartridge — declared tools, input schemas, version, domain, auth model, protocols, and health endpoint. Read-only. Use after `boj_menu` to inspect a cartridge's tool surface before invoking `boj_cartridge_invoke`. Returns `{error:\"not found\", hint}` for unknown cartridge names.",
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
    description: "Generic cartridge invocation — forward a typed command to `<name>`'s REST endpoint and return its JSON response. Side-effectful: the downstream cartridge may read or mutate external state (DB writes, git ops, container starts, etc.), so treat as potentially destructive. For tier-2+ operations prefer the explicit `boj_<domain>_*` tools which declare richer input schemas and trigger the hardening gate's field validators. Returns `{error, hint}` on unreachable backend or unknown cartridge.",
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
          description: "Cartridge-specific parameter object. Shape is defined by the target cartridge's manifest — call `boj_cartridge_info` first to discover the expected keys.",
        },
      },
      required: ["name"],
      additionalProperties: false,
    },
  });

  // Cloud providers
  tools.push({
    name: "boj_cloud_verpex",
    description: "Manage Verpex (cPanel UAPI) hosting resources — domains, DNS records, email accounts, MySQL databases, SSL certificates, cron jobs, and resource metrics. `authenticate` stores cPanel credentials once; subsequent ops reuse them. `dns-add`/`dns-remove`/`email-create`/`database-create` are side-effectful; list/status/metrics ops are read-only. Returns structured JSON or `{error, hint}` on auth failure / missing required params for the chosen operation.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-domains", "dns-list", "dns-add", "dns-remove", "email-list", "email-create", "databases-list", "database-create", "ssl-status", "cron-list", "metrics"], description: "Which Verpex op to run. `authenticate` must be called first (or with a valid stored credential)." },
        hostname: { type: "string", description: "cPanel hostname for `authenticate` (e.g. `panel.example.com`). Ignored on other ops." },
        username: { type: "string", description: "cPanel username for `authenticate`. Ignored on other ops." },
        api_token: { type: "string", description: "cPanel API token for `authenticate`. Ignored on other ops." },
        domain: { type: "string", description: "Domain name, required for DNS and SSL ops." },
        params: { type: "object", description: "Op-specific payload: `dns-add` → {name, type, value, ttl?}; `email-create` → {email, password}; `database-create` → {name}; `metrics` → {window?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "boj_cloud_cloudflare",
    description: "Manage Cloudflare edge resources — Workers scripts, D1 SQLite databases, KV namespaces, R2 object buckets, and DNS zones/records. `authenticate` stores an API token once; subsequent ops reuse it. `kv-put`/`add-dns-record`/`query-d1` (for mutations) are side-effectful; list/get ops are read-only. Returns the Cloudflare API response or `{error, hint}` on auth failure or 4xx/5xx.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-workers", "get-worker", "list-d1", "query-d1", "list-kv", "kv-get", "kv-put", "list-r2", "list-dns-zones", "list-dns-records", "add-dns-record"], description: "Which Cloudflare op to run. `authenticate` must be called first (or with a valid stored token)." },
        api_token: { type: "string", description: "Cloudflare API token with scope matching the requested op. Required for `authenticate`; ignored afterwards." },
        params: { type: "object", description: "Op-specific payload: `get-worker` → {script_name}; `query-d1` → {database_id, sql, bindings?}; `kv-get`/`kv-put` → {namespace_id, key, value?}; `add-dns-record` → {zone_id, type, name, content, ttl?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "boj_cloud_vercel",
    description: "Manage Vercel projects — deployments, custom domains, environment variables, build logs, and serverless function listings. `authenticate` stores an API token once; subsequent ops reuse it. All ops here are read-only (no create/delete); use the Vercel dashboard for destructive actions. Returns the Vercel API response or `{error, hint}` on auth failure.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-projects", "get-project", "list-deployments", "get-deployment", "list-domains", "list-env-vars", "deployment-logs", "list-functions"], description: "Which Vercel op to run. `authenticate` must be called first (or with a valid stored token)." },
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
    description: "Gmail operations via the comms-mcp cartridge — send, read, search, and label management. `authenticate` exchanges an OAuth2 token once; subsequent calls reuse the stored credential. Side-effectful for `send` (delivers mail) and `labels` (mutates account state). `read` and `search` are read-only. Returns structured JSON; `{error, hint}` on auth failure or missing required params for the chosen operation.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "send", "read", "search", "labels"], description: "Which Gmail op to run. `authenticate` must be called first (or with a valid stored token)." },
        oauth_token: { type: "string", description: "OAuth2 bearer token. Required for `authenticate`; ignored on subsequent ops that reuse the stored credential." },
        params: { type: "object", description: "Op-specific payload: `send` → {to, subject, body, cc?, bcc?}; `read` → {message_id}; `search` → {query, max?}; `labels` → {action:'list'|'add'|'remove', label?, message_id?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "boj_comms_calendar",
    description: "Google Calendar operations via the comms-mcp cartridge — list upcoming events, create events, and check free/busy windows. `authenticate` exchanges an OAuth2 token once; subsequent calls reuse the stored credential. `create-event` is side-effectful; `list-events` and `free-busy` are read-only. Returns structured JSON with event arrays or availability windows; `{error, hint}` on auth failure.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-events", "create-event", "free-busy"], description: "Which Calendar op to run. `authenticate` must be called first (or with a valid stored token)." },
        oauth_token: { type: "string", description: "OAuth2 bearer token. Required for `authenticate`; ignored on subsequent ops." },
        params: { type: "object", description: "Op-specific payload: `list-events` → {calendar_id?, time_min?, time_max?, max?}; `create-event` → {calendar_id?, summary, start, end, attendees?}; `free-busy` → {calendars[], time_min, time_max}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // ML/AI
  tools.push({
    name: "boj_ml_huggingface",
    description: "Hugging Face Hub operations via the ml-mcp cartridge — search models / datasets / spaces, fetch model cards, and run hosted inference against a specific model endpoint. `authenticate` stores an HF API token once; subsequent calls reuse it. `inference` is side-effectful on the HF backend (counts against quota) but idempotent locally. List/info ops are read-only. Returns structured JSON or `{error, hint}` on rate-limit / auth failure.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-models", "model-info", "inference", "list-spaces", "list-datasets"], description: "Which HF op to run. `authenticate` must be called first unless a stored token is present." },
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
    description: "Drive the controlled Firefox session to a new URL. Side-effectful — replaces the active tab's document and resets click/type state. Waits for the `load` event before returning. Use before `boj_browser_click`/`_type`/`_read_page` when orienting to a new page. Returns `{ok, final_url, title}` or `{error, hint}` on network failure.",
    inputSchema: { type: "object", properties: { url: { type: "string", description: "Absolute URL (http/https). Relative paths rejected.", minLength: 7 } }, required: ["url"], additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_click",
    description: "Click the first element matching a CSS selector on the current page. Side-effectful — may navigate, submit forms, or trigger JS handlers. Waits for the element to be visible+enabled before clicking. Use after `boj_browser_navigate` has settled. Returns `{ok, selector}` on success or `{error:\"not found\"|\"not visible\"}`.",
    inputSchema: { type: "object", properties: { selector: { type: "string", description: "CSS selector of the target element, e.g. `button#submit`, `a[href$='.pdf']`. Must match at least one visible element.", minLength: 1 } }, required: ["selector"], additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_type",
    description: "Type text into the first input/textarea matching a CSS selector. Side-effectful — fires `input`/`change` events as each character is delivered. Does not auto-submit; pair with `boj_browser_click` on the submit button. Returns `{ok, selector}` or `{error:\"not editable\"|\"not found\"}`.",
    inputSchema: { type: "object", properties: { selector: { type: "string", description: "CSS selector of the input/textarea/contenteditable element.", minLength: 1 }, text: { type: "string", description: "Literal text to deliver. Special keys (Enter, Tab) are not interpreted — use `boj_browser_execute_js` for key events." } }, required: ["selector", "text"], additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_read_page",
    description: "Extract the visible text content of the active tab — concatenates body text, strips scripts/styles, preserves rough reading order. Read-only. Use after navigation has settled to feed page content back to the agent. Returns `{url, title, text, text_length}` capped at ~1 MB.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_screenshot",
    description: "Capture a PNG screenshot of the active tab's viewport. Read-only; returns base64-encoded image bytes under `{ok, image_base64, mime:\"image/png\"}`. Use when text extraction (`boj_browser_read_page`) is insufficient — e.g. charts, layout bugs, visual confirmation.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  });
  tools.push({
    name: "boj_browser_tabs",
    description: "Manage browser tabs — enumerate, open, or close. `list` is read-only; `create` and `close` mutate session state. Use to orchestrate multi-page workflows without clobbering an existing investigation tab. Returns `{ok, tabs:[{id, url, title, active}]}` for `list`, `{ok, tab_id}` for `create`, `{ok}` for `close`.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["list", "create", "close"], description: "Tab verb: `list` returns all open tabs, `create` opens a new tab (optionally at `url`), `close` closes the tab with `tab_id`." },
        url: { type: "string", description: "Optional initial URL for `create`. Ignored for `list`/`close`." },
        tab_id: { type: "number", description: "Tab id returned by a prior `list`. Required for `close`, ignored otherwise.", minimum: 0 },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });
  tools.push({
    name: "boj_browser_execute_js",
    description: "Run a JavaScript snippet in the active tab's page context and return the last-expression value. Side-effectful — can mutate DOM, fire events, inspect state, or return structured data. Sandboxed to the target origin (no cross-origin privileges). Use when a declarative selector-based action is insufficient (e.g. dispatching synthetic keyboard events, waiting on a promise). Returns `{ok, result}` (JSON-serialisable only) or `{error, stack}` on thrown exceptions.",
    inputSchema: { type: "object", properties: { script: { type: "string", description: "JavaScript source. The last expression's value is returned; use an IIFE for multi-statement logic. Must be JSON-serialisable; DOM nodes are stringified to their `outerHTML`.", minLength: 1 } }, required: ["script"], additionalProperties: false },
  });

  // GitHub API tools — all routed via the authenticated backend token; read-only unless noted.
  const ghTools = [
    { name: "boj_github_list_repos", desc: "List repositories owned by or accessible to the authenticated GitHub user. Read-only. Paginated; default 30, max 100 per page. Use `sort` to order by last-activity axis. Returns `[{name, full_name, private, default_branch, ...}]`.", props: { per_page: { type: "number", minimum: 1, maximum: 100, description: "Results per page (1..100, default 30)." }, sort: { type: "string", enum: ["updated", "created", "pushed", "full_name"], description: "Sort key: `updated` (metadata), `pushed` (commits), `created`, `full_name`." } } },
    { name: "boj_github_get_repo", desc: "Fetch a single repository's metadata — description, default branch, topics, visibility, stars, language breakdown. Read-only. Use before operations that need `default_branch` (e.g. `boj_github_create_pr` with `base` omitted).", props: { owner: { type: "string", description: "Repo owner login (user or org)." }, repo: { type: "string", description: "Repo name (without owner prefix)." } }, req: ["owner", "repo"] },
    { name: "boj_github_create_issue", desc: "Open a new issue on a GitHub repository. Side-effectful — creates public (or private-repo-internal) record. Returns `{number, html_url}` on success. Pair with `boj_github_comment_issue` for follow-ups.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, title: { type: "string", description: "Issue title. Keep under 80 chars.", minLength: 1 }, body: { type: "string", description: "Markdown body. Optional but recommended." }, labels: { type: "array", items: { type: "string" }, description: "Label names to attach. Labels must already exist on the repo." } }, req: ["owner", "repo", "title"] },
    { name: "boj_github_list_issues", desc: "List issues on a GitHub repository, filtered by state. Read-only. Does NOT include pull requests (use `boj_github_list_prs`). Paginated; default 30.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, state: { type: "string", enum: ["open", "closed", "all"], description: "Issue state filter (default `open`)." }, per_page: { type: "number", minimum: 1, maximum: 100, description: "Results per page (1..100)." } }, req: ["owner", "repo"] },
    { name: "boj_github_get_issue", desc: "Fetch a single issue — title, body, state, labels, assignees, comments count. Read-only. Use before `boj_github_comment_issue` to confirm the issue is still open.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, issue_number: { type: "number", minimum: 1, description: "Issue number as shown in the URL `#<n>`." } }, req: ["owner", "repo", "issue_number"] },
    { name: "boj_github_comment_issue", desc: "Post a comment on a GitHub issue. Side-effectful — visible to all watchers. Supports Markdown. Returns `{id, html_url}` on success.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, issue_number: { type: "number", minimum: 1, description: "Issue number." }, body: { type: "string", description: "Markdown comment body.", minLength: 1 } }, req: ["owner", "repo", "issue_number", "body"] },
    { name: "boj_github_create_pr", desc: "Open a pull request between two branches. Side-effectful — triggers CI and notifies watchers. `head` must already be pushed to the remote. Returns `{number, html_url}`.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, title: { type: "string", description: "PR title (keep under 70 chars).", minLength: 1 }, body: { type: "string", description: "Markdown body — summary + test plan." }, head: { type: "string", description: "Source branch (same-repo) or `owner:branch` (cross-fork)." }, base: { type: "string", description: "Target branch, usually `main`. Defaults to repo's `default_branch` when omitted." } }, req: ["owner", "repo", "title", "head"] },
    { name: "boj_github_list_prs", desc: "List pull requests on a GitHub repository, filtered by state. Read-only. Does NOT include non-PR issues (use `boj_github_list_issues` for those). Paginated by GitHub's default (30). Returns `[{number, title, state, user, head, base, html_url, ...}]`.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, state: { type: "string", enum: ["open", "closed", "all"], description: "PR state filter (default `open`)." } }, req: ["owner", "repo"] },
    { name: "boj_github_get_pr", desc: "Fetch a single PR — title, body, state, head/base refs, mergeable state, CI checks summary. Read-only. Use before `boj_github_merge_pr` to confirm CI is green and mergeable.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, pull_number: { type: "number", minimum: 1, description: "PR number as shown in the URL." } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_merge_pr", desc: "Merge a pull request. Side-effectful and hard-to-reverse — branch protection and CI status must already permit it. Default method is `merge` (merge commit); prefer `squash` for linear history. Returns `{sha, merged:true}` on success.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, pull_number: { type: "number", minimum: 1, description: "PR number." }, method: { type: "string", enum: ["merge", "squash", "rebase"], description: "Merge strategy (default `merge`). `squash` collapses all commits; `rebase` replays linearly." } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_search_code", desc: "Search code across GitHub using the Code Search API v2. Read-only. Query syntax supports `repo:`, `language:`, `path:`, `symbol:` qualifiers. Returns `{total_count, items:[{path, repository, html_url, ...}]}`. Rate-limited (30/min authenticated).", props: { query: { type: "string", description: "Code search query, e.g. `repo:hyperpolymath/boj-server \"coord_register\"`. See GitHub's Code Search syntax.", minLength: 1 } }, req: ["query"] },
    { name: "boj_github_search_issues", desc: "Search issues and PRs across GitHub. Read-only. Query syntax supports `repo:`, `is:issue|pr`, `is:open|closed`, `author:`, `label:`. Returns `{total_count, items}`.", props: { query: { type: "string", description: "Issues search query, e.g. `repo:foo/bar is:pr is:open label:security`.", minLength: 1 } }, req: ["query"] },
    { name: "boj_github_get_file", desc: "Read a file's contents from a GitHub repository at a given ref. Read-only. Decodes base64 automatically and returns `{path, content, sha, encoding:\"utf-8\"}`. For binaries the raw base64 is preserved.", props: { owner: { type: "string", description: "Repo owner login." }, repo: { type: "string", description: "Repo name." }, path: { type: "string", description: "Repo-relative path (no leading slash), e.g. `src/main.js`." }, ref: { type: "string", description: "Branch, tag, or commit SHA. Defaults to the repo's default branch." } }, req: ["owner", "repo", "path"] },
    { name: "boj_github_graphql", desc: "Execute an arbitrary GitHub GraphQL v4 query. Read-only on `query`, side-effectful on `mutation`. Use when the REST endpoints are insufficient — batching, nested fragments, custom aggregates. Returns the raw GraphQL response `{data, errors?}`.", props: { query: { type: "string", description: "GraphQL document. Supports `query` and `mutation`.", minLength: 1 }, variables: { type: "object", description: "GraphQL variables object, keyed by `$name` references inside the query." } }, req: ["query"] },
  ];
  for (const t of ghTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [], additionalProperties: false } });
  }

  // GitLab API tools — routed via authenticated backend token; read-only unless noted.
  const glTools = [
    { name: "boj_gitlab_list_projects", desc: "List projects accessible to the authenticated GitLab user (personal + group + starred). Read-only. Paginated; default 20 per page. Returns `[{id, path_with_namespace, visibility, default_branch, ...}]`.", props: { per_page: { type: "number", minimum: 1, maximum: 100, description: "Results per page (1..100, default 20)." } } },
    { name: "boj_gitlab_get_project", desc: "Fetch a single project's metadata — description, default branch, visibility, topics, statistics. Read-only. Use before operations needing `default_branch` or `web_url`.", props: { project_id: { type: "string", description: "Either numeric project id or the URL-encoded full path (e.g. `group%2Fsubgroup%2Frepo`).", minLength: 1 } }, req: ["project_id"] },
    { name: "boj_gitlab_create_issue", desc: "Open a new issue on a GitLab project. Side-effectful — creates a public (or project-private) record and notifies project watchers/subscribers. Returns `{iid, web_url}` on success. Pair with follow-up comments via the GitLab GraphQL API if richer conversation is needed.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, title: { type: "string", description: "Issue title. Keep under 80 chars.", minLength: 1 }, description: { type: "string", description: "Markdown description. Optional but recommended." } }, req: ["project_id", "title"] },
    { name: "boj_gitlab_list_issues", desc: "List issues on a GitLab project, filtered by state. Read-only. Does NOT include merge requests (use `boj_gitlab_list_mrs`).", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, state: { type: "string", enum: ["opened", "closed", "all"], description: "Issue state filter (default `opened`)." } }, req: ["project_id"] },
    { name: "boj_gitlab_create_mr", desc: "Open a merge request on a GitLab project. Side-effectful — triggers CI and notifies reviewers. `source` must already be pushed. Target defaults to the project's `default_branch` when omitted. Returns `{iid, web_url}`.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, title: { type: "string", description: "MR title (keep under 70 chars).", minLength: 1 }, source: { type: "string", description: "Source branch name.", minLength: 1 }, target: { type: "string", description: "Target branch. Defaults to the project's default branch when omitted." } }, req: ["project_id", "title", "source"] },
    { name: "boj_gitlab_list_mrs", desc: "List merge requests on a GitLab project, filtered by state. Read-only. `merged` shows landed MRs, `all` returns every state.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, state: { type: "string", enum: ["opened", "closed", "merged", "all"], description: "MR state filter (default `opened`)." } }, req: ["project_id"] },
    { name: "boj_gitlab_list_pipelines", desc: "List recent CI/CD pipelines for a GitLab project. Read-only. Returns `[{id, status, ref, sha, web_url, created_at}]`. Use after a push to monitor build status.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." } }, req: ["project_id"] },
    { name: "boj_gitlab_setup_mirror", desc: "Configure a GitLab → external git push mirror. Side-effectful and hard-to-reverse — credentials stored server-side, all subsequent pushes to the GitLab project are mirrored to `target_url`. Confirm repo ownership before invoking. Returns `{mirror_id, enabled:true}`.", props: { project_id: { type: "string", description: "Project id or URL-encoded full path." }, target_url: { type: "string", description: "External git URL to mirror to, e.g. `https://github.com/owner/repo.git`. Credentials may be embedded as `https://user:token@host/...`." } }, req: ["project_id", "target_url"] },
  ];
  for (const t of glTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [], additionalProperties: false } });
  }

  // Code Intelligence (CodeSeeker)
  tools.push({
    name: "boj_codeseeker",
    description: "CodeSeeker hybrid code-intelligence cartridge — vector + BM25 + path-tier search fused via RRF, knowledge-graph traversal (imports, calls, extends, implements, uses), auto-detected pattern retrieval, and Graph-RAG answers that combine retrieved code with graph context. Index lives in `.codeseeker/` alongside the codebase; `index` is side-effectful (writes embeddings + graph). All query ops are read-only. Returns structured hits or `{error, hint}` when the slot is closed or the index is stale.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["index", "search", "traverse", "patterns", "graph-rag", "status", "close"], description: "Op verb: `index` builds/refreshes the index; `search` runs hybrid retrieval; `traverse` walks the knowledge graph from a symbol; `patterns` returns auto-detected code conventions; `graph-rag` answers a question using graph context; `status` / `close` manage the session slot." },
        codebase_path: { type: "string", description: "Absolute path to the codebase to index or query. Required for `index`. Must be a directory the backend can read." },
        slot: { type: "number", minimum: 0, description: "Session slot index returned by `index`. Required for every non-index op." },
        query: { type: "string", description: "Search query or Graph-RAG question. Required for `search` and `graph-rag`." },
        mode: { type: "string", enum: ["hybrid", "vector", "text", "path"], description: "Search mode — `hybrid` (default, RRF-fused) / `vector` / `text` / `path`." },
        symbol: { type: "string", description: "Symbol name or file path to traverse from. Required for `traverse`." },
        relation: { type: "string", enum: ["imports", "calls", "extends", "implements", "uses"], description: "Graph edge type to walk. Required for `traverse`." },
        depth: { type: "number", minimum: 1, maximum: 10, description: "Traversal depth (default 2, max 10)." },
        limit: { type: "number", minimum: 1, maximum: 100, description: "Maximum result count (default 10, max 100)." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // Research
  tools.push({
    name: "boj_research",
    description: "Academic literature search via the research-mcp cartridge — papers, citations, references, and author discovery across Semantic Scholar (and compatible backends). Read-only. `authenticate` stores an API key once; subsequent calls reuse it. Returns structured JSON (paper metadata, citation graphs, author profiles). Use `search-papers` for keyword queries, `paper-details` for a known id, `citations`/`references` to walk the graph, `author-search`/`author-papers` for person-centric lookup.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-papers", "paper-details", "citations", "references", "author-search", "author-papers"], description: "Which research op to run. `authenticate` must be called first if no stored key is present." },
        api_key: { type: "string", description: "Research-backend API key. Required for `authenticate`; ignored on subsequent ops." },
        params: { type: "object", description: "Op-specific payload: `search-papers`/`author-search` → {query, limit?}; `paper-details`/`citations`/`references` → {paper_id}; `author-papers` → {author_id, limit?}." },
      },
      required: ["operation"],
      additionalProperties: false,
    },
  });

  // Local coordination (localhost multi-instance AI coordination — local-coord-mcp cartridge)
  tools.push({
    name: "coord_register",
    description: "Register this AI instance as a coordination peer on the loopback coord bus (127.0.0.1:7745). Returns `{peer_id, token}`; the token must be passed to every subsequent coord_* call. Side-effectful on the bus (creates peer entry + inbox). Loopback-only — never exposed beyond 127.0.0.1, so all callers are implicitly trusted. Optional `context` disambiguates multiple windows of the same client_kind; optional `declared_affinities` seeds the Task #14 reassignment engine with self-reported strengths. Returns `{error, hint}` on duplicate peer_id collision.",
    inputSchema: {
      type: "object",
      properties: {
        client_kind: { type: "string", enum: ["claude", "gemini", "copilot", "custom"], description: "Client type prefix for the generated peer ID (`<kind>-<4hex>[@<context>]`)." },
        context: { type: "string", description: "Optional disambiguator, e.g. current repo name. Alphanumeric + hyphen/underscore, max 32 bytes. Absent = plain `<kind>-<4hex>` form.", maxLength: 32, pattern: "^[A-Za-z0-9_-]*$" },
        declared_affinities: { type: "array", items: { type: "string", maxLength: 64 }, description: "Optional self-reported strength tags (e.g. ['proof-analysis', 'supervision']). Max 256 bytes as CSV; feeds reassignment-engine comparisons (DD-28)." },
      },
      required: ["client_kind"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_list_peers",
    description: "List all currently-registered peers on the coord bus — peer_id, client_kind, variant, role (master/journeyman/apprentice), current `status` string, last-heartbeat timestamp, and declared capabilities. Read-only; any active peer may call. Use for peer discovery before `coord_send`/`coord_claim_task`, or to confirm a successor is alive before `coord_transfer_master`.",
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
    description: "Send a free-form (untyped) message to a specific peer by peer_id, or broadcast to all active peers with target `*`. Side-effectful — enqueues into the recipient's inbox where it remains until the recipient calls `coord_receive`. No contract validation (use `coord_send_gated` for risk_tier-validated envelopes). Returns `{status:\"queued\", recipients:[...]}` on success.",
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
    description: "Dequeue the next message from this peer's inbox (FIFO). Side-effectful — the message is removed from the queue. Read-only with respect to other peers' state. Returns `{from, message, ts}` when a message is available or `{empty:true}` when the inbox is drained. Use in a poll loop to drive reactive peer behaviour.",
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
    description: "Attempt mutex-style ownership of a named task. If unclaimed, this peer becomes the holder and receives a watchdog TTL based on role (apprentice 30s / journeyman 5m / master none). Idempotent — repeated claims by the current holder refresh the TTL. Side-effectful on the bus. Task #15 options: `confidence` (0.0-1.0) feeds the overclaim detector (DD-28); `dispatch_preference` + `task_difficulty` drive routing policy (DD-30: broadcast trivial/routine, deliberate challenging/novel). Rejection cooldown: 5 rejects per client_kind in 10 min triggers a 30s freeze. Returns `{holder, ttl_s}` or `{error:\"already claimed\"|\"cooldown\"}`.",
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
    description: "Set this peer's current work-status string, visible to every other peer via `coord_list_peers`. Side-effectful on the bus (updates own entry only). Use for coarse-grained progress signals between peers — e.g. `working on task X`, `idle, awaiting review`. For fine-grained claim heartbeats, prefer `coord_progress` which also refreshes the watchdog TTL. Returns `{ok:true}` on success.",
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
    description: "Promote this peer from journeyman/apprentice to the master role (DD-32 rename of `coord_promote_to_supervisor` — old name still accepted for one release). Secret-gated by the server's BOJ_MASTER_TOKEN env var (fallback BOJ_SUPERVISOR_TOKEN read for one release). At most one master exists at a time; a successful promotion demotes the previous master to journeyman and emits a `MASTER_HANDOFF` audit record so durability replay reconstructs the transition. Returns `{role:\"master\"}` on success, `{error, hint}` on auth failure or when a live master already holds the seat (use `coord_transfer_master` for live handoff).",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Own session token from `coord_register`." },
        secret: { type: "string", description: "Must match the server's BOJ_MASTER_TOKEN env var (BOJ_SUPERVISOR_TOKEN is read as fallback for one release)." },
      },
      required: ["token", "secret"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_send_gated",
    description: "Send a Nickel-contract-validated envelope with a declared `risk_tier` (0-4). Tier 2+ messages from role=apprentice peers are diverted into the supervisor quarantine queue awaiting manual review via `coord_review`/`coord_approve`/`coord_reject`. Tier 0-1 or non-apprentice senders deliver immediately. Side-effectful on the bus. Returns `{status:\"delivered\"}` on immediate delivery, `{status:\"quarantined\", request_id}` when gated, or `{error:\"invalid envelope\", hint}` on Nickel contract failure (when COORD_REQUIRE_NICKEL=1).",
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
    description: "List every currently-quarantined envelope awaiting master/journeyman decision — request_id, sender peer_id, declared risk_tier, 160-char message preview, and arrival timestamp. Master role only; journeyman listings are filtered to their own up-for-review items. Read-only. Use to triage the queue before calling `coord_review_entry` for full content then `coord_approve` / `coord_reject`.",
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
    description: "Read the full body of a single quarantined envelope by request_id — full message payload, sender peer_id, risk_tier, and arrival timestamp. Master role only. Read-only; the entry stays in the queue until `coord_approve` or `coord_reject` is called. Returns `{error:\"not found\"}` for unknown ids or items already processed.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Master session token from `coord_register`." },
        request_id: { type: "integer", minimum: 1, description: "Quarantine entry id returned by `coord_review`." },
      },
      required: ["token", "request_id"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_approve",
    description: "Approve a quarantined envelope — delivers the original message to its declared target and removes the entry from the queue. Master role only; side-effectful and hard-to-reverse once delivered. Use after `coord_review_entry` has surfaced the full content. Returns `{ok:true, delivered_to}` on success or `{error:\"not found\"|\"not master\"}` on failure.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Master session token from `coord_register`." },
        request_id: { type: "integer", minimum: 1, description: "Quarantine entry id returned by `coord_review`." },
      },
      required: ["token", "request_id"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_reject",
    description: "Reject a quarantined envelope with a human-readable reason — removes the entry without delivery and logs the decision to the audit log (consumed by the reassignment engine DD-28). Master role only; irreversible. Use to refuse tier-2+ apprentice messages that shouldn't execute. Returns `{ok:true}` on success.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Master session token from `coord_register`." },
        request_id: { type: "integer", minimum: 1, description: "Quarantine entry id returned by `coord_review`." },
        reason: { type: "string", description: "Human-readable rejection reason; logged to the audit stream. Max 512 bytes.", minLength: 1, maxLength: 512 },
      },
      required: ["token", "request_id", "reason"],
      additionalProperties: false,
    },
  });

  // ── Track record / affinity tools (Task #13) ───────────────────
  tools.push({
    name: "coord_report_outcome",
    description: "Record the outcome of a completed claim or attempted op against an affinity tag. Track-record is keyed on `client_kind` (DD-29) so it survives peer restart and follows the model family rather than the ephemeral peer id. Drives `effective_affinity` and the reassignment-suggestion engine (DD-28). Optional `confidence` at claim time feeds the overclaim detector (a high-confidence fail counts more heavily). Side-effectful on the bus (appends to the track-record ring). Returns `{ok:true}`.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        tag: { type: "string", description: "Affinity tag (e.g. `proof-analysis`, `routine-edit`). Max 64 bytes.", minLength: 1, maxLength: 64 },
        outcome: { type: "string", enum: ["success", "fail"], description: "Outcome label." },
        risk_tier: { type: "integer", minimum: 0, maximum: 4, description: "Risk tier of the completed op (0..4)." },
        duration_ms: { type: "integer", minimum: 0, description: "Optional wall-time duration in ms." },
        confidence: { type: "number", minimum: 0, maximum: 1, description: "Optional self-assessed confidence at claim time (0.0-1.0); feeds the overclaim detector." },
      },
      required: ["token", "tag", "outcome", "risk_tier"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_get_affinities",
    description: "Return the per-(client_kind, tag) `effective_affinity` scores computed over the trailing window — the larger of the last 20 attempts or the last 7 days. Read-only. Used for attester selection (DD-27) and for reviewing reassignment suggestions before applying them (DD-28). Returns `{affinities:[{client_kind, tag, effective_affinity, sample_size}]}`.",
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
    description: "Replace this peer's self-reported strength tags. Feeds the reassignment engine (Task #14): tags with high `effective_affinity` but absent here trigger `promote` suggestions in the quarantine; tags declared here but with low effective_affinity trigger `remove` suggestions. Engine never auto-modifies declarations — a supervisor must approve via `coord_review`/`coord_approve` (DD-28). Side-effectful on the bus. Returns `{ok:true, tags:[...]}`.",
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
    description: "Trigger one pass of the reassignment scanner — diffs track-record aggregates vs currently-declared affinities, enqueues candidate `fyi`/`clarify` envelopes in the quarantine, and emits `overclaim`/`drift` warnings when a peer's confidence and `effective_affinity` diverge. Supervisor approves or rejects via `coord_review`+`coord_approve`/`coord_reject`; the engine never auto-modifies peer state (DD-28). Any peer may call. Returns `{scanned, enqueued}`.",
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
    description: "Live master handoff — the outgoing master passes authority to a named successor without a process restart. Secret-gated by BOJ_MASTER_TOKEN; successor must currently be role=journeyman or role=master (apprentices rejected). Emits `AUDIT(MASTER_HANDOFF)` so durability replay reconstructs the transition. Use this instead of `coord_promote_to_master` when you want a specific successor rather than the first caller to win the seat. Returns `{ok:true, new_master:<peer_id>}` on success.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Current master's session token." },
        new_peer_id: { type: "string", description: "Successor peer id in the form `<kind>-<4hex>[@<context>]` (discover via `coord_list_peers`)." },
        secret: { type: "string", description: "Must match the server's BOJ_MASTER_TOKEN env var." },
      },
      required: ["token", "new_peer_id", "secret"],
      additionalProperties: false,
    },
  });

  // ── Variant + capability advertisement (Tasks #33 + #34) ───────
  tools.push({
    name: "coord_set_variant",
    description: "Set or update this peer's free-form model/variant label (Task #33). The variant is broadcast-visible via `coord_list_peers` and feeds cold-start routing alongside `client_kind`. Alphanumeric plus `.`, `-`, `_` only; max 32 bytes; empty string clears. Examples: `opus-4.7`, `sonnet-4.6`, `haiku-4.5`, `flash-2.5`, `leanstral`. Returns `{ok:true}` on success or `{error:\"invalid variant\"}` when validation fails.",
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
    description: "Advertise this peer's capability profile for cold-start routing (Task #34). Any of `class`, `tier`, `prover_strengths` may be supplied — omitted keys are cleared. Fields are stored as CSV internally and validated for the CSV-safe alphabet. Used by the routing layer when the track-record aggregate is still thin (first few tasks). Returns `{ok:true}` on success; `{error:\"invalid capability\"}` when tier is out of range or a field overruns its byte limit.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        class: {
          type: "array",
          items: { type: "string" },
          description: "Capability classes (e.g. `reasoner`, `coder`, `mathematician`, `scribe`, `proofsmith`, `reader`, `jester`). Joined as CSV internally; max 128 bytes.",
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
          description: "Prover/verifier tags this peer is strong with (e.g. `lean4`, `agda`, `idris2`, `rocq`, `tla`). Joined as CSV internally; max 256 bytes.",
        },
      },
      required: ["token"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_get_peer_capabilities",
    description: "Read another peer's advertised capability profile (Task #34) — `client_kind`, `variant`, `class`, `tier`, `prover_strengths`. Read-only; no side effects. Used by routing to pick a peer before the track-record has enough signal (cold-start). Returns `{error:\"peer not found\"}` for unknown peer ids.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Own session token from `coord_register`." },
        peer_id: {
          type: "string",
          description: "Target peer id in the form `<kind>-<4hex>[@<context>]`. Discover via `coord_list_peers`.",
        },
      },
      required: ["token", "peer_id"],
      additionalProperties: false,
    },
  });

  // ── Operational observability ──────────────────────────────────
  tools.push({
    name: "coord_health",
    description: "Read-only operational snapshot of the coord bus — peer count (with per-kind / per-role breakdown), quarantine queue depth, active claim count, track-record ring fill, and per-kind reject counts with cooldown flags. Any active peer may poll; loopback-only so all callers are trusted. No side effects. Use for dashboards, smoke tests, and pre-claim capacity checks; call before spinning up new sessions if the queue may be saturated (MAX_QUARANTINE=32). Returns 401 on invalid token.",
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
    description: "Heartbeat for a held claim — resets the watchdog TTL (DD-20) so the server does not auto-release the claim. Role-based TTLs: apprentice 30 s, journeyman 5 min, master no watchdog (masters approve rather than execute, so their claims never expire). Long-running work should ping every (TTL/3) to leave headroom for scheduling jitter. Idempotent; returns `{ok:true, new_deadline_ms}` on success or `{error:\"not holder\"}` if a different peer now holds the claim.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from `coord_register`." },
        task: {
          type: "string",
          description: "Task identifier previously granted via `coord_claim_task` (must be the same string).",
        },
      },
      required: ["token", "task"],
      additionalProperties: false,
    },
  });

  tools.push({
    name: "coord_sweep_watchdog",
    description: "Explicit watchdog tick — walks active claims and auto-releases any whose holder has missed its role-based TTL (DD-20). The sweep also runs implicitly at the top of every `coord_claim_task`, so this tool is only needed when ops want an external polling tick (e.g. a cron-style loop from a sidecar). Any active peer may invoke; released claims emit `AUDIT(AUTO_RELEASE)` for replay. Returns `{released:<count>}`. Non-destructive when no claims are expired.",
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
