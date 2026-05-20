# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Phase C seam tests — BoJ-side enforcement of the http-capability-gateway
# contract §3 (trust-header security invariant).
#
# Contract §3.3 (boj-contract.md):
#
#     BoJ's gnosis handler / BojRest.Router MUST treat X-Trust-Level as
#     authoritative only when the connection originates from the gateway
#     ... Any X-Trust-Level arriving from any other source MUST be ignored
#     and treated as untrusted.
#
# Enforced at the BoJ side by `BojRest.TrustPolicy.satisfies?/3`: the
# `is_local=false` clause rejects any non-`:public` exposure regardless of
# header. Companion to §4 (back-side bind isolation) and the gateway-side
# half in http-capability-gateway#11.
#
# Refs hyperpolymath/standards#98 (Phase C).
# Refs hyperpolymath/standards#91 (HCG tier-2 channel).
defmodule BojRest.PhaseCSeamTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts BojRest.Router.init([])

  @keyed_cart "airtable-mcp"
  @public_cart "boj-health"

  # ── §3 invariant 3 (positive control) — loopback HONOURS X-Trust-Level ────

  describe "loopback callers (gateway-equivalent path) — live tests" do
    test "X-Trust-Level: internal from 127.0.0.1 → allowed on :authenticated cartridge" do
      conn = invoke(@keyed_cart, "airtable_list_bases",
        remote_ip: {127, 0, 0, 1},
        trust_level: "internal"
      )

      assert conn.status in [200, 500]
      refute body(conn)["error"] == "forbidden"
    end

    test "X-Trust-Level: internal from ::1 → allowed on :authenticated cartridge" do
      conn = invoke(@keyed_cart, "airtable_list_bases",
        remote_ip: {0, 0, 0, 0, 0, 0, 0, 1},
        trust_level: "internal"
      )

      assert conn.status in [200, 500]
      refute body(conn)["error"] == "forbidden"
    end
  end

  # ── Non-loopback to :public cartridge — header is irrelevant, still passes ─

  describe ":public cartridge — non-loopback caller (header irrelevant)" do
    test "X-Trust-Level: internal from non-loopback → :public cartridge still allowed" do
      conn = invoke(@public_cart, "boj_health_status",
        remote_ip: {1, 2, 3, 4},
        trust_level: "internal"
      )

      assert conn.status in [200, 500]
      refute body(conn)["error"] == "forbidden"
    end
  end

  # ── §3 invariant 3 — non-loopback X-Trust-Level MUST be IGNORED ───────────

  describe "non-loopback callers (header MUST be ignored per §3) — live tests" do
    test "X-Trust-Level: internal from 1.2.3.4 → 403 on :authenticated cartridge" do
      conn = invoke(@keyed_cart, "airtable_list_bases",
        remote_ip: {1, 2, 3, 4},
        trust_level: "internal"
      )

      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
      assert body(conn)["detail"] == "insufficient-trust"
      assert body(conn)["required"] == "authenticated"
    end

    test "X-Trust-Level: authenticated from 1.2.3.4 → 403 on :authenticated cartridge" do
      conn = invoke(@keyed_cart, "airtable_list_bases",
        remote_ip: {1, 2, 3, 4},
        trust_level: "authenticated"
      )

      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
    end

    test "X-Trust-Level: internal from IPv6 non-loopback → 403" do
      # IPv6 documentation prefix 2001:db8::/32 — never routable, never loopback.
      conn = invoke(@keyed_cart, "airtable_list_bases",
        remote_ip: {0x2001, 0xdb8, 0, 0, 0, 0, 0, 1},
        trust_level: "internal"
      )

      assert conn.status == 403
    end

    test "SSE: X-Trust-Level: internal from 1.2.3.4 → 403 on :authenticated cartridge" do
      conn = invoke_sse(@keyed_cart, "airtable_list_bases",
        remote_ip: {1, 2, 3, 4},
        trust_level: "internal"
      )

      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
    end
  end

  # ── TrustPolicy.satisfies?/3 function-level parity with the §3 contract ───

  describe "TrustPolicy.satisfies?/3 function-level — live tests" do
    test "is_local=true accepts every claim (loopback bypass; defended by §4)" do
      for trust <- [nil, "public", "authenticated", "internal"] do
        assert BojRest.TrustPolicy.satisfies?(:authenticated, trust, true)
      end
    end

    test "is_local=false rejects every non-:public exposure regardless of header" do
      for trust <- [nil, "public", "authenticated", "internal", "garbage"] do
        refute BojRest.TrustPolicy.satisfies?(:authenticated, trust, false),
               "satisfies?(:authenticated, #{inspect(trust)}, false) leaked through"
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp invoke(cart, tool, opts) do
    do_invoke("/cartridge/#{cart}/invoke", tool, opts)
  end

  defp invoke_sse(cart, tool, opts) do
    do_invoke("/cartridge/#{cart}/sse", tool, opts)
  end

  defp do_invoke(path, tool, opts) do
    base =
      conn(:post, path, Jason.encode!(%{tool: tool}))
      |> put_req_header("content-type", "application/json")

    base =
      case Keyword.get(opts, :trust_level) do
        nil -> base
        v -> put_req_header(base, "x-trust-level", v)
      end

    base =
      case Keyword.get(opts, :remote_ip) do
        nil -> base
        ip -> Map.put(base, :remote_ip, ip)
      end

    BojRest.Router.call(base, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
end
