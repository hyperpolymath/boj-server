# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @cartridges_root Path.expand("../../cartridges", __DIR__)
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

  # ── health ─────────────────────────────────────────────────────────────────

  test "GET /health returns ok with no mode field" do
    conn = conn(:get, "/health") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    refute Map.has_key?(body, "mode"), "mode field should not be present"
    assert is_integer(body["cartridges_loaded"])
    assert body["cartridges_loaded"] > 0
    assert is_binary(body["version"])
  end

  # ── menu ───────────────────────────────────────────────────────────────────

  test "GET /menu returns cartridges with name/domain/tier/description" do
    conn = conn(:get, "/menu") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["cartridges"])
    assert body["count"] == length(body["cartridges"])
    Enum.each(body["cartridges"], fn c ->
      assert is_binary(c["name"]),   "menu entry missing name"
      assert is_binary(c["domain"]), "#{c["name"]} missing domain"
      assert is_binary(c["tier"]),   "#{c["name"]} missing tier"
    end)
  end

  # ── cartridges list ────────────────────────────────────────────────────────

  test "GET /cartridges lists names with correct count" do
    conn = conn(:get, "/cartridges") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["cartridges"])
    assert body["count"] == length(body["cartridges"])
    assert Enum.all?(body["cartridges"], &is_binary/1)
  end

  # ── single cartridge ───────────────────────────────────────────────────────

  test "GET /cartridge/boj-health returns metadata" do
    conn = conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "boj-health"
    assert Map.has_key?(body, "ffi")
  end

  test "GET /cartridge/model-router-mcp returns metadata without ffi" do
    conn = conn(:get, "/cartridge/model-router-mcp") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "model-router-mcp"
    refute Map.has_key?(body, "ffi")
  end

  test "GET /cartridge/unknown-xyz-999 is 404" do
    conn = conn(:get, "/cartridge/unknown-xyz-999") |> BojRest.Router.call(@opts)
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "unknown-cartridge"
  end

  # ── node pubkey ────────────────────────────────────────────────────────────

  test "GET /.well-known/boj-node-pubkey returns pubkey envelope" do
    conn = conn(:get, "/.well-known/boj-node-pubkey") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["pubkey"]), "pubkey should be a base64url string"
    assert body["algorithm"] == "x25519"
    assert body["version"] == 1
    # X25519 pubkey is 32 bytes → 43 base64url chars (no padding)
    assert byte_size(body["pubkey"]) == 43
  end

  # ── invoke — error paths ───────────────────────────────────────────────────

  test "POST /cartridge/unknown-xyz/invoke is 404" do
    conn =
      conn(:post, "/cartridge/unknown-xyz-999/invoke", Jason.encode!(%{tool: "noop"}))
      |> put_req_header("content-type", "application/json")
      |> BojRest.Router.call(@opts)

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "unknown-cartridge"
  end

  test "POST /cartridge/model-router-mcp/invoke without tool field is 400" do
    conn =
      conn(:post, "/cartridge/model-router-mcp/invoke", Jason.encode!(%{arguments: %{}}))
      |> put_req_header("content-type", "application/json")
      |> BojRest.Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "missing-tool-field"
  end

  # ── invoke — JS cartridge E2E ──────────────────────────────────────────────

  @tag :e2e
  test "POST /cartridge/model-router-mcp/invoke classify_task returns result" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        conn =
          conn(
            :post,
            "/cartridge/model-router-mcp/invoke",
            Jason.encode!(%{
              tool: "classify_task",
              arguments: %{task: "Summarise a PDF document"}
            })
          )
          |> put_req_header("content-type", "application/json")
          |> BojRest.Router.call(@opts)

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert is_map(body)
    end
  end

  # ── catch-all ──────────────────────────────────────────────────────────────

  test "unknown route returns 404" do
    conn = conn(:get, "/nonsense/path/here") |> BojRest.Router.call(@opts)
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "route-not-found"
  end
end
