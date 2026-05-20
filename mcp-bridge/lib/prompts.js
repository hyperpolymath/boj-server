// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP prompts surface
//
// Implements MCP prompts/list + prompts/get. Each template encodes a
// high-frequency BoJ workflow as a structured set of messages that
// guides the connected LLM through a multi-cartridge composition.
//
// Templates name the tools they expect to call so the LLM has explicit
// guidance, not just free-form orchestration.

const PROMPT_DEFS = [
  {
    name: "audit-repo",
    description: "Run a security + quality + compliance audit on a GitHub or GitLab repository, composing hypatia-mcp, panic-attack-mcp, and secrets-mcp findings into a single report.",
    arguments: [
      { name: "owner", description: "Repo owner / org login", required: true },
      { name: "repo", description: "Repo name (no owner prefix)", required: true },
      { name: "forge", description: "github | gitlab (default github)", required: false },
    ],
  },
  {
    name: "convene-cluster",
    description: "Stand up a multi-agent BoJ cluster: register this peer, discover others, claim a task, broadcast readiness, and start the supervision loop.",
    arguments: [
      { name: "task_topic", description: "Free-form description of the work to coordinate on", required: true },
      { name: "role_hint", description: "apprentice | journeyman | master (default journeyman)", required: false },
      { name: "variant", description: "Model variant label (e.g. opus-4.7, sonnet-4.6, flash-2.5)", required: false },
    ],
  },
  {
    name: "deploy-with-dns-ssl",
    description: "Deploy an application to a cloud provider with custom-domain DNS + SSL wired through Cloudflare. Composes the chosen provider's cartridge with cloudflare-mcp.",
    arguments: [
      { name: "app_name", description: "Application identifier on the deploy target", required: true },
      { name: "domain", description: "Custom domain (e.g. app.example.com)", required: true },
      { name: "provider", description: "fly | render | railway | vercel (default fly)", required: false },
    ],
  },
  {
    name: "summarize-channel",
    description: "Pull recent history from a messaging channel and produce a concise summary of decisions, action items, and unresolved threads.",
    arguments: [
      { name: "platform", description: "slack | discord | matrix | telegram", required: true },
      { name: "channel_id", description: "Channel/room identifier", required: true },
      { name: "hours", description: "Lookback window in hours (default 24)", required: false },
    ],
  },
  {
    name: "triage-issues",
    description: "Triage open issues on a repository: enumerate, classify by severity/effort/staleness, propose labels, and surface the top N for action.",
    arguments: [
      { name: "owner", description: "Repo owner / org login", required: true },
      { name: "repo", description: "Repo name", required: true },
      { name: "forge", description: "github | gitlab (default github)", required: false },
      { name: "top_n", description: "How many issues to surface (default 10)", required: false },
    ],
  },
  {
    name: "proof-status",
    description: "Report the formal-verification posture of one cartridge or the whole BoJ ABI — proof obligations, discharge state, believe_me-axiom count, and outstanding work.",
    arguments: [
      { name: "cartridge", description: "Cartridge name (omit for whole-server view)", required: false },
    ],
  },
];

function listPrompts() {
  return PROMPT_DEFS.map((p) => ({ ...p }));
}

function buildAuditRepo(args) {
  const forge = args.forge ?? "github";
  const owner = args.owner;
  const repo = args.repo;
  const text = `You are auditing the ${forge} repository \`${owner}/${repo}\` for security, quality, and compliance issues. Compose findings from three cartridges into a single report.

Step 1 — Fetch repo metadata via \`boj_${forge}_get_repo\` (owner=${owner}, repo=${repo}) to confirm visibility, default branch, and topics.

Step 2 — Run the Hypatia neurosymbolic scanner via \`boj_cartridge_invoke\` against \`hypatia-mcp\` to enumerate security/quality/compliance issues for this repo.

Step 3 — Run \`boj_cartridge_invoke\` against \`panic-attack-mcp\` to surface dangerous patterns, banned constructs, and proof drift.

Step 4 — Run \`boj_cartridge_invoke\` against \`secrets-mcp\` to verify no committed secrets are detectable.

Step 5 — Produce a single Markdown report with three sections (Security / Quality / Compliance), each listing findings with severity + file path + recommended remediation. If any tool returns an error or unavailable hint, surface that clearly and continue with the other tools.

Do not modify the repo. Read-only operations only.`;
  return {
    description: `Audit ${owner}/${repo} via hypatia + panic-attack + secrets`,
    messages: [
      { role: "user", content: { type: "text", text } },
    ],
  };
}

