# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.Router do
  @moduledoc """
  Plug router for the five endpoints `mcp-bridge/lib/api-clients.js` hits:

      GET  /health
      GET  /menu
      GET  /cartridges
      GET  /cartridge/:name
      POST /cartridge/:name/invoke

  Invocation is a placeholder: this skeleton does not dispatch to the Zig
  FFI yet. It returns `{"error": "invocation-not-yet-wired"}` so the bridge
  gets a structured response instead of a connection refusal.
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  @version Mix.Project.config()[:version]

  get "/health" do
    body =
      %{
        status: "ok",
        mode: "skeleton",
        note: "BoJ REST skeleton (elixir/) — endpoints respond, invocation is a placeholder",
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
      {:ok, _cart} ->
        json(conn, 501, %{
          error: "invocation-not-yet-wired",
          cartridge: name,
          message:
            "The REST skeleton can find this cartridge in the catalog but does not " <>
              "yet dispatch to the Zig FFI. Tracked under the Elixir-port Phase 2 task."
        })

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
end
