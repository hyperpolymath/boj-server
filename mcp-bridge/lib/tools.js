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
    description: "Check BoJ server health status",
    inputSchema: { type: "object", properties: {} },
  });

  tools.push({
    name: "boj_menu",
    description: "List all BoJ cartridges with their domains, protocols, tiers, and availability",
    inputSchema: { type: "object", properties: {} },
  });

  tools.push({
    name: "boj_cartridges",
    description: "Show the BoJ cartridge matrix — protocol x domain grid showing which cartridges serve which protocol/domain combinations",
    inputSchema: { type: "object", properties: {} },
  });

  tools.push({
    name: "boj_cartridge_info",
    description: "Get detailed information about a specific BoJ cartridge",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Cartridge name (e.g. database-mcp, container-mcp, git-mcp)" },
      },
      required: ["name"],
    },
  });

  tools.push({
    name: "boj_cartridge_invoke",
    description: "Invoke a BoJ cartridge operation. Send a command to a specific cartridge for execution.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Cartridge name (e.g. database-mcp, git-mcp)" },
        params: { type: "object", description: "Parameters to pass to the cartridge invocation" },
      },
      required: ["name"],
    },
  });

  // Cloud providers
  tools.push({
    name: "boj_cloud_verpex",
    description: "Manage Verpex hosting via cPanel UAPI — domains, DNS, email, databases, SSL, cron, metrics",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-domains", "dns-list", "dns-add", "dns-remove", "email-list", "email-create", "databases-list", "database-create", "ssl-status", "cron-list", "metrics"], description: "The Verpex operation to perform" },
        hostname: { type: "string", description: "cPanel hostname (for authenticate)" },
        username: { type: "string", description: "cPanel username (for authenticate)" },
        api_token: { type: "string", description: "cPanel API token (for authenticate)" },
        domain: { type: "string", description: "Domain name (for DNS, SSL operations)" },
        params: { type: "object", description: "Additional operation parameters" },
      },
      required: ["operation"],
    },
  });

  tools.push({
    name: "boj_cloud_cloudflare",
    description: "Manage Cloudflare resources — Workers, D1 databases, KV namespaces, R2 buckets, DNS zones/records",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-workers", "get-worker", "list-d1", "query-d1", "list-kv", "kv-get", "kv-put", "list-r2", "list-dns-zones", "list-dns-records", "add-dns-record"], description: "The Cloudflare operation" },
        api_token: { type: "string", description: "Cloudflare API token (for authenticate)" },
        params: { type: "object", description: "Operation parameters" },
      },
      required: ["operation"],
    },
  });

  tools.push({
    name: "boj_cloud_vercel",
    description: "Manage Vercel projects — deployments, domains, environment variables, logs, serverless functions",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-projects", "get-project", "list-deployments", "get-deployment", "list-domains", "list-env-vars", "deployment-logs", "list-functions"], description: "The Vercel operation" },
        api_token: { type: "string", description: "Vercel API token (for authenticate)" },
        params: { type: "object", description: "Operation parameters" },
      },
      required: ["operation"],
    },
  });

  // Communications
  tools.push({
    name: "boj_comms_gmail",
    description: "Gmail operations — send, read, search emails, manage labels",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "send", "read", "search", "labels"], description: "Gmail operation" },
        oauth_token: { type: "string", description: "OAuth2 token (for authenticate)" },
        params: { type: "object", description: "Operation parameters (to, subject, body for send; query for search; message_id for read)" },
      },
      required: ["operation"],
    },
  });

  tools.push({
    name: "boj_comms_calendar",
    description: "Google Calendar operations — list events, create events, check availability",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "list-events", "create-event", "free-busy"], description: "Calendar operation" },
        oauth_token: { type: "string", description: "OAuth2 token (for authenticate)" },
        params: { type: "object", description: "Operation parameters" },
      },
      required: ["operation"],
    },
  });

  // ML/AI
  tools.push({
    name: "boj_ml_huggingface",
    description: "Hugging Face operations — search models, model info, inference, spaces, datasets",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-models", "model-info", "inference", "list-spaces", "list-datasets"], description: "HuggingFace operation" },
        api_token: { type: "string", description: "HF API token (for authenticate)" },
        params: { type: "object", description: "Operation parameters (query for search, model_id for info/inference)" },
      },
      required: ["operation"],
    },
  });

  // Browser automation
  tools.push({
    name: "boj_browser_navigate",
    description: "Navigate Firefox to a URL",
    inputSchema: { type: "object", properties: { url: { type: "string", description: "URL to navigate to" } }, required: ["url"] },
  });
  tools.push({
    name: "boj_browser_click",
    description: "Click an element on the page by CSS selector",
    inputSchema: { type: "object", properties: { selector: { type: "string", description: "CSS selector of the element to click" } }, required: ["selector"] },
  });
  tools.push({
    name: "boj_browser_type",
    description: "Type text into an element on the page",
    inputSchema: { type: "object", properties: { selector: { type: "string", description: "CSS selector of the input element" }, text: { type: "string", description: "Text to type" } }, required: ["selector", "text"] },
  });
  tools.push({
    name: "boj_browser_read_page",
    description: "Read the text content of the current page",
    inputSchema: { type: "object", properties: {} },
  });
  tools.push({
    name: "boj_browser_screenshot",
    description: "Take a screenshot of the current page",
    inputSchema: { type: "object", properties: {} },
  });
  tools.push({
    name: "boj_browser_tabs",
    description: "List, create, or close browser tabs",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["list", "create", "close"], description: "Tab operation" },
        url: { type: "string", description: "URL for new tab (create only)" },
        tab_id: { type: "number", description: "Tab ID (close only)" },
      },
      required: ["operation"],
    },
  });
  tools.push({
    name: "boj_browser_execute_js",
    description: "Execute JavaScript in the current page context",
    inputSchema: { type: "object", properties: { script: { type: "string", description: "JavaScript code to execute" } }, required: ["script"] },
  });

  // GitHub API tools
  const ghTools = [
    { name: "boj_github_list_repos", desc: "List your GitHub repositories", props: { per_page: { type: "number" }, sort: { type: "string", enum: ["updated", "created", "pushed", "full_name"] } } },
    { name: "boj_github_get_repo", desc: "Get a GitHub repository", props: { owner: { type: "string" }, repo: { type: "string" } }, req: ["owner", "repo"] },
    { name: "boj_github_create_issue", desc: "Create an issue on a GitHub repo", props: { owner: { type: "string" }, repo: { type: "string" }, title: { type: "string" }, body: { type: "string" }, labels: { type: "array", items: { type: "string" } } }, req: ["owner", "repo", "title"] },
    { name: "boj_github_list_issues", desc: "List issues on a GitHub repo", props: { owner: { type: "string" }, repo: { type: "string" }, state: { type: "string", enum: ["open", "closed", "all"] }, per_page: { type: "number" } }, req: ["owner", "repo"] },
    { name: "boj_github_get_issue", desc: "Get a specific issue", props: { owner: { type: "string" }, repo: { type: "string" }, issue_number: { type: "number" } }, req: ["owner", "repo", "issue_number"] },
    { name: "boj_github_comment_issue", desc: "Comment on an issue", props: { owner: { type: "string" }, repo: { type: "string" }, issue_number: { type: "number" }, body: { type: "string" } }, req: ["owner", "repo", "issue_number", "body"] },
    { name: "boj_github_create_pr", desc: "Create a pull request", props: { owner: { type: "string" }, repo: { type: "string" }, title: { type: "string" }, body: { type: "string" }, head: { type: "string" }, base: { type: "string" } }, req: ["owner", "repo", "title", "head"] },
    { name: "boj_github_list_prs", desc: "List pull requests", props: { owner: { type: "string" }, repo: { type: "string" }, state: { type: "string", enum: ["open", "closed", "all"] } }, req: ["owner", "repo"] },
    { name: "boj_github_get_pr", desc: "Get a specific pull request", props: { owner: { type: "string" }, repo: { type: "string" }, pull_number: { type: "number" } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_merge_pr", desc: "Merge a pull request", props: { owner: { type: "string" }, repo: { type: "string" }, pull_number: { type: "number" }, method: { type: "string", enum: ["merge", "squash", "rebase"] } }, req: ["owner", "repo", "pull_number"] },
    { name: "boj_github_search_code", desc: "Search code on GitHub", props: { query: { type: "string" } }, req: ["query"] },
    { name: "boj_github_search_issues", desc: "Search issues and PRs on GitHub", props: { query: { type: "string" } }, req: ["query"] },
    { name: "boj_github_get_file", desc: "Get file contents from a repo", props: { owner: { type: "string" }, repo: { type: "string" }, path: { type: "string" }, ref: { type: "string" } }, req: ["owner", "repo", "path"] },
    { name: "boj_github_graphql", desc: "Execute a GitHub GraphQL query", props: { query: { type: "string" }, variables: { type: "object" } }, req: ["query"] },
  ];
  for (const t of ghTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [] } });
  }

  // GitLab API tools
  const glTools = [
    { name: "boj_gitlab_list_projects", desc: "List your GitLab projects", props: { per_page: { type: "number" } } },
    { name: "boj_gitlab_get_project", desc: "Get a GitLab project", props: { project_id: { type: "string", description: "Project ID or URL-encoded path" } }, req: ["project_id"] },
    { name: "boj_gitlab_create_issue", desc: "Create a GitLab issue", props: { project_id: { type: "string" }, title: { type: "string" }, description: { type: "string" } }, req: ["project_id", "title"] },
    { name: "boj_gitlab_list_issues", desc: "List GitLab project issues", props: { project_id: { type: "string" }, state: { type: "string", enum: ["opened", "closed", "all"] } }, req: ["project_id"] },
    { name: "boj_gitlab_create_mr", desc: "Create a merge request", props: { project_id: { type: "string" }, title: { type: "string" }, source: { type: "string" }, target: { type: "string" } }, req: ["project_id", "title", "source"] },
    { name: "boj_gitlab_list_mrs", desc: "List merge requests", props: { project_id: { type: "string" }, state: { type: "string", enum: ["opened", "closed", "merged", "all"] } }, req: ["project_id"] },
    { name: "boj_gitlab_list_pipelines", desc: "List CI/CD pipelines", props: { project_id: { type: "string" } }, req: ["project_id"] },
    { name: "boj_gitlab_setup_mirror", desc: "Set up a push mirror", props: { project_id: { type: "string" }, target_url: { type: "string" } }, req: ["project_id", "target_url"] },
  ];
  for (const t of glTools) {
    tools.push({ name: t.name, description: t.desc, inputSchema: { type: "object", properties: t.props, required: t.req || [] } });
  }

  // Code Intelligence (CodeSeeker)
  tools.push({
    name: "boj_codeseeker",
    description: "CodeSeeker code intelligence — hybrid search (vector + text + path with RRF), knowledge graph traversal (imports, calls, extends, implements), auto-detected pattern retrieval, and Graph RAG context. All data stored locally in .codeseeker/",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["index", "search", "traverse", "patterns", "graph-rag", "status", "close"], description: "Operation: index (build/refresh index), search (hybrid search), traverse (graph traversal from a symbol), patterns (auto-detected conventions), graph-rag (RAG with graph context), status (session state), close (close session)" },
        codebase_path: { type: "string", description: "Absolute path to the codebase to index or query (required for index)" },
        slot: { type: "number", description: "Session slot index returned by the index operation (required for search/traverse/patterns/graph-rag/status/close)" },
        query: { type: "string", description: "Search query or Graph RAG question (required for search and graph-rag)" },
        mode: { type: "string", enum: ["hybrid", "vector", "text", "path"], description: "Search mode (default: hybrid)" },
        symbol: { type: "string", description: "Symbol or file path to traverse from (required for traverse)" },
        relation: { type: "string", enum: ["imports", "calls", "extends", "implements", "uses"], description: "Graph relation type to traverse (required for traverse)" },
        depth: { type: "number", description: "Traversal depth (default: 2)" },
        limit: { type: "number", description: "Maximum number of search results (default: 10)" },
      },
      required: ["operation"],
    },
  });

  // Research
  tools.push({
    name: "boj_research",
    description: "Academic research — search papers, citations, references, authors",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["authenticate", "search-papers", "paper-details", "citations", "references", "author-search", "author-papers"], description: "Research operation" },
        api_key: { type: "string", description: "API key (for authenticate)" },
        params: { type: "object", description: "Operation parameters (query for search, paper_id for details/citations, author_id for author-papers)" },
      },
      required: ["operation"],
    },
  });

  // Local coordination (localhost multi-instance AI coordination — local-coord-mcp cartridge)
  tools.push({
    name: "coord_register",
    description: "Register this AI instance as a coordination peer on localhost. Returns a peer ID and a session token for all subsequent calls. Loopback-only, never exposed beyond 127.0.0.1. Pass the optional `context` (repo name, tty tag, or similar) to disambiguate multiple windows of the same client_kind on one machine — peer_id becomes <kind>-<4hex>@<context> rather than just <kind>-<4hex>.",
    inputSchema: {
      type: "object",
      properties: {
        client_kind: { type: "string", enum: ["claude", "gemini", "copilot", "custom"], description: "Client type prefix for the peer ID" },
        context: { type: "string", description: "Optional disambiguator, e.g. current repo name. Alphanumeric + hyphen/underscore, max 32 bytes. Absent = old <kind>-<4hex> form.", maxLength: 32 },
      },
      required: ["client_kind"],
    },
  });

  tools.push({
    name: "coord_list_peers",
    description: "List all active AI instances registered on this machine — their peer IDs, client kinds, states, and current status.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
      },
      required: ["token"],
    },
  });

  tools.push({
    name: "coord_send",
    description: "Send a message to a specific peer (by peer ID) or broadcast to all peers (target '*'). Messages are queued in recipient inboxes.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
        target: { type: "string", description: "Peer ID to send to, or '*' for broadcast" },
        message: { type: "string", description: "Message content" },
      },
      required: ["token", "target", "message"],
    },
  });

  tools.push({
    name: "coord_receive",
    description: "Receive the next message from this peer's inbox. Returns the message content and sender, or indicates empty inbox.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
      },
      required: ["token"],
    },
  });

  tools.push({
    name: "coord_claim_task",
    description: "Attempt to claim a task (mutex-style). If the task is unclaimed, this peer becomes the holder. Idempotent if already held by caller. Task #15: optional confidence (0.0-1.0), dispatch_preference (deliberate/broadcast/auto), task_difficulty (trivial/routine/challenging/novel). Default policy (DD-30): broadcast trivial+routine, deliberate challenging+novel. Rejection cooldown: 5 claim rejections per client_kind in 10 min => 30s freeze before next attempt.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
        task: { type: "string", description: "Task identifier to claim (e.g. 'audit-boj-server')" },
        confidence: { type: "number", minimum: 0, maximum: 1, description: "Self-assessed fit 0.0-1.0 (feeds overclaim detector DD-28)" },
        dispatch_preference: { type: "string", enum: ["deliberate", "broadcast", "auto"], description: "Routing hint (DD-30). auto = derive from difficulty" },
        task_difficulty: { type: "string", enum: ["trivial", "routine", "challenging", "novel"], description: "Difficulty level (DD-30)" },
      },
      required: ["token", "task"],
    },
  });

  tools.push({
    name: "coord_status",
    description: "Set this peer's current work status, visible to other peers via coord_list_peers.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
        status: { type: "string", description: "Current work status description" },
      },
      required: ["token", "status"],
    },
  });

  // ── Supervision tools ──────────────────────────────────────────
  tools.push({
    name: "coord_promote_to_supervisor",
    description: "Promote this peer to the supervisor role. Requires BOJ_SUPERVISOR_TOKEN to be set on the server and presented secret to match. At most one supervisor at a time.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Own session token from coord_register" },
        secret: { type: "string", description: "Must match BOJ_SUPERVISOR_TOKEN env var on the server" },
      },
      required: ["token", "secret"],
    },
  });

  tools.push({
    name: "coord_send_gated",
    description: "Send a message with a declared risk_tier (0-4). Tier 2+ from role=supervised peers is quarantined for supervisor review. Returns status:quarantined + request_id when gated, status:delivered otherwise.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
        target: { type: "string", description: "Peer ID to send to, or '*' for broadcast" },
        message: { type: "string", description: "Message content (typically an A2ML envelope)" },
        risk_tier: { type: "integer", minimum: 0, maximum: 4, description: "Declared risk tier 0-4" },
      },
      required: ["token", "target", "message", "risk_tier"],
    },
  });

  tools.push({
    name: "coord_review",
    description: "List all quarantined messages awaiting supervisor decision. Supervisor role only. Returns entries with request_id + preview.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Supervisor session token" },
      },
      required: ["token"],
    },
  });

  tools.push({
    name: "coord_review_entry",
    description: "Read the full body of a specific quarantined entry by request_id. Supervisor role only.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Supervisor session token" },
        request_id: { type: "integer", description: "Request ID from coord_review" },
      },
      required: ["token", "request_id"],
    },
  });

  tools.push({
    name: "coord_approve",
    description: "Approve a quarantined message — delivers to target, removes from queue. Supervisor role only.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Supervisor session token" },
        request_id: { type: "integer", description: "Request ID to approve" },
      },
      required: ["token", "request_id"],
    },
  });

  tools.push({
    name: "coord_reject",
    description: "Reject a quarantined message with a reason — removes without delivery. Supervisor role only. Reason logged.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Supervisor session token" },
        request_id: { type: "integer", description: "Request ID to reject" },
        reason: { type: "string", description: "Reason for rejection" },
      },
      required: ["token", "request_id", "reason"],
    },
  });

  // ── Track record / affinity tools (Task #13) ───────────────────
  tools.push({
    name: "coord_report_outcome",
    description: "Report outcome of a claim or attempted op against an affinity tag. Track record is keyed on client_kind (DD-29) so it survives peer restart. Drives effective_affinity + reassignment suggestions.",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
        tag: { type: "string", description: "Affinity tag (e.g. 'proof-analysis', 'routine-edit'). Max 64 bytes.", maxLength: 64 },
        outcome: { type: "string", enum: ["success", "fail"], description: "'success' or 'fail'" },
        risk_tier: { type: "integer", minimum: 0, maximum: 4, description: "Risk tier of the op" },
        duration_ms: { type: "integer", minimum: 0, description: "Wall-time duration in ms (optional)" },
      },
      required: ["token", "tag", "outcome", "risk_tier"],
    },
  });

  tools.push({
    name: "coord_get_affinities",
    description: "Return per-(client_kind, tag) effective_affinity over the last 20 attempts OR last 7 days (whichever is larger). Use for attester selection (DD-27) and reassignment-suggestion review (DD-28).",
    inputSchema: {
      type: "object",
      properties: {
        token: { type: "string", description: "Session token from coord_register" },
      },
      required: ["token"],
    },
  });

  return tools;
}

export { buildToolList };
