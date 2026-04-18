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
      {:ok, cart} ->
        # Skinny Phase 2 per ADR-0005: we can probe the cartridge .so
        # via the Zig CLI, but cannot dispatch to a specific tool yet
        # (ADR-0006 work). Run the probe so the caller gets real
        # evidence the cartridge loads; still return 501 on the tool
        # field because dispatch is not wired.
        so_path = cartridge_so_path(cart)

        probe =
          case BojRest.Invoker.probe(so_path) do
            {:ok, map} -> %{probe: :ok, result: map}
            {:error, info} -> %{probe: :error, info: info}
          end

        tool = Map.get(conn.body_params || %{}, "tool")

        json(conn, 501, %{
          error: "tool-dispatch-not-wired",
          cartridge: name,
          tool: tool,
          so_path: so_path,
          probe: probe,
          message:
            "Cartridge can be probed (init/name/version) but tool-level dispatch " <>
              "awaits ADR-0006 (boj_cartridge_invoke ABI)."
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

  # Derive the expected shared-library path from a cartridge entry.
  # Each cartridge builds its .so under `cartridges/<name>/ffi/zig-out/lib/lib<name>_mcp.so`.
  defp cartridge_so_path(cart) do
    name = Map.get(cart, "name") || "unknown"
    root = Application.get_env(:boj_rest, :cartridges_root)
    Path.join([root, name, "ffi", "zig-out", "lib", "lib#{name_to_lib(name)}.so"])
  end

  # cartridge name "aerie-mcp" -> lib name fragment "aerie_mcp"
  defp name_to_lib(name), do: String.replace(name, "-", "_")
end
