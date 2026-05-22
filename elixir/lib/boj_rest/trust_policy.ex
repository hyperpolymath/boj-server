# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.TrustPolicy do
  @moduledoc """
  Maps cartridge auth requirements to HTTP caller trust enforcement.

  The http-capability-gateway sidecar sets the `X-Trust-Level` request header
  after authenticating the caller:
    - `"internal"`      — verified Umoja peer (mTLS node cert)
    - `"authenticated"` — authenticated user (bearer token / API key)
    - `"public"`        — anonymous caller (no credentials presented)
    - missing / nil     — treated as `"public"`

  Loopback callers (127.x.x.x, ::1) bypass trust enforcement — they are
  implicitly trusted as local processes (mcp-bridge, developer curl, etc.).

  ## Phase A §3 invariant 3 — non-loopback ignores `X-Trust-Level`

  Per the http-capability-gateway BoJ contract §3 invariant 3, a
  non-loopback caller presenting an `X-Trust-Level` header has the
  header **ignored** — the caller is treated as if it presented no
  header at all. The gateway is the only source authorised to assert a
  trust class, and reaches BoJ on the loopback bind; any other source
  is by definition not the gateway. This is BoJ-side defence in depth;
  the gateway-side strip is the primary control. Without this clause an
  attacker who reaches BoJ's back-side bind directly (a §4 violation —
  back-side bind not network-isolated) could claim `internal` trust by
  setting a header.

  ## Exposure inference from auth.method

  | auth.method          | Required caller exposure |
  |----------------------|--------------------------|
  | `"none"`             | `:public`                |
  | nil (missing)        | `:public`                |
  | `"bearer_token"` etc | `:authenticated`         |

  The `auth.method` field in cartridge.json describes what credential the
  cartridge needs from its *upstream service*, not directly who may call it.
  We infer exposure conservatively: any cartridge that needs a credential
  requires at least an authenticated caller so the credential can be forwarded.
  """

  @type exposure :: :public | :authenticated | :internal
  @type trust_header :: String.t() | nil

  @doc """
  Infer the required caller exposure level from a cartridge manifest.
  Returns `:public` when `auth.method` is `"none"` or absent;
  `:authenticated` otherwise.
  """
  @spec required_exposure(map()) :: exposure()
  def required_exposure(cart) do
    case get_in(cart, ["auth", "method"]) do
      "none" -> :public
      nil -> :public
      _other -> :authenticated
    end
  end

  @doc """
  True when the given `X-Trust-Level` header value satisfies `required`.

  Loopback callers (`is_local: true`) always satisfy any exposure level.
  Non-loopback callers (`is_local: false`) have their `X-Trust-Level`
  header **ignored** per Phase A §3 invariant 3 — they can therefore
  only satisfy `:public` exposure. The header alone cannot promote a
  non-loopback caller's trust class.
  """
  @spec satisfies?(exposure(), trust_header(), boolean()) :: boolean()
  def satisfies?(_required, _trust, true), do: true
  def satisfies?(:public, _trust, _local), do: true
  def satisfies?(_required, _trust, false), do: false
  def satisfies?(:authenticated, trust, _local) when trust in ["authenticated", "internal"], do: true
  def satisfies?(_required, _trust, _local), do: false
end
