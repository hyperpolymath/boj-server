# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.CatalogTest do
  use ExUnit.Case, async: false

  @cartridges_root Path.expand("../../cartridges", __DIR__)

  setup_all do
    case Process.whereis(BojRest.Catalog) do
      nil -> start_supervised!({BojRest.Catalog, cartridges_root: @cartridges_root})
      _pid -> :ok
    end
    :ok
  end

  # ── unit tests ─────────────────────────────────────────────────────────────

  test "list/0 returns non-empty list of maps" do
    carts = BojRest.Catalog.list()
    assert is_list(carts)
    assert length(carts) > 0
    assert Enum.all?(carts, &is_map/1)
  end

  test "every cartridge has required string fields" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      assert is_binary(Map.get(cart, "name")),    "#{inspect(cart)} missing name"
      assert is_binary(Map.get(cart, "version")), "#{Map.get(cart, "name")} missing version"
      assert is_binary(Map.get(cart, "domain")),  "#{Map.get(cart, "name")} missing domain"
    end)
  end

  test "every cartridge has a tools list" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      name = Map.get(cart, "name")
      tools = Map.get(cart, "tools")
      assert is_list(tools), "#{name} tools is not a list"
      assert length(tools) > 0, "#{name} has no tools"
    end)
  end

  test "every tool has name and description" do
    BojRest.Catalog.list()
    |> Enum.flat_map(fn cart -> Map.get(cart, "tools", []) end)
    |> Enum.each(fn tool ->
      assert is_binary(Map.get(tool, "name")),        "tool missing name: #{inspect(tool)}"
      assert is_binary(Map.get(tool, "description")), "tool missing description: #{inspect(tool)}"
    end)
  end

  test "cartridge names are unique" do
    names = BojRest.Catalog.list() |> Enum.map(&Map.get(&1, "name"))
    assert names == Enum.uniq(names)
  end

  test "get/1 returns :not_found for unknown name" do
    assert :not_found = BojRest.Catalog.get("__definitely_not_a_real_cartridge__")
  end

  test "get/1 returns {:ok, cart} for boj-health" do
    assert {:ok, cart} = BojRest.Catalog.get("boj-health")
    assert cart["name"] == "boj-health"
    assert Map.has_key?(cart, "ffi")
  end

  test "get/1 returns {:ok, cart} for model-router-mcp" do
    assert {:ok, cart} = BojRest.Catalog.get("model-router-mcp")
    assert cart["name"] == "model-router-mcp"
    refute Map.has_key?(cart, "ffi")
  end

  # ── property-style invariants ──────────────────────────────────────────────

  test "ffi cartridges have so_path string" do
    BojRest.Catalog.list()
    |> Enum.filter(&Map.has_key?(&1, "ffi"))
    |> Enum.each(fn cart ->
      assert is_binary(get_in(cart, ["ffi", "so_path"])),
             "#{cart["name"]} ffi.so_path is not a string"
    end)
  end

  test "auth method is always a known value" do
    known = ["none", "api-key", "api_key_header", "bearer", "bearer_token",
             "oauth", "oauth2", "session-token", "basic"]
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      method = get_in(cart, ["auth", "method"])
      assert method in known,
             "#{cart["name"]} has unknown auth.method: #{method}"
    end)
  end

  test "tier is always a known value" do
    known = ["Ayo", "Umoja", "Teranga", "Shield"]
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      tier = Map.get(cart, "tier")
      assert tier in known, "#{cart["name"]} has unknown tier: #{tier}"
    end)
  end

  # ── edge cases ─────────────────────────────────────────────────────────────

  test "list/0 count is stable (idempotent)" do
    count1 = length(BojRest.Catalog.list())
    count2 = length(BojRest.Catalog.list())
    assert count1 == count2
  end

  test "list/0 returns more than 100 cartridges" do
    assert length(BojRest.Catalog.list()) > 100
  end

  test "all cartridge names are lowercase-alphanumeric with hyphens" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      name = cart["name"]
      assert String.match?(name, ~r/^[a-z0-9][a-z0-9\-]*[a-z0-9]$/) or
             String.match?(name, ~r/^[a-z0-9]$/),
             "#{name} does not match expected naming pattern"
    end)
  end

  test "boj-health has loopback configuration" do
    {:ok, cart} = BojRest.Catalog.get("boj-health")
    assert Map.has_key?(cart, "loopback") or Map.has_key?(cart, "ffi"),
           "boj-health missing both loopback and ffi config"
  end

  test "catalog not found for empty string" do
    assert :not_found = BojRest.Catalog.get("")
  end

  test "catalog not found for nil-like string" do
    assert :not_found = BojRest.Catalog.get("nil")
  end

  test "every version string is non-empty" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      version = cart["version"]
      assert is_binary(version) and byte_size(version) > 0,
             "#{cart["name"]} has empty version"
    end)
  end

  # ── schema completeness ────────────────────────────────────────────────────

  test "every cartridge has a non-empty description" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      desc = Map.get(cart, "description")
      assert is_binary(desc) and byte_size(desc) > 0,
             "#{cart["name"]} missing description"
    end)
  end

  test "every cartridge has an auth map" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      assert is_map(Map.get(cart, "auth")),
             "#{cart["name"]} missing auth map"
    end)
  end

  test "every cartridge has an spdx string" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      assert is_binary(Map.get(cart, "spdx")),
             "#{cart["name"]} missing spdx field"
    end)
  end

  test "adapter cartridges have runtime and entry fields" do
    BojRest.Catalog.list()
    |> Enum.filter(&Map.has_key?(&1, "adapter"))
    |> Enum.each(fn cart ->
      assert is_binary(get_in(cart, ["adapter", "runtime"])),
             "#{cart["name"]} adapter.runtime is not a string"
      assert is_binary(get_in(cart, ["adapter", "entry"])),
             "#{cart["name"]} adapter.entry is not a string"
    end)
  end

  test "get/1 for model-router-mcp returns cart with matching name" do
    {:ok, cart} = BojRest.Catalog.get("model-router-mcp")
    assert cart["name"] == "model-router-mcp"
  end

  test "list/0 first element is a map with required keys" do
    first = List.first(BojRest.Catalog.list())
    assert is_map(first)
    assert is_binary(first["name"])
    assert is_binary(first["version"])
  end

  test "every cartridge name is non-empty and not whitespace-only" do
    BojRest.Catalog.list()
    |> Enum.each(fn cart ->
      name = cart["name"]
      assert is_binary(name) and String.trim(name) != "",
             "cartridge has blank name: #{inspect(name)}"
    end)
  end
end
