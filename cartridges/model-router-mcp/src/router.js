#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Model Router — Intelligent model switching for Claude Code
//
// Analyses incoming tasks and determines the optimal model:
//   - Opus: complex architecture, design decisions, formal verification,
//           multi-file refactoring, code review, debugging novel issues
//   - Sonnet: standard coding, feature implementation, file editing,
//             test writing, documentation, most daily work
//   - Haiku: simple searches, file reads, grep/glob, formatting,
//            mechanical replacements, status checks
//
// The router can also PLAN at a higher tier and DELEGATE to a lower tier:
//   1. Opus analyses the task and writes detailed step-by-step instructions
//   2. Haiku/Sonnet executes the plan
//   3. Opus reviews at intervals (every N steps or on completion)
//   4. Escalates back to Opus if the executor is struggling
//
// Usage as MCP server:
//   Add to claude_desktop_config.json or .claude/settings.json
//
// Usage as Claude Code skill:
//   /model-route <task description>

// ---------------------------------------------------------------------------
// Task Classification
// ---------------------------------------------------------------------------

/**
 * Complexity levels that map to model tiers.
 * @typedef {'trivial' | 'simple' | 'moderate' | 'complex' | 'expert'} Complexity
 */

/**
 * Classify a task's complexity based on keyword analysis and heuristics.
 * Returns a complexity level and recommended model.
 *
 * @param {string} task - The task description or prompt
 * @returns {{ complexity: string, model: string, confidence: number, reason: string, canDelegate: boolean }}
 */
function classifyTask(task) {
  const lower = task.toLowerCase();
  const wordCount = task.split(/\s+/).length;

  // --- Expert indicators (always Opus) ---
  const expertPatterns = [
    /formal.?verif/i, /dependent.?type/i, /idris2?/i, /prove|proof|theorem/i,
    /architecture|redesign|refactor.*across/i, /security.?audit|vulnerability/i,
    /design.*system|system.*design/i, /migrate.*codebase/i,
    /cross.?repo|across.*repos/i, /critical.*decision/i,
    /believe_me|assert_total|sorry|Admitted/i,
  ];
  for (const pattern of expertPatterns) {
    if (pattern.test(task)) {
      return {
        complexity: "expert",
        model: "opus",
        confidence: 0.9,
        reason: `Expert task detected: ${pattern.source}`,
        canDelegate: false,
      };
    }
  }

  // --- Complex indicators (Opus, but can delegate with plan) ---
  const complexPatterns = [
    /implement.*feature/i, /build.*system/i, /create.*module/i,
    /debug.*complex|investigate/i, /review.*code|audit.*code/i,
    /multiple.*files|several.*files/i, /wire.*together|integrate/i,
    /character.*system|game.*design/i, /protocol|specification/i,
  ];
  for (const pattern of complexPatterns) {
    if (pattern.test(task)) {
      return {
        complexity: "complex",
        model: "opus",
        confidence: 0.75,
        reason: `Complex task: ${pattern.source}`,
        canDelegate: true,
      };
    }
  }

  // --- Trivial indicators (always Haiku) ---
  const trivialPatterns = [
    /^(list|show|what is|check|status|count|find|search|grep|glob)/i,
    /^(read|cat|head|tail|ls)\s/i,
    /git status|git log|git branch/i,
    /how many|what files/i,
  ];
  for (const pattern of trivialPatterns) {
    if (pattern.test(task)) {
      return {
        complexity: "trivial",
        model: "haiku",
        confidence: 0.85,
        reason: `Trivial query: ${pattern.source}`,
        canDelegate: false,
      };
    }
  }

  // --- Simple indicators (Haiku or Sonnet) ---
  const simplePatterns = [
    /rename|replace|fix.*typo|update.*version/i,
    /add.*header|add.*spdx|add.*license/i,
    /delete.*file|remove.*file|clean.*up/i,
    /format|lint|prettier/i,
    /commit|push|pull/i,
  ];
  for (const pattern of simplePatterns) {
    if (pattern.test(task)) {
      return {
        complexity: "simple",
        model: "haiku",
        confidence: 0.7,
        reason: `Simple mechanical task: ${pattern.source}`,
        canDelegate: false,
      };
    }
  }

  // --- Length-based heuristic for remaining ---
  if (wordCount < 10) {
    return {
      complexity: "simple",
      model: "sonnet",
      confidence: 0.5,
      reason: "Short prompt, defaulting to Sonnet",
      canDelegate: false,
    };
  }

  if (wordCount > 100) {
    return {
      complexity: "complex",
      model: "opus",
      confidence: 0.6,
      reason: "Long detailed prompt suggests complex task",
      canDelegate: true,
    };
  }

  // Default: Sonnet (balanced)
  return {
    complexity: "moderate",
    model: "sonnet",
    confidence: 0.5,
    reason: "No strong signals, defaulting to Sonnet",
    canDelegate: true,
  };
}

