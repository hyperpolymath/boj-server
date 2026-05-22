# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Application supervisor for the OrchestratorLspMcp BoJ cartridge.
#
# Starts the following processes:
#   - GenLSP server (omitted in :test env to avoid stdio contention)
#   - LSPClientPool: registry of connected domain LSP server PIDs
#   - ExecutionRegistry: unique-key Registry for in-flight execution tracking
#   - ExecutionSupervisor: DynamicSupervisor for fan-out Task workers

defmodule OrchestratorLspMcp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Mix.env() == :test do
        # In test, omit the GenLSP server (it binds stdio) and the pool
        # (tests instantiate domain stubs directly).
        [
          {Registry, keys: :unique, name: OrchestratorLspMcp.ExecutionRegistry},
          {DynamicSupervisor,
           strategy: :one_for_one, name: OrchestratorLspMcp.ExecutionSupervisor}
        ]
      else
        [
          {OrchestratorLspMcp.LSP.Server, []},
          {OrchestratorLspMcp.Orchestrator.LSPClientPool, []},
          {Registry, keys: :unique, name: OrchestratorLspMcp.ExecutionRegistry},
          {DynamicSupervisor,
           strategy: :one_for_one, name: OrchestratorLspMcp.ExecutionSupervisor}
        ]
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: OrchestratorLspMcp.Supervisor
    )
  end
end
