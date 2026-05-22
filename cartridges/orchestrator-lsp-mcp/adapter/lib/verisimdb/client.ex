# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Thin VeriSimDB client for persisting orchestration session history.
#
# VeriSimDB is the estate-wide mandatory database layer. This module records:
#   - Session open:  session_id, active domains, workspace_root, started_at
#   - Session close: closed_at timestamp update
#
# Unavailability contract:
#   All calls return :unavailable (not an error) when VeriSimDB is offline.
#   Callers must handle this gracefully — the orchestrator continues normally.
#
# Configuration:
#   config :orchestrator_lsp_mcp, :verisimdb_url, "http://localhost:5440"
#
# The HTTP transport uses Erlang's built-in :httpc to avoid adding a dep.

defmodule OrchestratorLspMcp.VeriSimDB.Client do
  @moduledoc """
  Thin VeriSimDB client for persisting orchestration session history.

  Connects to the local VeriSimDB instance (default: http://localhost:5440).
  All functions degrade gracefully: :unavailable is returned (never raised)
  when the VeriSimDB instance cannot be reached.
  """

  require Logger

  @table "orchestrator_sessions"
  @default_url "http://localhost:5440"

  # ──────────────────────────────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Insert a new session record into VeriSimDB.

  ## Fields persisted
  - `session_id`     – opaque reference (inspect-serialised)
  - `domains`        – list of domain name strings
  - `workspace_root` – absolute path or URI string
  - `started_at`     – ISO 8601 UTC timestamp
  """
  @spec record_session(reference(), [map()], String.t()) :: :ok | :unavailable
  def record_session(session_id, domains, workspace_root) do
    payload =
      Jason.encode!(%{
        table: @table,
        op: "insert",
        row: %{
          session_id: inspect(session_id),
          domains: Enum.map(domains, & &1.domain),
          workspace_root: workspace_root,
          started_at: utc_now_iso8601()
        }
      })

    post("/q", payload)
  end

  @doc """
  Update the `closed_at` timestamp for an existing session record.
  """
  @spec close_session(reference()) :: :ok | :unavailable
  def close_session(session_id) do
    payload =
      Jason.encode!(%{
        table: @table,
        op: "update",
        where: %{session_id: inspect(session_id)},
        set: %{closed_at: utc_now_iso8601()}
      })

    post("/q", payload)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────

  defp post(path, body) do
    url = Application.get_env(:orchestrator_lsp_mcp, :verisimdb_url, @default_url)
    full_url = String.to_charlist(url <> path)

    case :httpc.request(
           :post,
           {full_url, [], ~c"application/json", body},
           [],
           []
         ) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[orchestrator-lsp-mcp] VeriSimDB unavailable at #{url}: #{inspect(reason)}"
        )

        :unavailable
    end
  end

  defp utc_now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