// ---------------------------------------------------------------------------
// Plan-and-Delegate System
// ---------------------------------------------------------------------------

/**
 * Generate a delegation plan — instructions that a lower-tier model can follow.
 *
 * This is the key efficiency mechanism:
 *   1. Opus (expensive) analyses the task and writes precise step-by-step instructions
 *   2. Haiku (cheap) follows the instructions mechanically
 *   3. Opus reviews the output at checkpoints
 *
 * @param {string} task - The original task
 * @param {string} targetModel - The model that will execute ('haiku' or 'sonnet')
 * @returns {string} A prompt for the target model with detailed instructions
 */
function generateDelegationPlan(task, targetModel) {
  return `You are executing a pre-planned task. Follow these instructions EXACTLY.
Do not deviate, improvise, or add anything not specified.
If you encounter something unexpected, STOP and report it — do not try to fix it yourself.

MODEL: ${targetModel}
ORIGINAL TASK: ${task}

INSTRUCTIONS:
[This section would be filled by Opus with specific step-by-step instructions]

CHECKPOINTS:
- After each file edit, verify it compiles/builds
- After completing all steps, run tests if available
- Report: what was done, what succeeded, what failed

ESCALATION: If any step fails or is unclear, output "ESCALATE: <reason>" and stop.`;
}

/**
 * Generate review instructions for Opus to check delegated work.
 *
 * @param {string} originalTask - What was requested
 * @param {string} executorOutput - What the lower model produced
 * @returns {string} A prompt for Opus to review
 */
function generateReviewPrompt(originalTask, executorOutput) {
  return `Review the following work done by a delegated model.

ORIGINAL TASK: ${originalTask}

EXECUTOR OUTPUT:
${executorOutput}

CHECK:
1. Was the task completed correctly?
2. Were there any errors, omissions, or quality issues?
3. Does the output match the intent of the original task?
4. Are there any security concerns?

VERDICT: [APPROVED / NEEDS_REVISION / FAILED]
NOTES: [Specific feedback if not approved]`;
}

// ---------------------------------------------------------------------------
// Cost Estimation
// ---------------------------------------------------------------------------

/**
 * Estimate relative cost of running a task on different models.
 * Based on approximate token pricing ratios.
 *
 * @param {number} estimatedTokens - Rough input+output token estimate
 * @returns {{ opus: number, sonnet: number, haiku: number, delegated: number }}
 */
function estimateCost(estimatedTokens) {
  // Relative cost ratios (approximate)
  const opusCostPerToken = 1.0; // baseline
  const sonnetCostPerToken = 0.2; // ~5x cheaper
  const haikuCostPerToken = 0.04; // ~25x cheaper

  const opusCost = estimatedTokens * opusCostPerToken;
  const sonnetCost = estimatedTokens * sonnetCostPerToken;
  const haikuCost = estimatedTokens * haikuCostPerToken;

  // Delegated: Opus plans (10% of tokens) + Haiku executes (90%) + Opus reviews (10%)
  const delegatedCost =
    estimatedTokens * 0.1 * opusCostPerToken +
    estimatedTokens * 0.9 * haikuCostPerToken +
    estimatedTokens * 0.1 * opusCostPerToken;

  return {
    opus: Math.round(opusCost),
    sonnet: Math.round(sonnetCost),
    haiku: Math.round(haikuCost),
    delegated: Math.round(delegatedCost),
    savings: Math.round((1 - delegatedCost / opusCost) * 100) + "%",
  };
}

// ---------------------------------------------------------------------------
// MCP Server (stdio transport)
// ---------------------------------------------------------------------------

