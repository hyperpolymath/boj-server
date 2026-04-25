# SPDX-License-Identifier: PMPL-1.0-or-later
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

  Auth note: the invoke endpoint currently has no caller authentication.
  Umoja federation trust is established at the gossip/SDP layer (X25519
  handshake, UDP port 9999) — the HTTP layer has no way to verify a caller
  is an authenticated peer. The http-capability-gateway sidecar (port 7800)
  will enforce verb governance and, via mTLS Phase B, trust-level headers.
  See docs/AUTH-DESIGN.adoc for the full topology and migration plan.
  """
  use Plug.Router

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
    carts =
      BojRest.Catalog.list()
      |> Enum.map(fn c ->
        %{
          name: Map.get(c, "name"),
          domain: Map.get(c, "domain"),
          tier: Map.get(c, "tier"),
          description: Map.get(c, "description")
        }
      end)
    json(conn, 200, %{cartridges: carts, count: length(carts)})
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
        tool = Map.get(body, "tool")
        args = Map.get(body, "arguments") || %{}
        is_local = loopback?(conn.remote_ip)

        with false <- is_nil(tool),
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

          {:error, reason} ->
            json(conn, 403, %{error: "credential-error", detail: reason})
        end

      :not_found ->
        json(conn, 404, %{error: "unknown-cartridge", cartridge: name})
    end
  end

  match _ do
    json(conn, 404, %{error: "route-not-found", path: conn.request_path})
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
      BojRest.JsInvoker.invoke(cartridge_mod_path(cart), tool, args, creds)
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
