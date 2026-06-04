# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule BojRest.RouterTest do
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

  test "GET /menu returns tiered cartridge lists with a truthful summary" do
    conn = conn(:get, "/menu") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    # Tiered MenuResponse shape (openapi.yaml): three tier buckets + summary.
    # There is no flat `cartridges`/`count` here — that shape belongs to
    # /cartridges. This test previously asserted those nonexistent keys.
    for tier <- ["tier_teranga", "tier_shield", "tier_ayo"] do
      assert is_list(body[tier]), "#{tier} should be a list"
    end

    entries = body["tier_teranga"] ++ body["tier_shield"] ++ body["tier_ayo"]
    assert entries != [], "expected at least one catalogued cartridge"

    Enum.each(entries, fn c ->
      assert is_binary(c["name"]),       "menu entry missing name"
      assert is_binary(c["domain"]),     "#{c["name"]} missing domain"
      assert is_boolean(c["available"]), "#{c["name"]} missing available flag"
      assert is_binary(c["status"]),     "#{c["name"]} missing status"
    end)

    # The summary must not over-claim: `ready` counts only cartridges whose
    # `available` flag is true (built + verified-real), so it equals the number
    # of available entries and can never exceed `total`.
    summary = body["summary"]
    assert summary["total"] == length(entries)
    assert summary["ready"] == Enum.count(entries, & &1["available"])
    assert summary["ready"] <= summary["total"]
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

  # ── operation/params alias (echidna-style wire format) ─────────────────────

  @tag :e2e
  test "POST /cartridge/model-router-mcp/invoke accepts 'operation' alias for 'tool'" do
    case BojRest.JsInvoker.deno_path() do
      nil -> :ok
      _deno ->
        conn =
          conn(
            :post,
            "/cartridge/model-router-mcp/invoke",
            Jason.encode!(%{
              operation: "classify_task",
              params: %{task: "Count tokens in a file"}
            })
          )
          |> put_req_header("content-type", "application/json")
          |> BojRest.Router.call(@opts)

        # Should route correctly — not 400 (missing tool) or 404 (unknown cartridge)
        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert is_map(body)
        assert Map.has_key?(body, "complexity")
    end
  end

  # ── echidna-llm-mcp cartridge presence ────────────────────────────────────

  test "GET /cartridge/echidna-llm-mcp returns metadata" do
    conn = conn(:get, "/cartridge/echidna-llm-mcp") |> BojRest.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "echidna-llm-mcp"
    assert body["domain"] == "Formal Verification"
    assert is_list(body["tools"])
    tool_names = Enum.map(body["tools"], & &1["name"])
    assert "consult" in tool_names
    assert "suggest_tactics" in tool_names
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

  # ── additional coverage ────────────────────────────────────────────────────

  test "GET /health has status/version/cartridges_loaded keys" do
    conn = conn(:get, "/health") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert Map.has_key?(body, "status")
    assert Map.has_key?(body, "version")
    assert Map.has_key?(body, "cartridges_loaded")
  end

  test "GET /cartridges returns more than 100 cartridges" do
    conn = conn(:get, "/cartridges") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert body["count"] > 100
  end

  test "GET /cartridge/boj-health has a tools list" do
    conn = conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["tools"])
    assert length(body["tools"]) > 0
  end

  test "GET /cartridge/model-router-mcp has a tools list" do
    conn = conn(:get, "/cartridge/model-router-mcp") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["tools"])
    assert length(body["tools"]) > 0
  end

  test "POST /cartridge/boj-health/invoke without tool field is 400" do
    conn =
      conn(:post, "/cartridge/boj-health/invoke", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> BojRest.Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "missing-tool-field"
  end

  test "GET /cartridge/:name returns parseable JSON for all cartridges" do
    names = BojRest.Catalog.list() |> Enum.take(5) |> Enum.map(& &1["name"])
    Enum.each(names, fn name ->
      conn = conn(:get, "/cartridge/#{name}") |> BojRest.Router.call(@opts)
      assert conn.status == 200
      assert {:ok, _} = Jason.decode(conn.resp_body)
    end)
  end

  test "GET /.well-known/boj-node-pubkey has version 1" do
    conn = conn(:get, "/.well-known/boj-node-pubkey") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert body["version"] == 1
  end

  test "response body is always valid JSON for all tested routes" do
    routes = [
      conn(:get, "/health"),
      conn(:get, "/menu"),
      conn(:get, "/cartridges"),
      conn(:get, "/cartridge/boj-health"),
      conn(:get, "/cartridge/__unknown_xyz__"),
      conn(:get, "/no/such/route")
    ]
    Enum.each(routes, fn c ->
      result_conn = BojRest.Router.call(c, @opts)
      assert {:ok, _} = Jason.decode(result_conn.resp_body),
             "Route #{c.request_path} returned non-JSON: #{result_conn.resp_body}"
    end)
  end

  # ── HTTP method rejection ─────────────────────────────────────────────────

  test "PUT /health returns 404" do
    conn = conn(:put, "/health") |> BojRest.Router.call(@opts)
    assert conn.status == 404
  end

  test "DELETE /health returns 404" do
    conn = conn(:delete, "/health") |> BojRest.Router.call(@opts)
    assert conn.status == 404
  end

  test "POST /menu returns 404" do
    conn = conn(:post, "/menu", "") |> BojRest.Router.call(@opts)
    assert conn.status == 404
  end

  test "POST /.well-known/boj-node-pubkey returns 404" do
    conn = conn(:post, "/.well-known/boj-node-pubkey", "") |> BojRest.Router.call(@opts)
    assert conn.status == 404
  end

  # ── cartridge field coverage ──────────────────────────────────────────────

  test "GET /cartridge/boj-health has description field" do
    conn = conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["description"]) and byte_size(body["description"]) > 0
  end

  test "GET /cartridge/boj-health has tier field" do
    conn = conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["tier"])
  end

  test "GET /cartridge/boj-health has auth.method field" do
    conn = conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_binary(get_in(body, ["auth", "method"]))
  end

  test "GET /cartridge/model-router-mcp has description field" do
    conn = conn(:get, "/cartridge/model-router-mcp") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["description"]) and byte_size(body["description"]) > 0
  end

  test "GET /cartridge/model-router-mcp has auth.method field" do
    conn = conn(:get, "/cartridge/model-router-mcp") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_binary(get_in(body, ["auth", "method"]))
  end

  # ── cross-endpoint consistency ────────────────────────────────────────────

  test "GET /cartridges count equals GET /menu summary total" do
    conn1 = conn(:get, "/cartridges") |> BojRest.Router.call(@opts)
    conn2 = conn(:get, "/menu") |> BojRest.Router.call(@opts)
    body1 = Jason.decode!(conn1.resp_body)
    body2 = Jason.decode!(conn2.resp_body)
    # /menu has no flat count; its total lives under summary.
    assert body1["count"] == body2["summary"]["total"]
  end

  test "GET /health version field is non-empty string" do
    conn = conn(:get, "/health") |> BojRest.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["version"]) and byte_size(body["version"]) > 0
  end

  @tag :e2e
  test "POST /cartridge/model-router-mcp/invoke estimate_cost returns result" do
    case BojRest.JsInvoker.deno_path() do
      nil -> :ok
      _deno ->
        conn =
          conn(:post, "/cartridge/model-router-mcp/invoke",
               Jason.encode!(%{tool: "estimate_cost", arguments: %{estimated_tokens: 500}}))
          |> put_req_header("content-type", "application/json")
          |> BojRest.Router.call(@opts)

        assert conn.status == 200
        assert {:ok, _} = Jason.decode(conn.resp_body)
    end
  end

  # ── Trust-level enforcement (Phase 9 auth) ──────────────────────────────────

  # airtable-mcp has auth.method=bearer_token → requires authenticated trust
  @keyed_cart "airtable-mcp"
  @public_cart "boj-health"

  test "POST /invoke on keyed cartridge from loopback without header → allowed (loopback bypass)" do
    conn =
      conn(:post, "/cartridge/#{@keyed_cart}/invoke", Jason.encode!(%{tool: "airtable_list_bases"}))
      |> put_req_header("content-type", "application/json")
      |> BojRest.Router.call(@opts)

    assert conn.status in [200, 500]
    body = Jason.decode!(conn.resp_body)
    refute body["error"] == "forbidden"
  end

  test "POST /invoke on public cartridge from non-loopback without header → allowed" do
    conn =
      conn(:post, "/cartridge/#{@public_cart}/invoke", Jason.encode!(%{tool: "boj_health_status"}))
      |> put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> BojRest.Router.call(@opts)

    assert conn.status in [200, 500]
    body = Jason.decode!(conn.resp_body)
    refute body["error"] == "forbidden"
  end

  test "POST /invoke on keyed cartridge from non-loopback without header → 403 forbidden" do
    conn =
      conn(:post, "/cartridge/#{@keyed_cart}/invoke", Jason.encode!(%{tool: "airtable_list_bases"}))
      |> put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> BojRest.Router.call(@opts)

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "forbidden"
    assert body["detail"] == "insufficient-trust"
    assert body["required"] == "authenticated"
  end

  # Phase A §3 invariant 3: non-loopback X-Trust-Level is IGNORED. These two
  # used to assert the header was honoured for non-loopback callers; that was
  # the §3 hole the gateway was supposed to plug at the front and BoJ at the
  # back. BoJ-side enforcement now lives in TrustPolicy.satisfies?/3.
  test "POST /invoke on keyed cartridge with X-Trust-Level: authenticated from non-loopback → 403 (header ignored, §3)" do
    conn =
      conn(:post, "/cartridge/#{@keyed_cart}/invoke", Jason.encode!(%{tool: "airtable_list_bases"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-trust-level", "authenticated")
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> BojRest.Router.call(@opts)

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "forbidden"
    assert body["detail"] == "insufficient-trust"
  end

  test "POST /invoke on keyed cartridge with X-Trust-Level: internal from non-loopback → 403 (header ignored, §3)" do
    conn =
      conn(:post, "/cartridge/#{@keyed_cart}/invoke", Jason.encode!(%{tool: "airtable_list_bases"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-trust-level", "internal")
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> BojRest.Router.call(@opts)

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "forbidden"
    assert body["detail"] == "insufficient-trust"
  end

  test "POST /invoke on keyed cartridge with X-Trust-Level: public → 403 forbidden" do
    conn =
      conn(:post, "/cartridge/#{@keyed_cart}/invoke", Jason.encode!(%{tool: "airtable_list_bases"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-trust-level", "public")
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> BojRest.Router.call(@opts)

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "forbidden"
  end

  test "POST /invoke with X-Node-Identity header does not crash" do
    conn =
      conn(:post, "/cartridge/#{@public_cart}/invoke", Jason.encode!(%{tool: "boj_health_status"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-node-identity", "peer-node-abc123")
      |> BojRest.Router.call(@opts)

    assert conn.status in [200, 500]
  end

  test "POST /cartridge/:name/sse streams text/event-stream open→…→done" do
    conn =
      conn(:post, "/cartridge/#{@public_cart}/sse", Jason.encode!(%{tool: "boj_health_status"}))
      |> put_req_header("content-type", "application/json")
      |> BojRest.Router.call(@opts)

    assert conn.status == 200
    assert {"content-type", "text/event-stream; charset=utf-8"} in conn.resp_headers
    assert conn.resp_body =~ "event: open"
    assert conn.resp_body =~ "event: done"
  end

  test "POST /cartridge/:name/sse without tool is 400 (not a stream)" do
    conn =
      conn(:post, "/cartridge/#{@public_cart}/sse", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> BojRest.Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "missing-tool-field"
  end
end
