# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Fans out LSP requests to the selected domain servers in parallel and
# merges their responses via the appropriate Handlers module.
#
# fan_out/3         – parallel request + merge for :completion and :hover
# broadcast_notification/3 – fire-and-forget notification relay to all domains
#
# Failure isolation:
#   - Per-domain tasks that time out or crash are silently dropped (domain
#     unavailability must never crash the orchestrator).
#   - The @timeout is intentionally conservative (5 s) to avoid stacking
#     slow domains into a cascade that blocks the editor.

defmodule OrchestratorLspMcp.Orchestrator.Executor do
  @moduledoc """
  Fans out LSP requests to domain servers in parallel and merges results.

  Uses `Task.async_stream/3` for parallel request dispatch with a hard
  per-domain timeout. Timed-out or crashed tasks are silently dropped so
  that a single offline domain never blocks completion/hover for the rest.
  """

  alias OrchestratorLspMcp.Orchestrator.{Planner, LSPClientPool}
  alias OrchestratorLspMcp.LSP.Handlers.{Completion, Hover}

  # Per-domain request timeout in milliseconds.
  @timeout 5_000

  # ──────────────────────────────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Fan out `method` (:completion | :hover) to the domains selected by
  Planner.route/2 and merge the results.

  Returns the merged LSP response (list for completion, map/nil for hover).
  """
  @spec fan_out(:completion | :hover, map(), [map()]) :: term()
  def fan_out(:completion, params, domains) do
    uri = get_in(params, ["textDocument", "uri"]) || ""
    routed = Planner.route(uri, domains)
    results = parallel_request(routed, :completion, params)
    Completion.merge(results)
  end

  def fan_out(:hover, params, domains) do
    uri = get_in(params, ["textDocument", "uri"]) || ""
    routed = Planner.route(uri, domains)
    results = parallel_request(routed, :hover, params)
    Hover.merge(results)
  end

  @doc """
  Broadcast a notification to all active domain servers.

  Fire-and-forget: errors and timeouts per domain are silently swallowed.
  Uses `Task.Supervisor.async_stream_nolink/4` to avoid linking the
  broadcast tasks to the calling process.
  """
  @spec broadcast_notification(atom(), map(), [map()]) :: :ok
  def broadcast_notification(method, params, domains) do
    Task.Supervisor.async_stream_nolink(
      OrchestratorLspMcp.ExecutionSupervisor,
      domains,
      fn d -> send_notification(d, method, params) end,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────

  # Dispatch `method` to each domain in parallel; collect {domain, result} pairs.
  # Tasks that exit (timeout or crash) produce no result entry.
  defp parallel_request(domains, method, params) do
    domains
    |> Task.async_stream(
      fn d -> {d.domain, send_request(d, method, params)} end,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, result} -> [result]
      # Drop timed-out or crashed tasks without propagating the error.
      {:exit, _reason} -> []
    end)
  end

  # Send a synchronous LSP request to a single domain client process.
  # Returns nil if the domain is not registered in the pool, or on any error.
  defp send_request(domain_info, method, params) do
    case LSPClientPool.get(domain_info.domain) do
      nil ->
        nil

      pid ->
        GenServer.call(pid, {:request, method, params}, @timeout)
    end
  rescue
    # Catch exit/timeout from GenServer.call so callers always get a value.
    _ -> nil
  end

  # Send a fire-and-forget cast to a single domain client process.
  defp send_notification(domain_info, method, params) do
    case LSPClientPool.get(domain_info.domain) do
      nil -> :noop
      pid -> GenServer.cast(pid, {:notification, method, params})
    end
  end
end
