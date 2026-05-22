// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Extension.res — BoJ Orchestrator LSP — VSCode extension entry point.
//
// Registers the cross-domain GenLSP orchestrator as a single language server
// that editors and AI agents connect to once, receiving cross-domain
// intelligence from all 12 poly-*-lsp servers.
//
// Architecture:
//   VSCode / AI agent (LanguageClient) ←→ this extension ←→ Elixir adapter
//                                                              ↕ routes by domain
//                                                        12 poly-*-lsp servers
//
// Configuration keys (boj.orchestratorLsp.*):
//   adapterDir    — path to the adapter/ Mix project root
//   command       — executable to start the adapter (default: "mix")
//   args          — argument array (default: ["run", "--no-halt"])
//   trace.server  — LSP trace level: "off" | "messages" | "verbose"

// The active LanguageClient, held for graceful shutdown on deactivation.
let client: ref<option<LanguageClient.t>> = ref(None)

// ── Helpers ──────────────────────────────────────────────────────────────────

// Wrap a JS array push to keep ReScript bindings local.
@val @scope("Array.prototype")
external arrayPush: (array<'a>, 'a) => int = "push"

// Retrieve the adapter directory from VSCode config or the BOJ env var.
let resolveAdapterDir = (): string => {
  let cfg = VscodeApi.Workspace2.getConfiguration("boj.orchestratorLsp")
  switch VscodeApi.Configuration.get(cfg, "adapterDir") {
  | Some(dir) if dir !== "" => dir
  | _ =>
    let envDir: Js.nullable<string> = %raw(`process.env.BOJ_ORCHESTRATOR_LSP_DIR ?? null`)
    switch Js.Nullable.toOption(envDir) {
    | Some(d) => d
    | None => "cartridges/orchestrator-lsp-mcp/adapter"
    }
  }
}

// Workspace root: first open folder, or "." as fallback.
let resolveWorkspaceRoot = (): string => {
  switch VscodeApi.Workspace.workspaceFolders {
  | Some(folders) if Array.length(folders) > 0 =>
    let uri = folders->Array.getUnsafe(0)->VscodeApi.WorkspaceFolder.uri
    VscodeApi.Uri.fsPath(uri)
  | _ => "."
  }
}

// Build the ServerOptions record for vscode-languageclient.
let buildServerOptions = (adapterDir: string): LanguageClient.serverOptions => {
  let cfg = VscodeApi.Workspace2.getConfiguration("boj.orchestratorLsp")

  let cmd: string = switch VscodeApi.Configuration.get(cfg, "command") {
  | Some(c) => c
  | None => "mix"
  }

  let args: array<string> = switch VscodeApi.Configuration.get(cfg, "args") {
  | Some(a) => a
  | None => ["run", "--no-halt"]
  }

  let opts = LanguageClient.executableOptions(~cwd=adapterDir, ())
  let exe = LanguageClient.executable(~command=cmd, ~args, ~options=opts, ())
  LanguageClient.serverOptions(~run=exe, ~debug=exe)
}

// Build the ClientOptions for vscode-languageclient.
// The orchestrator accepts all document types — routing happens inside the adapter.
let buildClientOptions = (channel: VscodeApi.OutputChannel.t): LanguageClient.clientOptions => {
  let selector = [
    LanguageClient.documentSelectorItem(~scheme="file", ()),
    LanguageClient.documentSelectorItem(~scheme="untitled", ()),
  ]
  LanguageClient.clientOptions(~documentSelector=selector, ~outputChannel=channel, ())
}

// Wrap an OutputChannel as a disposable for VSCode subscriptions.
let channelAsDisposable = (ch: VscodeApi.OutputChannel.t): VscodeApi.disposable => {
  {dispose: () => VscodeApi.OutputChannel.dispose(ch)}
}

// ── Extension lifecycle ───────────────────────────────────────────────────────

// Called by VSCode when the extension activates.
// Exported as a top-level binding — ReScript CommonJS output exposes it as
// `module.exports.activate`, which is what VSCode requires.
let activate = (context: VscodeApi.extensionContext): unit => {
  let channel = VscodeApi.Window.createOutputChannel("BoJ Orchestrator LSP")
  let subscriptions = VscodeApi.ExtensionContext.subscriptions(context)

  let log = msg => VscodeApi.OutputChannel.appendLine(channel, "[BoJ Orchestrator LSP] " ++ msg)

  let adapterDir = resolveAdapterDir()
  let wsRoot = resolveWorkspaceRoot()
  log("adapter dir: " ++ adapterDir)
  log("workspace root: " ++ wsRoot)

  let serverOpts = buildServerOptions(adapterDir)
  let clientOpts = buildClientOptions(channel)

  let lspClient = LanguageClient.make(
    "boj-orchestrator-lsp",
    "BoJ Orchestrator LSP",
    serverOpts,
    clientOpts,
  )
  client := Some(lspClient)

  let _ =
    LanguageClient.start(lspClient)
    ->Js.Promise.then_(_ => {
      log("adapter ready — connected to 12 domain LSP servers")
      Js.Promise.resolve()
    }, _)
    ->Js.Promise.catch(err => {
      let detail = Js.String.make(err)
      log("adapter failed to start: " ++ detail)
      VscodeApi.Window.showErrorMessage("BoJ Orchestrator LSP failed to start: " ++ detail)
      Js.Promise.resolve()
    }, _)

  // Register for automatic cleanup when the extension deactivates.
  let _ = arrayPush(subscriptions, LanguageClient.asDisposable(lspClient))
  let _ = arrayPush(subscriptions, channelAsDisposable(channel))
  ()
}

// Called by VSCode before the extension host is torn down.
// Returns a promise so VSCode waits for graceful shutdown.
let deactivate = (): Js.Promise.t<unit> => {
  switch client.contents {
  | Some(c) =>
    client := None
    LanguageClient.stop(c)
  | None => Js.Promise.resolve()
  }
}
