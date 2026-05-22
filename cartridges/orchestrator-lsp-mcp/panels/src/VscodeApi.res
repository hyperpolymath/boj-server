// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// VscodeApi.res — Minimal ReScript external bindings for the VSCode extension API.
//
// Only the surface used by the orchestrator-lsp-mcp extension is bound here.
// Extend as needed rather than importing a full binding library.

// A VSCode disposable — anything with a `dispose()` method can be pushed into
// ExtensionContext.subscriptions so VSCode cleans it up on extension deactivation.
type disposable = {dispose: unit => unit}

// Opaque handle passed to `activate`. Never constructed by extension code.
type extensionContext

module ExtensionContext = {
  // Array of disposables to clean up when the extension deactivates.
  @get
  external subscriptions: extensionContext => array<disposable> = "subscriptions"
}

module OutputChannel = {
  type t

  @send
  external appendLine: (t, string) => unit = "appendLine"

  @send
  external show: t => unit = "show"

  @send
  external dispose: t => unit = "dispose"
}

module Uri = {
  type t
  @get external fsPath: t => string = "fsPath"
}

module WorkspaceFolder = {
  type t
  @get external uri: t => Uri.t = "uri"
  @get external name: t => string = "name"
}

module Window = {
  @module("vscode") @scope("window")
  external createOutputChannel: string => OutputChannel.t = "createOutputChannel"

  @module("vscode") @scope("window")
  external showErrorMessage: string => unit = "showErrorMessage"

  @module("vscode") @scope("window")
  external showInformationMessage: string => unit = "showInformationMessage"
}

module Workspace = {
  // May be undefined if no folder is open — binds as nullable array.
  @module("vscode") @scope("workspace") @return(nullable)
  external workspaceFolders: option<array<WorkspaceFolder.t>> = "workspaceFolders"
}

module Configuration = {
  type t

  @send @return(nullable)
  external get: (t, string) => option<'a> = "get"
}

module Workspace2 = {
  @module("vscode") @scope("workspace")
  external getConfiguration: string => Configuration.t = "getConfiguration"
}