function buildConveneCluster(args) {
  const task = args.task_topic;
  const role = args.role_hint ?? "journeyman";
  const variant = args.variant ?? "unset";
  const text = `You are joining a BoJ multi-agent coordination cluster on the local coord bus (127.0.0.1:7745) to work on: ${task}

Step 1 — Register as a peer via \`coord_register\` with client_kind matching your model family (claude/gemini/copilot/openai/mistral/custom), variant="${variant}", and declared_affinities matching this task. Capture the returned token.

Step 2 — Call \`coord_list_peers\` to see who else is already on the bus.

Step 3 — Call \`coord_set_capabilities\` to advertise your class/tier/prover_strengths so cold-start routing can find you.

Step 4 — Call \`coord_claim_task\` for the topic above with confidence∈[0,1] and an honest task_difficulty (trivial/routine/challenging/novel). Watchdog TTL will be applied based on your role (apprentice 30s / journeyman 5m / master none).

Step 5 — Broadcast readiness via \`coord_send\` (target="*") with a JSON A2ML envelope announcing your variant + claimed task.

Step 6 — Enter the receive loop: call \`coord_receive\` periodically. If your role is "${role}" and you handle a high-risk operation (tier 2+), route it via \`coord_send_gated\` so the master can quarantine-review.

Step 7 — Heartbeat via \`coord_progress\` before your watchdog TTL expires. Report outcomes via \`coord_report_outcome\` to build your track record.

Maintain coordination etiquette: only one peer claims a task at a time; respect quarantine decisions; do not promote yourself to master without the explicit secret.`;
  return {
    description: `Convene ${role} on BoJ coord bus for: ${task}`,
    messages: [
      { role: "user", content: { type: "text", text } },
    ],
  };
}

function buildDeployWithDnsSsl(args) {
  const app = args.app_name;
  const domain = args.domain;
  const provider = args.provider ?? "fly";
  const providerCartridge = `${provider}-mcp`;
  const text = `Deploy \`${app}\` to ${provider} with custom domain \`${domain}\` and SSL via Cloudflare.

Step 1 — Verify your auth posture: \`boj_cloud_cloudflare\` (operation=authenticate) and \`boj_cartridge_invoke\` against \`${providerCartridge}\` with an auth check op.

Step 2 — Deploy the application via \`boj_cartridge_invoke\` against \`${providerCartridge}\`. Use the deploy/release op appropriate to that provider (Fly: deploy; Render: create-service; Railway: deploy; Vercel: redeploy).

Step 3 — Once the deployment reports a public hostname (e.g. \`${app}.fly.dev\`), point Cloudflare DNS at it. Call \`boj_cloud_cloudflare\` with operation="list-dns-zones" to find the zone for \`${domain}\`, then operation="add-dns-record" with type=CNAME, name=\`${domain}\`, content=<provider-hostname>, proxied=true.

Step 4 — On the provider side, register the custom domain so the provider's edge accepts traffic for \`${domain}\` (Fly: certs create; Render: add custom domain; Railway: add domain; Vercel: assign domain).

Step 5 — Verify HTTPS resolves and the provider's cert issuance has completed (Cloudflare-proxied → Cloudflare cert is sufficient end-to-end; for grey-clouded, wait for provider issuance).

Step 6 — Smoke-test via \`boj_browser_navigate\` to \`https://${domain}\` and confirm 200 + correct content.

If anything fails, do not roll back automatically. Report the failed step and ask before destructive actions.`;
  return {
    description: `Deploy ${app} to ${provider} + ${domain} via Cloudflare DNS/SSL`,
    messages: [
      { role: "user", content: { type: "text", text } },
    ],
  };
}

function buildSummarizeChannel(args) {
  const platform = args.platform;
  const channel = args.channel_id;
  const hours = args.hours ?? "24";
  const cartridge = `${platform}-mcp`;
  const text = `Summarize the last ${hours} hours of activity in ${platform} channel \`${channel}\`.

Step 1 — Call \`boj_cartridge_invoke\` against \`${cartridge}\` with an op that fetches recent messages (Slack: read-history; Discord: channel-history; Matrix: room-messages; Telegram: get-updates) bounded by the ${hours}-hour window.

Step 2 — Produce a Markdown summary with these sections:
  - **Decisions made** — explicit choices with who said what
  - **Action items** — TODOs with owner + deadline when stated
  - **Unresolved threads** — questions or debates that didn't reach closure
  - **Notable links / files** — anything shared that's worth surfacing

Step 3 — At the end, list any participants who appeared but didn't post substantively (silent presence).

Keep it under 800 words. Do not invent details that aren't in the message log. Quote exact words for any decision or commitment.`;
  return {
    description: `Summarize ${platform}#${channel} (${hours}h)`,
    messages: [
      { role: "user", content: { type: "text", text } },
    ],
  };
}

