# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.Application do
  @moduledoc """
  OTP application for the BoJ REST skeleton.

  Boots the cartridge catalog (reads every `cartridges/*/cartridge.json`
  into an ETS-backed cache) and the Cowboy HTTP listener on the configured
  port (default 7700) bound to the configured IP (default `127.0.0.1`).

  ## Bind address — loopback by default

  The Cowboy listener binds to `127.0.0.1` unless `BOJ_BIND_IP` is set.
  This is the code-enforced expression of the ADR-0004 §1 invariant
  that BoJ's back-side bind is not externally routable in deployments
  fronted by http-capability-gateway. Operators wanting BoJ exposed
  on all interfaces (legacy / standalone deployments) must set
  `BOJ_BIND_IP=0.0.0.0` (IPv4) or `BOJ_BIND_IP=::` (IPv6) explicitly.

  See `docs/integration/http-capability-gateway-boj-contract.md` §1
  for the wider transport invariant and the Phase E rollout-runbook
  §1.4 prerequisite checklist.
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:boj_rest, :port, 7700)
    bind_ip = parse_bind_ip(Application.get_env(:boj_rest, :bind_ip, "127.0.0.1"))
    cartridges_root = Application.get_env(:boj_rest, :cartridges_root)

    data_dir = Application.get_env(:boj_rest, :data_dir, "/data")

    start_server = Application.get_env(:boj_rest, :start_server, true)

    children =
      [
        {BojRest.NodeKey, data_dir: data_dir},
        {BojRest.Catalog, cartridges_root: cartridges_root},
        {BojRest.JsWorkerPool, []}
      ] ++
        if start_server do
          [{Plug.Cowboy, scheme: :http, plug: BojRest.Router, options: [port: port, ip: bind_ip]}]
        else
          []
        end

    opts = [strategy: :one_for_one, name: BojRest.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Parse a bind-address string (IPv4 or IPv6) into the Erlang inet tuple
  form expected by `:gen_tcp`/Cowboy. Raises on invalid input — fail-fast
  is preferred to silently degrading to `0.0.0.0` and exposing the
  back-side bind.
  """
  @spec parse_bind_ip(String.t()) :: :inet.ip_address()
  def parse_bind_ip(str) when is_binary(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} ->
        ip

      {:error, _} ->
        raise ArgumentError,
              "BOJ_BIND_IP=#{inspect(str)} is not a valid IPv4 or IPv6 address. " <>
                "Use e.g. \"127.0.0.1\" (default, loopback-only) or \"0.0.0.0\" " <>
                "(all IPv4 interfaces; only valid for legacy/standalone deployments)."
    end
  end
end
