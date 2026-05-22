# BoJ + PanLL Full Onboarding Script
# SPDX-License-Identifier: MPL-2.0
#
# INSTRUCTIONS: Copy everything below the line into Claude Code as a single message.
# Claude will walk you through each step interactively.
# ─────────────────────────────────────────────────────────────────────

I want you to set up my full development environment. Follow these phases IN ORDER. Do not skip ahead. Ask me questions where indicated. Do each phase completely before moving to the next.

---

## PHASE 1 — BoJ Server (Bundle of Joy)

BoJ is a cartridge-based MCP server that routes ALL tool integrations through a single unified gateway. Every MCP, LSP, debugger, and AI agent connects through BoJ cartridges instead of running as separate servers.

1. Clone the BoJ server:
   ```
   git clone https://github.com/hyperpolymath/boj-server ~/Documents/hyperpolymath-repos/boj-server
   cd ~/Documents/hyperpolymath-repos/boj-server
   ```

2. Check and install prerequisites (ask me before installing anything):
   - **Deno** (runtime) — check `deno --version`
   - **Zig** (FFI compilation) — check `zig version`
   - **Rust** (if building from source) — check `rustc --version`
   - **just** (task runner) — check `just --version`

3. Build the server:
   ```
   just deps
   just build
   ```

4. Start the MCP bridge and verify health:
   ```
   deno run --allow-net --allow-env mcp-bridge/main.js
   ```
   Then in another terminal: `curl http://localhost:7700/health`

5. Register BoJ as my Claude Code MCP server. Create/update `~/.config/claude/mcp_servers.json`:
   ```json
   {
     "boj-server": {
       "command": "deno",
       "args": ["run", "--allow-net", "--allow-env", "<FULL_PATH>/boj-server/mcp-bridge/main.js"],
       "env": { "BOJ_URL": "http://localhost:7700" }
     }
   }
   ```

6. Verify BoJ is working by calling `boj_health` and `boj_menu` tools.

---

## PHASE 2 — Cartridge Inventory

BoJ ships with 22 built-in cartridges. List them with `boj_menu` and show me what's available in a table:

| Cartridge | Protocols | Purpose |
|-----------|-----------|---------|

The 22 built-in cartridges cover: database, container, git, cloud (Verpex/Cloudflare/Vercel), comms (Gmail/Calendar), ML (HuggingFace), research, LSP, DAP (debug), BSP (build), NeSy (neurosymbolic), agentic, fleet (bot orchestration), proof (Idris2), secrets, observability, IaC, queues, model-router, SSG, UMS, lang, feedback.

For any service I'm currently using that does NOT have a cartridge, use the **cartridge minter** to create one:

**Cartridge Minting Wizard** (for each new cartridge):
1. Ask: "What service/tool do you want to connect?"
2. Ask: "What protocols does it need?" (MCP, LSP, DAP, BSP, NeSy, Agentic, gRPC, REST)
3. Ask: "What domain?" (Database, Container, K8s, Git, Cloud, Comms, ML, Research, etc.)
4. Generate the three-layer cartridge scaffold:
   ```
   cartridges/<name>-mcp/
   ├── abi/<Name>Mcp/<Name>.idr    # Idris2 ABI definition
   ├── ffi/build.zig               # Zig FFI implementation
   ├── ffi/<name>_ffi.zig          # Zig FFI source
   └── adapter/<name>_adapter.v    # zig REST/gRPC/GraphQL adapter
   ```
5. Configure and provision the cartridge via `boj_cartridge_invoke`

---

## PHASE 3 — Firefox Setup

Set up Firefox as the browser bridge for Claude Code:

1. Check if Firefox is installed (`which firefox`)
2. If not installed, ask me which package manager to use
3. Create a health-check hook at `~/.claude/hooks/boj-health-check.sh` that:
   - Checks if BoJ server is running on startup, restarts if not
   - Checks if Firefox is running — if YES, do nothing; if NO, launch it **minimised**
   - Logs diagnostics to `~/.claude/hooks/boj-diagnostics.log`
4. Make the hook executable: `chmod +x ~/.claude/hooks/boj-health-check.sh`

---

## PHASE 4 — Code Editor

**ASK ME:** "Which code editor do you want to use? (e.g., VS Code, Neovim, Helix, Zed, Lapce, or something else)"

Based on my answer:
- Configure the LSP cartridge (`lsp-mcp`) to connect to my editor's LSP
- Configure the DAP cartridge (`dap-mcp`) for debugging in my editor
- Set up any editor-specific integrations (extensions, plugins, config files)
- If my editor supports it, configure the BSP cartridge for build server integration

---

## PHASE 5 — PanLL (Optional)

**ASK ME:** "Would you like to install PanLL?"

**Explain PanLL like this:**
> PanLL is an **eNSAID** — an Environment for NeSy-Agentic Integrated Development.
>
> Think of it as a mission control dashboard for coding. Instead of just a code editor, PanLL gives you three co-working panels:
> - **Panel-L** (Symbolic) — formal logic, type checking, proof verification
> - **Panel-N** (Neural) — AI reasoning, suggestions, and an advisor called ECHIDNA
> - **Panel-W** (World) — results, dashboards, databases, security tools
>
> You and the AI work together as equals — neither is "the assistant." PanLL monitors cognitive load (a "Vexometer" tracks frustration), adjusts information density, and manages 79+ specialist overlay panels you can summon for different tasks.
>
> It runs as a lightweight Tauri app (5 MB, not an Electron bloat-fest) built in ReScript + Rust.

