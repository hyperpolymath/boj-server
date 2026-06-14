# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule BojRest.Catalog do
  @moduledoc """
  Reads every `cartridge.json` under `<root>/*/` once at boot, validates each
  against the bundled schema at `schemas/cartridge-v1.json`, and caches the
  parsed structs in ETS keyed by cartridge name. Read-only: no reload, no
  mutation. A cartridge fleet change requires a restart, which matches the
  current mount lifecycle.

  ## Strict mode (since 2026-06-01)

  A `cartridge.json` that fails schema validation is **rejected**: it does
  not enter the catalog and an error is logged. Operators see the bad
  manifest immediately on boot rather than discovering it through a
  silent runtime failure later. Closes `hyperpolymath/boj-server#183`.

  Validation uses the bundled schema mirror at `schemas/cartridge-v1.json`,
  SHA-pinned in `schemas/PINNED-SHA` against the canonical copy at
  `hyperpolymath/standards/cartridges/cartridge-v1.json`. The mirror has
  been kept byte-identical with canonical commit `7c2b815` as of 2026-06-01.

  ## Configuration

  - `:cartridges_root` (required) — the on-disk directory whose immediate
    children are cartridge directories each containing a `cartridge.json`.
  - `:schema_path` (optional) — explicit path to the schema mirror. Defaults
    to `<repo_root>/schemas/cartridge-v1.json` (one level above
    `:cartridges_root` for the bundled case).
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
    schema_path = Keyword.get(opts, :schema_path, default_schema_path(root))
    schema = load_schema(schema_path)
    {loaded, rejected} = load_all(root, schema)

    Logger.info(
      "BoJ catalog: loaded #{loaded} cartridges from #{root}" <>
        " (#{rejected} rejected by schema #{Path.basename(schema_path)})"
    )

    {:ok, %{root: root, schema_path: schema_path, loaded: loaded, rejected: rejected}}
  end

  defp default_schema_path(root) do
    root
    |> Path.expand()
    |> Path.dirname()
    |> Path.join("schemas/cartridge-v1.json")
  end

  defp load_schema(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, schema} ->
            # The canonical schema declares draft 2020-12; ex_json_schema only
            # supports drafts 4/6/7. The schema's actual constructs (type,
            # enum, pattern, required, properties, items, minItems) are all
            # draft-4-compatible, so we rewrite `$schema` in-memory to a
            # supported version before resolving. The on-disk file is
            # unchanged so the PINNED-SHA mirror check still works.
            schema
            |> Map.put("$schema", "http://json-schema.org/draft-07/schema#")
            |> ExJsonSchema.Schema.resolve()

          {:error, err} ->
            raise "BoJ catalog: schema mirror #{path} is not valid JSON: #{inspect(err)}"
        end

      {:error, reason} ->
        raise "BoJ catalog: schema mirror #{path} not readable: #{inspect(reason)}"
    end
  end

  defp load_all(root, schema) do
    root
    |> Path.join("*/cartridge.json")
    |> Path.wildcard()
    |> Enum.reduce({0, 0}, fn path, {loaded, rejected} ->
      case load_one(path, schema) do
        {:ok, cart} ->
          :ets.insert(@table, {Map.get(cart, "name"), cart})
          {loaded + 1, rejected}

        {:error, reason} ->
          Logger.error("BoJ catalog: reject #{path}: #{format_reason(reason)}")
          {loaded, rejected + 1}
      end
    end)
  end

  defp load_one(path, schema) do
    with {:ok, bytes} <- File.read(path),
         {:ok, json} <- Jason.decode(bytes),
         :ok <- validate(schema, json) do
      {:ok, json}
    end
  end

  defp validate(schema, json) do
    case ExJsonSchema.Validator.validate(schema, json) do
      :ok -> :ok
      {:error, errors} -> {:error, {:schema_violation, errors}}
    end
  end

  defp format_reason({:schema_violation, errors}) do
    errors
    |> Enum.map(fn {message, path} -> "#{path}: #{message}" end)
    |> Enum.join("; ")
  end

  defp format_reason(reason), do: inspect(reason)
end
