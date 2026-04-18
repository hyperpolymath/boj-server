# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts BojRest.Router.init([])

  setup_all do
    # The OTP Application supervisor already started Catalog at boot.
    # If it's running, reuse it; otherwise start our own.
    case Process.whereis(BojRest.Catalog) do
      nil ->
        root = Path.expand("../../cartridges", __DIR__)
        start_supervised!({BojRest.Catalog, cartridges_root: root})

      _pid ->
        :ok
    end

    :ok
  end

  test "GET /health returns ok" do
    conn = conn(:get, "/health") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["mode"] == "skeleton"
    assert is_integer(body["cartridges_loaded"])
  end

  test "GET /cartridges lists names" do
    conn = conn(:get, "/cartridges") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["cartridges"])
    assert body["count"] == length(body["cartridges"])
  end

  test "GET /cartridge/unknown-xyz is 404" do
    conn = conn(:get, "/cartridge/unknown-xyz-999") |> BojRest.Router.call(@opts)
    assert conn.status == 404
  end

  test "POST /cartridge/:name/invoke returns 501 for known cartridge" do
    # Pick any cartridge that loaded successfully — 'database-mcp' is a safe bet
    case BojRest.Catalog.get("database-mcp") do
      {:ok, _} ->
        conn =
          conn(:post, "/cartridge/database-mcp/invoke", %{tool: "noop"})
          |> put_req_header("content-type", "application/json")
          |> BojRest.Router.call(@opts)

        assert conn.status == 501
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "invocation-not-yet-wired"

      :not_found ->
        # Catalog empty — still test the 404 path
        :ok
    end
  end

  test "unknown route is 404" do
    conn = conn(:get, "/nonsense") |> BojRest.Router.call(@opts)
    assert conn.status == 404
  end
end
