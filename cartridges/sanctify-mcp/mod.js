// SPDX-License-Identifier: MPL-2.0
export const cartridge = {
  name: "sanctify-mcp",
  version: "1.0.0",
  description: "Sanctify cartridge — PHP lint and deviation detection",
  tools: [
    { id: "lint_file", name: "Lint File" },
    { id: "detect_deviations", name: "Detect Deviations" },
    { id: "analyze_file", name: "Analyze File" },
    { id: "check_snippet", name: "Check Snippet" },
    { id: "validate_syntax", name: "Validate Syntax" },
  ],
};

export async function health() {
  return { status: "healthy", cartridge: "sanctify-mcp" };
}

export async function init() {
  console.log("[sanctify-mcp] Initializing");
  return { initialized: true };
}

export async function cleanup() {
  console.log("[sanctify-mcp] Shutting down");
  return { cleaned: true };
}