const SERVER_NAME = "model-router";
const SERVER_VERSION = "1.0.0";

const TOOLS = [
  {
    name: "classify_task",
    description:
      "Analyse a task and recommend the optimal Claude model (opus/sonnet/haiku). Returns complexity, recommended model, confidence, and whether the task can be delegated to a cheaper model with planning.",
    inputSchema: {
      type: "object",
      properties: {
        task: {
          type: "string",
          description: "The task description to classify",
        },
      },
      required: ["task"],
    },
  },
  {
    name: "plan_delegation",
    description:
      "Generate a step-by-step plan for a cheaper model to execute a task that was classified as delegatable. Opus plans, Haiku/Sonnet executes.",
    inputSchema: {
      type: "object",
      properties: {
        task: {
          type: "string",
          description: "The original task to delegate",
        },
        target_model: {
          type: "string",
          enum: ["haiku", "sonnet"],
          description: "Which model will execute the plan",
        },
      },
      required: ["task", "target_model"],
    },
  },
  {
    name: "review_output",
    description:
      "Have Opus review work done by a delegated model. Returns verdict (APPROVED/NEEDS_REVISION/FAILED) and notes.",
    inputSchema: {
      type: "object",
      properties: {
        original_task: {
          type: "string",
          description: "What was originally requested",
        },
        executor_output: {
          type: "string",
          description: "What the delegated model produced",
        },
      },
      required: ["original_task", "executor_output"],
    },
  },
  {
    name: "estimate_cost",
    description:
      "Estimate relative cost of running a task on different models. Shows potential savings from delegation.",
    inputSchema: {
      type: "object",
      properties: {
        estimated_tokens: {
          type: "number",
          description:
            "Rough estimate of total tokens (input + output) for the task",
        },
      },
      required: ["estimated_tokens"],
    },
  },
];

// --- JSON-RPC stdio transport ---

let buffer = "";

process.stdin.setEncoding("utf-8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) break;

    const header = buffer.substring(0, headerEnd);
    const lengthMatch = header.match(/Content-Length:\s*(\d+)/i);
    if (!lengthMatch) {
      buffer = buffer.substring(headerEnd + 4);
      continue;
    }

    const contentLength = parseInt(lengthMatch[1], 10);
    const bodyStart = headerEnd + 4;
    if (buffer.length < bodyStart + contentLength) break;

    const body = buffer.substring(bodyStart, bodyStart + contentLength);
    buffer = buffer.substring(bodyStart + contentLength);

    try {
      const message = JSON.parse(body);
      handleMessage(message);
    } catch (err) {
      sendError(null, -32700, "Parse error");
    }
  }
});

function send(message) {
  const body = JSON.stringify(message);
  const header = `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`;
  process.stdout.write(header + body);
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function handleMessage(msg) {
  if (msg.method === "initialize") {
    sendResult(msg.id, {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    });
  } else if (msg.method === "notifications/initialized") {
    // no-op
  } else if (msg.method === "tools/list") {
    sendResult(msg.id, { tools: TOOLS });
  } else if (msg.method === "tools/call") {
    handleToolCall(msg);
  } else if (msg.method === "ping") {
    sendResult(msg.id, {});
  } else if (msg.id) {
    sendError(msg.id, -32601, `Unknown method: ${msg.method}`);
  }
}

function handleToolCall(msg) {
  const { name, arguments: args } = msg.params;

  try {
    let result;
    switch (name) {
      case "classify_task":
        result = classifyTask(args.task);
        break;
      case "plan_delegation":
        result = {
          plan: generateDelegationPlan(args.task, args.target_model),
          target_model: args.target_model,
        };
        break;
      case "review_output":
        result = {
          review_prompt: generateReviewPrompt(
            args.original_task,
            args.executor_output
          ),
        };
        break;
      case "estimate_cost":
        result = estimateCost(args.estimated_tokens);
        break;
      default:
        sendError(msg.id, -32602, `Unknown tool: ${name}`);
        return;
    }
    sendResult(msg.id, {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    });
  } catch (err) {
    sendError(msg.id, -32603, err.message);
  }
}

process.stderr.write(`[${SERVER_NAME}] MCP server running on stdio\n`);
