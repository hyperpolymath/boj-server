# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Registry of live connections to individual domain LSP server processes.
#
# Domain LSP clients (one per domain) register themselves here via put/2
# when they successfully connect, and deregister via remove/1 when they
# disconnect or crash.
#
# The Executor queries this pool before fanning out requests; a nil return
# from get/1 means the domain server is offline and the request for that
# domain is silently skipped.

defmodule OrchestratorLspMcp.Orchestrator.LSPClientPool do
  use GenServer
  require Logger

  @name __MODULE__

  # ──────────────────────────────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────────────────────────────

  @doc "Start the pool under its module name."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Look up the client PID for `domain`. Returns nil if not registered."
  @spec get(String.t()) :: pid() | nil
  def get(domain), do: GenServer.call(@name, {:get, domain})

  @doc "Register `pid` as the client for `domain`."
  @spec put(String.t(), pid()) :: :ok
  def put(domain, pid), do: GenServer.cast(@name, {:put, domain, pid})

  @doc "Deregister the client for `domain` (e.g. on disconnect)."
  @spec remove(String.t()) :: :ok
  def remove(domain), do: GenServer.cast(@name, {:remove, domain})

  @doc "Return the full map of %{domain => pid} registrations."
  @spec all() :: %{String.t() => pid()}
  def all, do: GenServer.call(@name, :all)

  # ──────────────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ──────────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:get, domain}, _from, state) do
    {:reply, Map.get(state, domain), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:put, domain, pid}, state) do
    Logger.info("[orchestrator-lsp-mcp] registered domain #{domain} → #{inspect(pid)}")
    {:noreply, Map.put(state, domain, pid)}
  end

  def handle_cast({:remove, domain}, state) do
    Logger.info("[orchestrator-lsp-mcp] removed domain #{domain} from pool")
    {:noreply, Map.delete(state, domain)}
  end
end
