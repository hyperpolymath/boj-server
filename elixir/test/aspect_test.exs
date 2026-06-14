# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Aspect tests — cross-cutting concerns: no-crash, content-type, security,
# idempotency, and concurrency.
defmodule BojRest.AspectTest do
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

  # ── No-crash aspect ────────────────────────────────────────────────────────

  describe "no-crash" do
    test "Catalog.get/1 never crashes on arbitrary string input" do
      inputs = ["", " ", "/../", "'; DROP TABLE--", String.duplicate("x", 500),
                "\x00\x01\x02", "a/b/c", "!@#$%^"]
      Enum.each(inputs, fn s ->
        result = BojRest.Catalog.get(s)
        assert result == :not_found or match?({:ok, _}, result)
      end)
    end

    test "Catalog.list/0 safe to call concurrently from 20 tasks" do
      tasks = for _ <- 1..20, do: Task.async(fn -> BojRest.Catalog.list() end)
      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &is_list/1)
      assert length(Enum.uniq_by(results, &length/1)) == 1, "list/0 returned different lengths concurrently"
    end

    test "CredentialDecryptor.extract/2 never crashes on empty body" do
      result = BojRest.CredentialDecryptor.extract(%{}, true)
      assert {:ok, %{}} = result
    end

    test "CredentialDecryptor.extract/2 never crashes on completely malformed input" do
      bad_inputs = [
        %{"credentials" => "not-a-map"},
        %{"credentials" => 42},
        %{"credentials" => %{"encrypted" => true}},
        %{}
      ]
      Enum.each(bad_inputs, fn input ->
        result = BojRest.CredentialDecryptor.extract(input, false)
        assert match?({:error, _}, result) or match?({:ok, _}, result),
               "Expected error or ok tuple, got: #{inspect(result)}"
      end)
    end

    test "NodeKey.public_key/0 safe under 20 concurrent reads" do
      tasks = for _ <- 1..20, do: Task.async(fn -> BojRest.NodeKey.public_key() end)
      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, fn k -> is_binary(k) and byte_size(k) == 32 end)
    end

    test "Router handles POST with empty body without crash" do
      conn =
        conn(:post, "/cartridge/model-router-mcp/invoke", "")
        |> put_req_header("content-type", "application/json")
        |> BojRest.Router.call(@opts)

      assert conn.status in [400, 404, 415, 422]
    end

    test "Router handles POST with non-JSON body without crash" do
      assert_raise Plug.Parsers.ParseError, fn ->
        conn(:post, "/cartridge/model-router-mcp/invoke", "not json at all!!!")
        |> put_req_header("content-type", "application/json")
        |> BojRest.Router.call(@opts)
      end
    end
  end

  # ── Content-type aspect ────────────────────────────────────────────────────

  describe "content-type: all routes return application/json" do
    test "GET /health returns application/json" do
      conn = conn(:get, "/health") |> BojRest.Router.call(@opts)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "GET /menu returns application/json" do
      conn = conn(:get, "/menu") |> BojRest.Router.call(@opts)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "GET /cartridges returns application/json" do
      conn = conn(:get, "/cartridges") |> BojRest.Router.call(@opts)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "GET /cartridge/:name returns application/json" do
      conn = conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(@opts)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "404 responses return application/json" do
      conn = conn(:get, "/no/such/path") |> BojRest.Router.call(@opts)
      assert conn.status == 404
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "400 responses return application/json" do
      conn =
        conn(:post, "/cartridge/model-router-mcp/invoke", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> BojRest.Router.call(@opts)

      assert conn.status == 400
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end
  end

  # ── Security aspect ────────────────────────────────────────────────────────

  describe "security: no key material leakage" do
    test "CredentialDecryptor error message does not contain private key hex" do
      node_priv_hex = BojRest.NodeKey.private_key() |> Base.encode16(case: :lower)

      body = %{
        "credentials" => %{
          "v" => 1,
          "encrypted" => true,
          "caller_pubkey" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
          "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
          "ciphertext" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
        }
      }

      {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
      refute String.contains?(reason, node_priv_hex),
             "Private key hex found in error message"
    end

    test "CredentialDecryptor error message does not contain private key base64" do
      node_priv_b64 = BojRest.NodeKey.private_key() |> Base.url_encode64(padding: false)

      body = %{
        "credentials" => %{
          "v" => 1,
          "encrypted" => true,
          "caller_pubkey" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
          "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
          "ciphertext" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
        }
      }

      {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
      refute String.contains?(reason, node_priv_b64),
             "Private key base64 found in error message"
    end
  end

  # ── Idempotency aspect ─────────────────────────────────────────────────────

  describe "idempotency" do
    test "Catalog.list/0 returns the same result on repeated calls" do
      result1 = BojRest.Catalog.list()
      result2 = BojRest.Catalog.list()
      assert result1 == result2
    end

    test "Catalog.get/1 returns the same result on repeated calls" do
      result1 = BojRest.Catalog.get("boj-health")
      result2 = BojRest.Catalog.get("boj-health")
      assert result1 == result2
    end

    test "NodeKey.public_key/0 returns the same value on repeated calls" do
      assert BojRest.NodeKey.public_key() == BojRest.NodeKey.public_key()
    end

    test "GET /health cartridges_loaded is stable across calls" do
      conn1 = conn(:get, "/health") |> BojRest.Router.call(@opts)
      conn2 = conn(:get, "/health") |> BojRest.Router.call(@opts)
      body1 = Jason.decode!(conn1.resp_body)
      body2 = Jason.decode!(conn2.resp_body)
      assert body1["cartridges_loaded"] == body2["cartridges_loaded"]
    end
  end
end
