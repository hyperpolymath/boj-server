# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# GenLSP server entry-point for the orchestrator cartridge.
#
# Responsibilities:
#   - Negotiate LSP capabilities with the editor client (initialize handshake)
#   - Delegate textDocument/completion and textDocument/hover requests to
#     Executor.fan_out/3, which fans them out to the active domain servers in
#     parallel and merges the results.
#   - Broadcast open/change/close notifications to all active domain servers.
#   - Relay publishDiagnostics push-notifications from domain servers back to
#     the editor (wired via Executor, not handled directly here).
#
# State (lsp.assigns):
#   :domains      – list of %{domain: string, port: integer} maps from Planner
#   :session_id   – opaque reference used for VeriSimDB session tracking

defmodule OrchestratorLspMcp.LSP.Server do
  use GenLSP

  alias OrchestratorLspMcp.Orchestrator.{Planner, Executor}
  alias OrchestratorLspMcp.VeriSimDB.Client, as: DB

  # ──────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────

  @impl true
  def init(lsp, _args) do
    {:ok, assign(lsp, domains: [], session_id: nil)}
  end

  # ──────────────────────────────────────────────────────────────────────
  # Request handlers
  # ──────────────────────────────────────────────────────────────────────

  @impl true
  def handle_request(%GenLSP.Requests.Initialize{} = req, lsp) do
    root = get_in(req, [:params, :rootUri])
    domains = Planner.active_domains(root)
    session_id = make_ref()

    # Persist session asynchronously — VeriSimDB unavailability must not
    # block the initialize handshake.
    Task.start(fn -> DB.record_session(session_id, domains, root || "") end)

    caps = Planner.merged_capabilities(domains)

    {:reply, %{capabilities: caps},
     assign(lsp, domains: domains, session_id: session_id)}
  end

  @impl true
  def handle_request(%GenLSP.Requests.TextDocumentCompletion{} = req, lsp) do
    result = Executor.fan_out(:completion, req.params, lsp.assigns.domains)
    {:reply, result, lsp}
  end

  @impl true
  def handle_request(%GenLSP.Requests.TextDocumentHover{} = req, lsp) do
    result = Executor.fan_out(:hover, req.params, lsp.assigns.domains)
    {:reply, result, lsp}
  end

  # ──────────────────────────────────────────────────────────────────────
  # Notification handlers
  # ──────────────────────────────────────────────────────────────────────

  @impl true
  def handle_notification(%GenLSP.Notifications.Initialized{}, lsp) do
    # Nothing to do beyond acknowledging the handshake is complete.
    {:noreply, lsp}
  end

  @impl true
  def handle_notification(%GenLSP.Notifications.TextDocumentDidOpen{} = notif, lsp) do
    Executor.broadcast_notification(:did_open, notif.params, lsp.assigns.domains)
    {:noreply, lsp}
  end

  @impl true
  def handle_notification(%GenLSP.Notifications.TextDocumentDidChange{} = notif, lsp) do
    Executor.broadcast_notification(:did_change, notif.params, lsp.assigns.domains)
    {:noreply, lsp}
  end

  @impl true
  def handle_notification(%GenLSP.Notifications.TextDocumentDidClose{} = notif, lsp) do
    Executor.broadcast_notification(:did_close, notif.params, lsp.assigns.domains)

    # Close VeriSimDB session when the last document is closed (best-effort).
    Task.start(fn -> DB.close_session(lsp.assigns.session_id) end)

    {:noreply, lsp}
  end

  # Catch-all: ignore unknown notifications silently.
  @impl true
  def handle_notification(_, lsp), do: {:noreply, lsp}
end
