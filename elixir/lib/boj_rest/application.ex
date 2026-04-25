# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.Application do
  @moduledoc """
  OTP application for the BoJ REST skeleton.

  Boots the cartridge catalog (reads every `cartridges/*/cartridge.json`
  into an ETS-backed cache) and the Cowboy HTTP listener on the configured
  port (default 7700).
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:boj_rest, :port, 7700)
    cartridges_root = Application.get_env(:boj_rest, :cartridges_root)

    data_dir = Application.get_env(:boj_rest, :data_dir, "/data")

    start_server = Application.get_env(:boj_rest, :start_server, true)

    children =
      [
        {BojRest.NodeKey, data_dir: data_dir},
        {BojRest.Catalog, cartridges_root: cartridges_root}
      ] ++
        if start_server do
          [{Plug.Cowboy, scheme: :http, plug: BojRest.Router, options: [port: port]}]
        else
          []
        end

    opts = [strategy: :one_for_one, name: BojRest.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