**If YES:**

1. Clone PanLL:
   ```
   git clone https://github.com/hyperpolymath/panll ~/Documents/hyperpolymath-repos/panll
   cd ~/Documents/hyperpolymath-repos/panll
   ```

2. Install PanLL prerequisites:
   - ReScript compiler: `npm install rescript` (exception to npm ban — ReScript requires it)
   - Deno (already installed from Phase 1)
   - Rust + Tauri 2.0: check `cargo tauri --version`
   - Tailwind CSS: handled by deno tasks

3. Build PanLL:
   ```
   just build
   ```
   Or for development:
   ```
   just dev
   ```

4. Use the **Panel Minter** to verify it works:
   - Open PanLL → click Minter in the panel bar
   - Or via CLI: the minter generates an 8-file scaffold per panel

**If NO:** Skip to Phase 7.

---

## PHASE 6 — PanLL Panels for IDApTIK & Game Dev

**ASK ME:** "Would you like to set up the existing game development and IDApTIK panels?"

**If YES**, provision these panel sets using the Panel Provisioner:

### IDApTIK eNSAID Panels (11):
| Panel | Purpose |
|-------|---------|
| Valence Shell | Embedded terminal with session recording |
| Game Preview | Live IDApTIK preview with hot-reload |
| VM Inspector | Reversible debugger (step forward/backward) |
| Network Topology | Force-directed in-game network graph |
| Level Architect | Visual level design with validation |
| Coprocessors | Backend coprocessor heatmap (10 types) |
| Multiplayer Monitor | Real-time multiplayer session tracking |
| DLC Workshop | Puzzle pack creation + testing |
| Editor Bridge | Connects PanLL to your code editor |
| Build Dashboard | Build status across all targets |
| Release Manager | Release pipeline and versioning |

### Game Dev Testing Panels (10):
Unit Test Runner, Functional Tester, Regression Guard, Performance Profiler, Load Tester, Soak Monitor, Compatibility Matrix, Exploratory Workbench, Beta Feedback Hub, Balance Analyser

### Game Dev Bridge Panels (8):
Typing Bridge, Neurosym Bridge, Agentic Bridge, Automation Bridge, Database Bridge, Protocol Bridge, Proofs Bridge, Scripting Bridge

### Game Dev Specific Panels (6):
Generator Mode, Architect Mode, Guard AI Tuner, Device Network Designer, Asset Manager, Playtest Recorder

For each panel set, use the **Panel Provisioner** to select isolation tier:
- **Native** (in-process, fastest) — recommended for trusted panels
- **Standard Pod** (Alpine + Podman) — community panels
- **Hardened Pod** (Stapeln + Chainguard) — untrusted panels

Then use the **Panel Configurator** (Workspace panel) to arrange them into workspace modes.

---

## PHASE 7 — Custom Cartridges & Panels

**ASK ME:** "Would you like to create any custom BoJ cartridges or PanLL panels for your development work?"

**If YES for cartridges**, run the **Cartridge Minting Wizard** for each one:
1. "What's the name of this cartridge?"
2. "What does it do? (one sentence)"
3. "What protocols?" — show checklist: ☐ MCP ☐ LSP ☐ DAP ☐ BSP ☐ NeSy ☐ Agentic ☐ gRPC ☐ REST
4. "What domain?" — show checklist: ☐ Database ☐ Container ☐ Git ☐ Cloud ☐ Comms ☐ ML ☐ Research ☐ Other
5. "Any external APIs or services it connects to?"
6. Generate the scaffold, then ask: "Want me to implement the adapter logic now, or leave it as a scaffold?"

**If YES for panels** (and PanLL is installed), run the **Panel Minting Wizard** for each one:
1. "What's the name of this panel?"
2. "What clade kind?" — explain each: directive (controls), scanner (monitors), builder (creates), viewer (displays), ai (neural), bridge (connects external tools)
3. "What does it do? (one sentence)"
4. "Should it connect to any BoJ cartridges?"
5. "What isolation tier?" — Native / Standard Pod / Hardened Pod
6. Generate the 8-file scaffold using the Minter
7. Ask: "Want me to implement the panel logic now, or leave it as a scaffold?"

**Keep asking** "Any more?" until I say I'm done.

---

## PHASE 8 — Final Verification

Run a full system check:
1. `curl http://localhost:7700/health` — BoJ healthy
2. `boj_menu` — all cartridges listed
3. Firefox running (check `pgrep firefox`)
4. Editor integration working
5. If PanLL installed: `just test` in panll directory — all tests pass
6. Show me a summary table of everything installed

**Done!** Tell me: "Your environment is ready. You have [N] BoJ cartridges and [M] PanLL panels configured. Type `boj_menu` any time to see your cartridges, or open PanLL to access your panels."