function buildTriageIssues(args) {
  const forge = args.forge ?? "github";
  const owner = args.owner;
  const repo = args.repo;
  const topN = args.top_n ?? "10";
  const text = `Triage open issues on ${forge}:${owner}/${repo}. Surface the top ${topN} for action.

Step 1 — List open issues via \`boj_${forge}_list_issues\` (state=open, owner=${owner}, repo=${repo}, per_page=100). Page if there are more.

Step 2 — For each issue, classify by:
  - **Severity** — critical / high / normal / low (signal: security keywords, "broken", user-blocking, vs. nice-to-have)
  - **Effort** — small / medium / large (signal: scope of files mentioned, dependency complexity)
  - **Staleness** — fresh (<7 days) / mid (7-30) / stale (>30) — uses createdAt + last-activity

Step 3 — Recommend labels using these rules: any critical/high → \`priority:high\`; any small + stale → \`good-first-issue\`; any unanswered + >14 days → \`needs-triage\`.

Step 4 — Surface the top ${topN} prioritized as: \`[severity, -staleness_days, effort_asc]\`. For each, output:
  - Issue # + title
  - Severity / Effort / Staleness classification
  - Why it's prioritized
  - Recommended labels
  - Suggested first step

Do not apply labels automatically. This is recommendation-only; the human must approve before any \`boj_${forge}_*\` mutating call.`;
  return {
    description: `Triage top ${topN} issues on ${forge}:${owner}/${repo}`,
    messages: [
      { role: "user", content: { type: "text", text } },
    ],
  };
}

function buildProofStatus(args) {
  const cartridge = args.cartridge;
  const scope = cartridge ? `cartridge \`${cartridge}\`` : "the whole BoJ ABI surface";
  const text = `Report the formal-verification posture of ${scope}.

Step 1 — Read \`boj://proofs/manifest\` via \`resources/read\` to get the canonical obligation list and discharge state.

${cartridge ? `Step 2 — Read \`boj://cartridges/${cartridge}\` to confirm this cartridge exists and check its declared proof-obligation set in its manifest.` : `Step 2 — Read \`boj://cartridges\` to enumerate every cartridge and note which ones declare proof obligations in their manifests.`}

Step 3 — Produce a report with:
  - **Obligations**: ID, title, status (discharged / outstanding), evidence file
  - **believe_me audit**: current axiom count vs. initial, with a brief note on each remaining axiom and whether discharge is tractable
  - **Outstanding work**: any obligation marked outstanding, plus the relevant tracking issue (epic #87 item 11 for residual axioms, item 12 for composition proof)

Do not invent obligations not present in the manifest. If a cartridge has no proof obligations declared, say so explicitly rather than fabricating any.`;
  return {
    description: `Proof-verification posture for ${scope}`,
    messages: [
      { role: "user", content: { type: "text", text } },
    ],
  };
}

const BUILDERS = {
  "audit-repo": buildAuditRepo,
  "convene-cluster": buildConveneCluster,
  "deploy-with-dns-ssl": buildDeployWithDnsSsl,
  "summarize-channel": buildSummarizeChannel,
  "triage-issues": buildTriageIssues,
  "proof-status": buildProofStatus,
};

function validateRequired(name, args) {
  const def = PROMPT_DEFS.find((p) => p.name === name);
  if (!def) return { code: -32602, message: `Unknown prompt: ${name}` };
  for (const a of def.arguments) {
    if (a.required && (args?.[a.name] === undefined || args?.[a.name] === "")) {
      return { code: -32602, message: `Prompt '${name}' requires argument '${a.name}'` };
    }
  }
  return null;
}

function getPrompt(name, args) {
  const err = validateRequired(name, args ?? {});
  if (err) return { error: err };
  const builder = BUILDERS[name];
  if (!builder) return { error: { code: -32602, message: `Unknown prompt: ${name}` } };
  return { result: builder(args ?? {}) };
}

export { listPrompts, getPrompt };
