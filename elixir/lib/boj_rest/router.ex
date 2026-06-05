# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.Router do
  @moduledoc """
  Plug router for the five HTTP endpoints:

      GET  /health                    — liveness + cartridge count
      GET  /menu                      — full cartridge catalogue (name/domain/tier/description)
      GET  /cartridges                — cartridge name list
      GET  /cartridge/:name           — single cartridge metadata (cartridge.json contents)
      POST /cartridge/:name/invoke    — dispatch a tool call to a cartridge

  Dispatch on POST /invoke branches on the cartridge manifest:
    - cart["ffi"] present  → BojRest.Invoker   (Zig .so via boj-invoke CLI)
    - cart["ffi"] absent   → BojRest.JsInvoker (mod.js via Deno runner)

  Caller auth uses the `X-Trust-Level` header set by the gateway sidecar:
    - `"internal"` / `"authenticated"` satisfies cartridges that need credentials
    - `"public"` / absent satisfies only `auth.method: "none"` cartridges
  Loopback callers bypass enforcement (local dev / mcp-bridge).
  `X-Node-Identity` is logged for audit purposes when present.
  See `BojRest.TrustPolicy` and docs/AUTH-DESIGN.adoc for full topology.
  """
  use Plug.Router
  require Logger

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  @version Mix.Project.config()[:version]

  # Node's X25519 public key — callers use this to encrypt per-invocation
  # credentials (Option A, docs/AUTH-DESIGN.adoc).
  get "/.well-known/boj-node-pubkey" do
    pub_b64 = Base.url_encode64(BojRest.NodeKey.public_key(), padding: false)
    json(conn, 200, %{pubkey: pub_b64, algorithm: "x25519", version: 1})
  end

  get "/health" do
    body =
      %{
        status: "ok",
        version: @version,
        cartridges_loaded: length(BojRest.Catalog.list())
      }
    json(conn, 200, body)
  end

  get "/menu" do
    carts = BojRest.Catalog.list()

    # `available` is the catalog's load-bearing truth claim: true ONLY when the
    # cartridge is built and its tools return real results (verified in CI by the
    # truthfulness invariant). The default is false — a cartridge must opt in by
    # asserting `"available": true` in its cartridge.json, never the reverse —
    # so a newly-catalogued stub is never advertised as working by omission.
    summary_of = fn c ->
      %{
        name: Map.get(c, "name"),
        version: Map.get(c, "version"),
        domain: Map.get(c, "domain"),
        protocols: Map.get(c, "protocols", []),
        status: Map.get(c, "status", "catalogued"),
        available: Map.get(c, "available", false),
        description: Map.get(c, "description")
      }
    end

    # Group by the cartridge's declared tier (Teranga / Shield / Ayo),
    # case-folded, into the tiered MenuResponse shape openapi.yaml documents
    # and the mcp-bridge offline menu already uses.
    tier_of = fn c -> c |> Map.get("tier", "") |> to_string() |> String.downcase() end
    grouped = Enum.group_by(carts, tier_of, summary_of)

    json(conn, 200, %{
      tier_teranga: Map.get(grouped, "teranga", []),
      tier_shield: Map.get(grouped, "shield", []),
      tier_ayo: Map.get(grouped, "ayo", []),
      summary: %{
        total: length(carts),
        ready: Enum.count(carts, fn c -> Map.get(c, "available", false) end),
        mounted: length(carts)
      }
    })
  end

  get "/cartridges" do
    names = BojRest.Catalog.list() |> Enum.map(&Map.get(&1, "name"))
    json(conn, 200, %{cartridges: names, count: length(names)})
  end

  get "/cartridge/:name" do
    case BojRest.Catalog.get(name) do
      {:ok, cart} -> json(conn, 200, cart)
      :not_found -> json(conn, 404, %{error: "unknown-cartridge", cartridge: name})
    end
  end

  post "/cartridge/:name/invoke" do
    case BojRest.Catalog.get(name) do
      {:ok, cart} ->
        body = conn.body_params || %{}
        # Accept both canonical ("tool"/"arguments") and echidna-style
        # ("operation"/"params") field names so callers need not adapt.
        tool = Map.get(body, "tool") || Map.get(body, "operation")
        args = Map.get(body, "arguments") || Map.get(body, "params") || %{}
        is_local = loopback?(conn.remote_ip)
        trust_level = conn |> get_req_header("x-trust-level") |> List.first()
        node_id = conn |> get_req_header("x-node-identity") |> List.first()

        if node_id, do: Logger.info("BoJ invoke caller=#{node_id} cart=#{name} tool=#{inspect(tool)}")

        with false <- is_nil(tool),
             :ok <- check_trust(cart, trust_level, is_local),
             {:ok, creds} <- BojRest.CredentialDecryptor.extract(body, is_local) do
          case dispatch(cart, tool, args, creds) do
            {:ok, data} ->
              json(conn, 200, data)

            {:error, info} ->
              json(conn, 500, %{
                error: "invocation-failed",
                cartridge: name,
                tool: tool,
                info: info
              })
          end
        else
          true ->
            json(conn, 400, %{error: "missing-tool-field", cartridge: name})

          {:error, :forbidden, required} ->
            json(conn, 403, %{
              error: "forbidden",
              detail: "insufficient-trust",
              required: to_string(required)
            })

          {:error, reason} ->
            json(conn, 403, %{error: "credential-error", detail: reason})
        end

      :not_found ->
        json(conn, 404, %{error: "unknown-cartridge", cartridge: name})
    end
  end

  # Server-Sent Events surface for the same unified dispatch. The cartridge
  # ABI is request/response (one boj_cartridge_invoke buffer), so the stream
  # is: `open` → `result`|`error` → `done`. This makes the unified surface
  # genuinely four-protocol (REST + SSE here; gRPC-compat + GraphQL in the
  # per-cartridge Zig adapter).
  post "/cartridge/:name/sse" do
    case BojRest.Catalog.get(name) do
      {:ok, cart} ->
        body = conn.body_params || %{}
        tool = Map.get(body, "tool") || Map.get(body, "operation")
        args = Map.get(body, "arguments") || Map.get(body, "params") || %{}
        is_local = loopback?(conn.remote_ip)
        trust_level = conn |> get_req_header("x-trust-level") |> List.first()
        node_id = conn |> get_req_header("x-node-identity") |> List.first()

        if node_id, do: Logger.info("BoJ SSE caller=#{node_id} cart=#{name} tool=#{inspect(tool)}")

        cond do
          is_nil(tool) ->
            json(conn, 400, %{error: "missing-tool-field", cartridge: name})

          true ->
            with :ok <- check_trust(cart, trust_level, is_local),
                 {:ok, creds} <- BojRest.CredentialDecryptor.extract(body, is_local) do
              conn =
                conn
                |> Plug.Conn.put_resp_content_type("text/event-stream")
                |> Plug.Conn.put_resp_header("cache-control", "no-cache")
                |> Plug.Conn.send_chunked(200)

              {:ok, conn} = Plug.Conn.chunk(conn, sse_event("open", %{cartridge: name, tool: tool}))

              event =
                case dispatch(cart, tool, args, creds) do
                  {:ok, data} -> sse_event("result", data)
                  {:error, info} -> sse_event("error", %{error: "invocation-failed", info: info})
                end

              {:ok, conn} = Plug.Conn.chunk(conn, event)
              {:ok, conn} = Plug.Conn.chunk(conn, sse_event("done", %{}))
              conn
            else
              {:error, :forbidden, required} ->
                json(conn, 403, %{error: "forbidden", detail: "insufficient-trust", required: to_string(required)})

              {:error, reason} ->
                json(conn, 403, %{error: "credential-error", detail: reason})
            end
        end

      :not_found ->
        json(conn, 404, %{error: "unknown-cartridge", cartridge: name})
    end
  end

  match _ do
    json(conn, 404, %{error: "route-not-found", path: conn.request_path})
  end

  # One SSE frame: `event: <name>\ndata: <json>\n\n` (text/event-stream).
  defp sse_event(event, data) do
    "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp dispatch(cart, tool, args, creds) do
    if Map.has_key?(cart, "ffi") do
      BojRest.Invoker.invoke(cartridge_so_path(cart), tool, args, creds)
    else
      # JsWorkerPool.invoke falls back to JsInvoker.invoke when pool is absent.
      BojRest.JsWorkerPool.invoke(cartridge_mod_path(cart), tool, args, creds)
    end
  end

  defp check_trust(cart, trust_header, is_local) do
    required = BojRest.TrustPolicy.required_exposure(cart)
    if BojRest.TrustPolicy.satisfies?(required, trust_header, is_local) do
      :ok
    else
      {:error, :forbidden, required}
    end
  end

  # True for IPv4 loopback (127.x.x.x) and IPv6 loopback (::1).
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  # Read .so path directly from the manifest's ffi.so_path field.
  defp cartridge_so_path(cart) do
    root = Application.get_env(:boj_rest, :cartridges_root)
    name = Map.get(cart, "name")
    so_rel = get_in(cart, ["ffi", "so_path"])
    Path.join([root, name, so_rel])
  end

  # mod.js lives at <cartridges_root>/<name>/mod.js by convention.
  defp cartridge_mod_path(cart) do
    root = Application.get_env(:boj_rest, :cartridges_root)
    name = Map.get(cart, "name")
    Path.join([root, name, "mod.js"])
  end
end
