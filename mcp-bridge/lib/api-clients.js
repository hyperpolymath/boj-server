// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — API client module
//
// Direct passthrough clients for GitHub and GitLab APIs, plus
// BoJ REST API wrappers for cartridge operations.

import { isValidCartridgeName } from "./security.js";
import { warn } from "./logger.js";
import { SERVER_VERSION } from "./version.js";

const BOJ_BASE = process.env.BOJ_URL || "http://localhost:7700";
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || "";
const GITLAB_TOKEN = process.env.GITLAB_TOKEN || "";

// ===================================================================
// BoJ REST API wrappers
// ===================================================================

/** @returns {Promise<object>} */
async function fetchHealth() {
  try {
    const res = await fetch(`${BOJ_BASE}/health`);
    return await res.json();
  } catch {
    return { status: "offline", message: "BoJ REST API not reachable. Start the server with: systemctl --user start boj-server" };
  }
}

/** @returns {Promise<object>} */
async function fetchMenu() {
  try {
    const res = await fetch(`${BOJ_BASE}/menu`);
    return await res.json();
  } catch {
    warn("BoJ REST API unreachable, using offline menu");
    const { OFFLINE_MENU } = await import("./offline-menu.js");
    return OFFLINE_MENU;
  }
}

/** @returns {Promise<object>} */
async function fetchCartridges() {
  try {
    const res = await fetch(`${BOJ_BASE}/cartridges`);
    return await res.json();
  } catch {
    const { OFFLINE_MENU } = await import("./offline-menu.js");
    return {
      note: "Offline mode — cartridge matrix available when BoJ REST API is running",
      cartridges: Object.keys(
        OFFLINE_MENU.tier_teranga
          .concat(OFFLINE_MENU.tier_shield)
          .reduce((acc, c) => { acc[c.name] = c.domain; return acc; }, {})
      ),
    };
  }
}

/**
 * @param {string} name
 * @param {object} [params]
 * @returns {Promise<object>}
 */
async function invokeCartridge(name, params) {
  if (!isValidCartridgeName(name)) {
    return { error: `Invalid cartridge name: ${name}` };
  }
  try {
    const res = await fetch(`${BOJ_BASE}/cartridge/${encodeURIComponent(name)}/invoke`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params || {}),
    });
    return await res.json();
  } catch {
    return { error: "BoJ REST API not reachable. Invocation requires a running server.", cartridge: name, hint: "Start with: systemctl --user start boj-server" };
  }
}

/**
 * @param {string} name
 * @returns {Promise<object>}
 */
async function fetchCartridgeInfo(name) {
  if (!isValidCartridgeName(name)) {
    return { error: `Invalid cartridge name: ${name}` };
  }
  try {
    const res = await fetch(`${BOJ_BASE}/cartridge/${encodeURIComponent(name)}`);
    return await res.json();
  } catch {
    const { OFFLINE_MENU } = await import("./offline-menu.js");
    const all = OFFLINE_MENU.tier_teranga.concat(OFFLINE_MENU.tier_shield);
    const found = all.find(c => c.name === name);
    return found || { error: `Unknown cartridge: ${name}` };
  }
}

// ===================================================================
// GitHub API
// ===================================================================

/**
 * @param {string} method
 * @param {string} path
 * @param {object} [body]
 * @returns {Promise<object>}
 */
