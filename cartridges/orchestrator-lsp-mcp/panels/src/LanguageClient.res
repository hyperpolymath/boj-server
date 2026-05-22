// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// LanguageClient.res — ReScript bindings for vscode-languageclient/node.
//
// Binds just the subset needed to start, stop, and dispose an LSP client
// from within the VSCode extension host.

// Opaque LanguageClient instance.
type t

// ── ServerOptions ────────────────────────────────────────────────────────────

// Environment variable overrides for the server process.
type processEnv = Js.Dict.t<string>

// Options for the spawned server process.
@deriving(abstract)
type executableOptions = {
  @optional cwd: string,
  @optional env: processEnv,
}

// A runnable executable (command + args + optional process options).
@deriving(abstract)
type executable = {
  command: string,
  @optional args: array<string>,
  @optional options: executableOptions,
}

// Run/debug variants — vscode-languageclient picks `run` in production.
@deriving(abstract)
type serverOptions = {
  run: executable,
  debug: executable,
}

// ── ClientOptions ─────────────────────────────────────────────────────────────

// A document selector entry — any combination of scheme, language, pattern.
@deriving(abstract)
type documentSelectorItem = {
  @optional scheme: string,
  @optional language: string,
  @optional pattern: string,
}

// Options for the LanguageClient.
@deriving(abstract)
type clientOptions = {
  documentSelector: array<documentSelectorItem>,
  @optional outputChannel: VscodeApi.OutputChannel.t,
}

// ── LanguageClient constructor ────────────────────────────────────────────────

// `new LanguageClient(id, name, serverOptions, clientOptions)`
@module("vscode-languageclient/node") @new
external make: (string, string, serverOptions, clientOptions) => t = "LanguageClient"

// ── Lifecycle ─────────────────────────────────────────────────────────────────

// Start the language client and server.  Returns a promise that resolves when
// the server has initialised.
@send
external start: t => promise<unit> = "start"

// Gracefully stop the language client and server.
@send
external stop: t => promise<unit> = "stop"

// Cast the client as a disposable for subscription registration.
// LanguageClient implements the disposable protocol — this is a safe identity cast.
external asDisposable: t => VscodeApi.disposable = "%identity"
