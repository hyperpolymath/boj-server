# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Contract tests — verify the interface boundaries between modules.
# Each describe block names a boundary pair.
defmodule BojRest.ContractTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @cartridges_root System.get_env("BOJ_CARTRIDGES_PATH") || Path.expand("../../cartridges", __DIR__)
  @opts BojRest.Router.init([])

  setup_all do
    case Process.whereis(BojRest.NodeKey) do
      nil -> start_supervised!({BojRest.NodeKey, data_dir: System.tmp_dir!()})
      _pid -> :ok
    end
    case Process.whereis(BojRest.Catalog) do
      nil -> start_supervised!({BojRest.Catalog, cartridges_root: @cartridges_root})
      _pid -> :ok
    end
    :ok
  end

  # ── Catalog ↔ Router ──────────────────────────────────────────────────────

  describe "Catalog ↔ Router" do
    test "every name in Catalog.list/0 is reachable at GET /cartridge/:name" do
      names = BojRest.Catalog.list() |> Enum.map(& &1["name"])
      Enum.each(names, fn name ->
        conn = conn(:get, "/cartridge/#{name}") |> BojRest.Router.call(@opts)
        assert conn.status == 200, "Expected 200 for /cartridge/#{name}, got #{conn.status}"
      end)
    end

    test "GET /cartridges count equals Catalog.list/0 length" do
      catalog_count = length(BojRest.Catalog.list())
      conn = conn(:get, "/cartridges") |> BojRest.Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      assert body["count"] == catalog_count
    end

    test "GET /menu entries are all present in Catalog.list/0 names" do
      catalog_names = BojRest.Catalog.list() |> MapSet.new(& &1["name"])
      conn = conn(:get, "/menu") |> BojRest.Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      # Tiered MenuResponse: entries live in the three tier buckets, not a
      # flat `cartridges` list (that shape is /cartridges).
      entries = body["tier_teranga"] ++ body["tier_shield"] ++ body["tier_ayo"]
      assert entries != [], "expected at least one catalogued cartridge"
      Enum.each(entries, fn entry ->
        assert MapSet.member?(catalog_names, entry["name"]),
               "Menu entry #{entry["name"]} not found in Catalog"
      end)
    end

    test "Catalog.get/1 and Router GET /cartridge/:name return the same name" do
      {:ok, cart} = BojRest.Catalog.get("boj-health")
      conn = conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == cart["name"]
    end
  end

  # ── NodeKey ↔ CredentialDecryptor ─────────────────────────────────────────

  describe "NodeKey ↔ CredentialDecryptor" do
    test "NodeKey public key can be retrieved via Router pubkey endpoint" do
      node_pub = BojRest.NodeKey.public_key()
      conn = conn(:get, "/.well-known/boj-node-pubkey") |> BojRest.Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      encoded = Base.url_encode64(node_pub, padding: false)
      assert body["pubkey"] == encoded
    end

    test "ECDH round-trip: encrypt with node pubkey, CredentialDecryptor decrypts it" do
      node_pub = BojRest.NodeKey.public_key()
      {caller_pub, caller_priv} = :crypto.generate_key(:ecdh, :x25519)
      shared = :crypto.compute_key(:ecdh, node_pub, caller_priv, :x25519)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = Jason.encode!(%{"API_KEY" => "test-secret"})
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:chacha20_poly1305, shared, nonce, plaintext, "boj-invoke-v1", true)

      body = %{
        "credentials" => %{
          "v" => 1,
          "encrypted" => true,
          "caller_pubkey" => Base.url_encode64(caller_pub, padding: false),
          "nonce" => Base.url_encode64(nonce, padding: false),
          "ciphertext" => Base.url_encode64(ciphertext <> tag, padding: false)
        }
      }

      assert {:ok, %{"API_KEY" => "test-secret"}} =
               BojRest.CredentialDecryptor.extract(body, false)
    end

    test "CredentialDecryptor with wrong node key returns error" do
      # Generate a different server keypair
      {wrong_pub, _wrong_priv} = :crypto.generate_key(:ecdh, :x25519)
      {caller_pub, caller_priv} = :crypto.generate_key(:ecdh, :x25519)

      # Encrypt against the wrong pubkey (not the real node key)
      shared = :crypto.compute_key(:ecdh, wrong_pub, caller_priv, :x25519)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = Jason.encode!(%{"KEY" => "value"})
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:chacha20_poly1305, shared, nonce, plaintext, "boj-invoke-v1", true)

      body = %{
        "credentials" => %{
          "v" => 1,
          "encrypted" => true,
          "caller_pubkey" => Base.url_encode64(caller_pub, padding: false),
          "nonce" => Base.url_encode64(nonce, padding: false),
          "ciphertext" => Base.url_encode64(ciphertext <> tag, padding: false)
        }
      }

      assert {:error, _} = BojRest.CredentialDecryptor.extract(body, false)
    end
  end

  # ── Router ↔ Invoker dispatch ──────────────────────────────────────────────

  describe "Router ↔ Invoker dispatch" do
    test "missing tool field always returns 400 regardless of cartridge type" do
      ["boj-health", "model-router-mcp"]
      |> Enum.each(fn name ->
        conn =
          conn(:post, "/cartridge/#{name}/invoke", Jason.encode!(%{}))
          |> put_req_header("content-type", "application/json")
          |> BojRest.Router.call(@opts)

        assert conn.status == 400,
               "Expected 400 for #{name} with missing tool, got #{conn.status}"
      end)
    end

    test "unknown cartridge name always returns 404 on invoke" do
      conn =
        conn(:post, "/cartridge/__no_such_cart__/invoke", Jason.encode!(%{tool: "x"}))
        |> put_req_header("content-type", "application/json")
        |> BojRest.Router.call(@opts)

      assert conn.status == 404
    end

    test "GET verb on invoke path returns 404" do
      conn = conn(:get, "/cartridge/model-router-mcp/invoke") |> BojRest.Router.call(@opts)
      assert conn.status == 404
    end
  end

  # ── JsInvoker ↔ JS runner ─────────────────────────────────────────────────

  describe "JsInvoker ↔ JS runner" do
    test "deno_path/0 returns nil or a binary" do
      result = BojRest.JsInvoker.deno_path()
      assert is_nil(result) or is_binary(result)
    end

    test "invoke with non-existent mod returns :mod_missing" do
      result = BojRest.JsInvoker.invoke("/nonexistent/mod.js", "anything", %{})
      assert {:error, %{classification: :mod_missing}} = result
    end

    test "invoke returns error map with classification key" do
      result = BojRest.JsInvoker.invoke("/nonexistent/mod.js", "anything", %{})
      assert {:error, err} = result
      assert Map.has_key?(err, :classification)
    end
  end
end