async function githubApiCall(method, path, body) {
  if (!GITHUB_TOKEN) {
    return { error: "GITHUB_TOKEN not set. Store in vault-mcp or export to environment." };
  }
  try {
    const url = `https://api.github.com${path}`;
    const opts = {
      method,
      headers: {
        "Authorization": `Bearer ${GITHUB_TOKEN}`,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": `boj-server/${SERVER_VERSION}`,
      },
    };
    if (body && method !== "GET") {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(url, opts);
    const data = await res.json();
    const rateLimit = {
      remaining: res.headers.get("x-ratelimit-remaining"),
      reset: res.headers.get("x-ratelimit-reset"),
      limit: res.headers.get("x-ratelimit-limit"),
    };
    return { status: res.status, data, rateLimit };
  } catch (err) {
    return { error: `GitHub API error: ${err.message}` };
  }
}

/**
 * @param {string} query
 * @param {object} [variables]
 * @returns {Promise<object>}
 */
async function githubGraphQL(query, variables) {
  if (!GITHUB_TOKEN) {
    return { error: "GITHUB_TOKEN not set." };
  }
  try {
    const res = await fetch("https://api.github.com/graphql", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${GITHUB_TOKEN}`,
        "Content-Type": "application/json",
        "User-Agent": `boj-server/${SERVER_VERSION}`,
      },
      body: JSON.stringify({ query, variables: variables || {} }),
    });
    return await res.json();
  } catch (err) {
    return { error: `GitHub GraphQL error: ${err.message}` };
  }
}

/**
 * Route GitHub tool calls to real API.
 * @param {string} toolName
 * @param {Record<string, any>} args
 * @returns {Promise<object>}
 */
async function handleGitHubTool(toolName, args) {
  switch (toolName) {
    case "boj_github_list_repos":
      return githubApiCall("GET", `/user/repos?per_page=${args.per_page || 30}&sort=${args.sort || "updated"}`);
    case "boj_github_get_repo":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}`);
    case "boj_github_create_issue":
      return githubApiCall("POST", `/repos/${args.owner}/${args.repo}/issues`, { title: args.title, body: args.body, labels: args.labels });
    case "boj_github_list_issues":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/issues?state=${args.state || "open"}&per_page=${args.per_page || 30}`);
    case "boj_github_get_issue":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/issues/${args.issue_number}`);
    case "boj_github_comment_issue":
      return githubApiCall("POST", `/repos/${args.owner}/${args.repo}/issues/${args.issue_number}/comments`, { body: args.body });
    case "boj_github_create_pr":
      return githubApiCall("POST", `/repos/${args.owner}/${args.repo}/pulls`, { title: args.title, body: args.body, head: args.head, base: args.base || "main" });
    case "boj_github_list_prs":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/pulls?state=${args.state || "open"}`);
    case "boj_github_get_pr":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/pulls/${args.pull_number}`);
    case "boj_github_merge_pr":
      return githubApiCall("PUT", `/repos/${args.owner}/${args.repo}/pulls/${args.pull_number}/merge`, { merge_method: args.method || "merge" });
    case "boj_github_search_code":
      return githubApiCall("GET", `/search/code?q=${encodeURIComponent(args.query)}`);
    case "boj_github_search_issues":
      return githubApiCall("GET", `/search/issues?q=${encodeURIComponent(args.query)}`);
    case "boj_github_get_file":
      return githubApiCall("GET", `/repos/${args.owner}/${args.repo}/contents/${args.path}?ref=${args.ref || "main"}`);
    case "boj_github_graphql":
      return githubGraphQL(args.query, args.variables);
    default:
      return { error: `Unknown GitHub tool: ${toolName}` };
  }
}

// ===================================================================
// GitLab API
// ===================================================================

/**
 * @param {string} method
 * @param {string} path
 * @param {object} [body]
 * @returns {Promise<object>}
 */
async function gitlabApiCall(method, path, body) {
  if (!GITLAB_TOKEN) {
    return { error: "GITLAB_TOKEN not set." };
  }
  const baseUrl = process.env.GITLAB_URL || "https://gitlab.com";
  try {
    const url = `${baseUrl}/api/v4${path}`;
    const opts = {
      method,
      headers: {
        "PRIVATE-TOKEN": GITLAB_TOKEN,
        "Accept": "application/json",
        "User-Agent": `boj-server/${SERVER_VERSION}`,
      },
    };
    if (body && method !== "GET") {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(url, opts);
    const data = await res.json();
    return { status: res.status, data };
  } catch (err) {
    return { error: `GitLab API error: ${err.message}` };
  }
}

/**
 * Route GitLab tool calls to real API.
 * @param {string} toolName
 * @param {Record<string, any>} args
 * @returns {Promise<object>}
 */
async function handleGitLabTool(toolName, args) {
  switch (toolName) {
    case "boj_gitlab_list_projects":
      return gitlabApiCall("GET", `/projects?owned=true&per_page=${args.per_page || 20}`);
    case "boj_gitlab_get_project":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}`);
    case "boj_gitlab_create_issue":
      return gitlabApiCall("POST", `/projects/${encodeURIComponent(args.project_id)}/issues`, { title: args.title, description: args.description });
    case "boj_gitlab_list_issues":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}/issues?state=${args.state || "opened"}`);
    case "boj_gitlab_create_mr":
      return gitlabApiCall("POST", `/projects/${encodeURIComponent(args.project_id)}/merge_requests`, { title: args.title, source_branch: args.source, target_branch: args.target || "main" });
    case "boj_gitlab_list_mrs":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}/merge_requests?state=${args.state || "opened"}`);
    case "boj_gitlab_list_pipelines":
      return gitlabApiCall("GET", `/projects/${encodeURIComponent(args.project_id)}/pipelines`);
    case "boj_gitlab_setup_mirror":
      return gitlabApiCall("POST", `/projects/${encodeURIComponent(args.project_id)}/remote_mirrors`, { url: args.target_url, enabled: true });
    default:
      return { error: `Unknown GitLab tool: ${toolName}` };
  }
}

export {
  BOJ_BASE,
  fetchCartridgeInfo,
  fetchCartridges,
  fetchHealth,
  fetchMenu,
  handleGitHubTool,
  handleGitLabTool,
  invokeCartridge,
};
