# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.Catalog do
  @moduledoc """
  Reads every `cartridge.json` under `cartridges/*/` once at boot and caches the
  parsed structs in ETS keyed by cartridge name. Read-only: no reload, no
  mutation. A cartridge fleet change requires a restart, which matches the
  current mount lifecycle.

  `cartridge.json` missing or malformed is a log warning, not a crash — the
  catalog is best-effort.
  """
  use GenServer
  require Logger

  @table :boj_cartridge_catalog

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def list, do: :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))

  def get(name) do
    case :ets.lookup(@table, name) do
      [{^name, cart}] -> {:ok, cart}
      [] -> :not_found
    end
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    root = Keyword.fetch!(opts, :cartridges_root)
    count = load_all(root)
    Logger.info("BoJ catalog: loaded #{count} cartridges from #{root}")
    {:ok, %{root: root, count: count}}
  end

  defp load_all(root) do
    root
    |> Path.join("*/cartridge.json")
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, acc ->
      case load_one(path) do
        {:ok, cart} ->
          :ets.insert(@table, {Map.get(cart, "name"), cart})
          acc + 1

        {:error, reason} ->
          Logger.warning("skip #{path}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp load_one(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, json} <- Jason.decode(bytes),
         name when is_binary(name) <- Map.get(json, "name") do
      {:ok, json}
    else
      nil -> {:error, :missing_name}
      err -> err
    end
  end
end
