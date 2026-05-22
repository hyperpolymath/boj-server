// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// model-router-mcp/mod.js — Intelligent model-tier router cartridge.
//
// All logic is local — no external service required. Classification,
// delegation planning, output review, and cost estimation run in-process.
// The canonical implementation lives in src/router.js (Node.js MCP server);
// this module re-implements the same logic for the BoJ cartridge host.

// ---------------------------------------------------------------------------
// Task Classification
// ---------------------------------------------------------------------------

function classifyTask(task) {
  const expertPatterns = [
    /formal.?verif/i, /dependent.?type/i, /idris2?/i, /prove|proof|theorem/i,
    /architecture|redesign|refactor.*across/i, /security.?audit|vulnerability/i,
    /design.*system|system.*design/i, /migrate.*codebase/i,
    /cross.?repo|across.*repos/i, /critical.*decision/i,
    /believe_me|assert_total|sorry|Admitted/i,
  ];
  for (const p of expertPatterns) {
    if (p.test(task))
      return { complexity: "expert", model: "opus", confidence: 0.9, reason: `Expert: ${p.source}`, canDelegate: false };
  }

  const complexPatterns = [
    /implement.*feature/i, /build.*system/i, /create.*module/i,
    /debug.*complex|investigate/i, /review.*code|audit.*code/i,
    /multiple.*files|several.*files/i, /wire.*together|integrate/i,
    /protocol|specification/i,
  ];
  for (const p of complexPatterns) {
    if (p.test(task))
      return { complexity: "complex", model: "opus", confidence: 0.75, reason: `Complex: ${p.source}`, canDelegate: true };
  }

  const trivialPatterns = [
    /^(list|show|what is|check|status|count|find|search|grep|glob)/i,
    /^(read|cat|head|tail|ls)\s/i,
    /git status|git log|git branch/i,
    /how many|what files/i,
  ];
  for (const p of trivialPatterns) {
    if (p.test(task))
      return { complexity: "trivial", model: "haiku", confidence: 0.85, reason: `Trivial: ${p.source}`, canDelegate: false };
  }

  const simplePatterns = [
    /rename|replace|fix.*typo|update.*version/i,
    /add.*header|add.*spdx|add.*license/i,
    /delete.*file|remove.*file|clean.*up/i,
    /format|lint|prettier/i,
    /commit|push|pull/i,
  ];
  for (const p of simplePatterns) {
    if (p.test(task))
      return { complexity: "simple", model: "haiku", confidence: 0.7, reason: `Simple: ${p.source}`, canDelegate: false };
  }

  const wordCount = task.split(/\s+/).length;
  if (wordCount < 10)
    return { complexity: "simple", model: "sonnet", confidence: 0.5, reason: "Short prompt", canDelegate: false };
  if (wordCount > 100)
    return { complexity: "complex", model: "opus", confidence: 0.6, reason: "Long detailed prompt", canDelegate: true };

  return { complexity: "moderate", model: "sonnet", confidence: 0.5, reason: "No strong signals, defaulting to Sonnet", canDelegate: true };
}

// ---------------------------------------------------------------------------
// Plan-and-Delegate
// ---------------------------------------------------------------------------

function generateDelegationPlan(task, targetModel) {
  return `You are executing a pre-planned task. Follow these instructions EXACTLY.
Do not deviate, improvise, or add anything not specified.
If you encounter something unexpected, STOP and report it — do not try to fix it yourself.

MODEL: ${targetModel}
ORIGINAL TASK: ${task}

INSTRUCTIONS:
[Opus will fill detailed step-by-step instructions before handoff]

CHECKPOINTS:
- After each file edit, verify it compiles/builds
- After completing all steps, run tests if available
- Report: what was done, what succeeded, what failed

ESCALATION: If any step fails or is unclear, output "ESCALATE: <reason>" and stop.`;
}

// ---------------------------------------------------------------------------
// Output Review
// ---------------------------------------------------------------------------

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

function estimateCost(estimatedTokens) {
  const opusPer = 1.0, sonnetPer = 0.2, haikuPer = 0.04;
  const opus = estimatedTokens * opusPer;
  const sonnet = estimatedTokens * sonnetPer;
  const haiku = estimatedTokens * haikuPer;
  // Delegated: Opus plans (10%) + Haiku executes (90%) + Opus reviews (10%)
  const delegated = estimatedTokens * 0.1 * opusPer
    + estimatedTokens * 0.9 * haikuPer
    + estimatedTokens * 0.1 * opusPer;
  return {
    opus: Math.round(opus),
    sonnet: Math.round(sonnet),
    haiku: Math.round(haiku),
    delegated: Math.round(delegated),
    savings: Math.round((1 - delegated / opus) * 100) + "%",
  };
}

// ---------------------------------------------------------------------------
// handleTool — BoJ cartridge entry point
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "classify_task": {
      const { task } = args ?? {};
      if (!task) return { status: 400, data: { error: "task is required" } };
      return { status: 200, data: classifyTask(task) };
    }

    case "plan_delegation": {
      const { task, target_model } = args ?? {};
      if (!task || !target_model)
        return { status: 400, data: { error: "task and target_model are required" } };
      return { status: 200, data: { plan: generateDelegationPlan(task, target_model), target_model } };
    }

    case "review_output": {
      const { original_task, executor_output } = args ?? {};
      if (!original_task || !executor_output)
        return { status: 400, data: { error: "original_task and executor_output are required" } };
      return { status: 200, data: { review_prompt: generateReviewPrompt(original_task, executor_output) } };
    }

    case "estimate_cost": {
      const { estimated_tokens } = args ?? {};
      if (estimated_tokens == null || typeof estimated_tokens !== "number")
        return { status: 400, data: { error: "estimated_tokens (number) is required" } };
      return { status: 200, data: estimateCost(estimated_tokens) };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
