# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.CatalogPropertiesTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @cartridges_root System.get_env("BOJ_CARTRIDGES_PATH") || Path.expand("../../cartridges", __DIR__)

  setup_all do
    case Process.whereis(BojRest.Catalog) do
      nil -> start_supervised!({BojRest.Catalog, cartridges_root: @cartridges_root})
      _pid -> :ok
    end
    :ok
  end

  # ── round-trip property ───────────────────────────────────────────────────

  property "get(name) round-trips for every cartridge in list/0" do
    carts = BojRest.Catalog.list()
    check all cart <- StreamData.member_of(carts) do
      name = cart["name"]
      assert {:ok, fetched} = BojRest.Catalog.get(name)
      assert fetched["name"] == name
    end
  end

  property "get(name) tools match list/0 tools for the same cartridge" do
    carts = BojRest.Catalog.list()
    check all cart <- StreamData.member_of(carts) do
      {:ok, fetched} = BojRest.Catalog.get(cart["name"])
      assert fetched["tools"] == cart["tools"]
    end
  end

  # ── structural invariants (StreamData over the live catalogue) ─────────────

  property "all cartridge names are non-empty strings" do
    carts = BojRest.Catalog.list()
    check all cart <- StreamData.member_of(carts) do
      name = cart["name"]
      assert is_binary(name)
      assert byte_size(name) > 0
    end
  end

  property "all cartridge versions are semver-like" do
    carts = BojRest.Catalog.list()
    check all cart <- StreamData.member_of(carts) do
      version = cart["version"]
      assert is_binary(version)
      assert String.match?(version, ~r/^\d+\.\d+\.\d+/),
             "#{cart["name"]} version #{version} is not semver-like"
    end
  end

  property "all tools have non-empty name and description" do
    carts = BojRest.Catalog.list()
    all_tools = Enum.flat_map(carts, fn c -> Enum.map(c["tools"], &{c["name"], &1}) end)
    check all {cart_name, tool} <- StreamData.member_of(all_tools) do
      assert is_binary(tool["name"]) and byte_size(tool["name"]) > 0,
             "#{cart_name} tool missing name"
      assert is_binary(tool["description"]) and byte_size(tool["description"]) > 0,
             "#{cart_name} tool missing description"
    end
  end

  property "auth method is always a known value for all cartridges" do
    known = ~w[none api-key api_key api_key_header api_token bearer bearer_token oauth oauth2 session-token basic mtls custom optional_bearer optional_api_key]
    carts = BojRest.Catalog.list()
    check all cart <- StreamData.member_of(carts) do
      method = get_in(cart, ["auth", "method"])
      assert method in known,
             "#{cart["name"]} has unexpected auth.method: #{inspect(method)}"
    end
  end

  property "tier is always a known value for all cartridges" do
    known = ["Ayo", "Umoja", "Teranga", "Shield"]
    carts = BojRest.Catalog.list()
    check all cart <- StreamData.member_of(carts) do
      tier = cart["tier"]
      assert tier in known,
             "#{cart["name"]} has unexpected tier: #{inspect(tier)}"
    end
  end

  # ── CredentialDecryptor properties (StreamData generators) ────────────────

  property "plaintext map with all string values from loopback always passes" do
    check all pairs <- StreamData.list_of(
                         StreamData.tuple({StreamData.string(:alphanumeric, min_length: 1),
                                          StreamData.string(:alphanumeric)}),
                         min_length: 0, max_length: 10
                       ) do
      creds = Map.new(pairs)
      result = BojRest.CredentialDecryptor.extract(%{"credentials" => creds}, true)
      assert {:ok, returned} = result
      assert returned == creds
    end
  end

  property "plaintext map with a non-string value always fails validation" do
    check all key <- StreamData.string(:alphanumeric, min_length: 1),
              non_string <- StreamData.one_of([StreamData.integer(), StreamData.boolean(),
                                               StreamData.list_of(StreamData.integer())]) do
      bad_map = %{key => non_string}
      result = BojRest.CredentialDecryptor.extract(%{"credentials" => bad_map}, true)
      assert {:error, _} = result
    end
  end

  property "get/1 never crashes on arbitrary string input" do
    check all name <- StreamData.string(:utf8, max_length: 200) do
      result = BojRest.Catalog.get(name)
      assert result == :not_found or match?({:ok, _}, result)
    end
  end
end
