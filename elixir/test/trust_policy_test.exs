# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.TrustPolicyTest do
  use ExUnit.Case, async: true

  alias BojRest.TrustPolicy

  # ── required_exposure/1 ────────────────────────────────────────────────────

  test "required_exposure: auth.method none → :public" do
    assert TrustPolicy.required_exposure(%{"auth" => %{"method" => "none"}}) == :public
  end

  test "required_exposure: auth.method missing → :public" do
    assert TrustPolicy.required_exposure(%{}) == :public
  end

  test "required_exposure: auth.method bearer_token → :authenticated" do
    assert TrustPolicy.required_exposure(%{"auth" => %{"method" => "bearer_token"}}) == :authenticated
  end

  test "required_exposure: auth.method api-key → :authenticated" do
    assert TrustPolicy.required_exposure(%{"auth" => %{"method" => "api-key"}}) == :authenticated
  end

  test "required_exposure: auth.method oauth2 → :authenticated" do
    assert TrustPolicy.required_exposure(%{"auth" => %{"method" => "oauth2"}}) == :authenticated
  end

  test "required_exposure: unknown auth.method → :authenticated (fail-safe)" do
    assert TrustPolicy.required_exposure(%{"auth" => %{"method" => "magic"}}) == :authenticated
  end

  # ── satisfies?/3 ───────────────────────────────────────────────────────────

  test "satisfies?: loopback always passes any exposure" do
    assert TrustPolicy.satisfies?(:public, nil, true)
    assert TrustPolicy.satisfies?(:authenticated, nil, true)
    assert TrustPolicy.satisfies?(:authenticated, "public", true)
  end

  test "satisfies?: :public exposure passes without trust header" do
    assert TrustPolicy.satisfies?(:public, nil, false)
  end

  test "satisfies?: :public exposure passes any trust level" do
    assert TrustPolicy.satisfies?(:public, "public", false)
    assert TrustPolicy.satisfies?(:public, "authenticated", false)
    assert TrustPolicy.satisfies?(:public, "internal", false)
  end

  test "satisfies?: :authenticated from non-loopback is rejected regardless of header (§3 invariant 3)" do
    # http-capability-gateway contract §3.3: any X-Trust-Level arriving from
    # a non-gateway (non-loopback in this layer) source MUST be ignored.
    refute TrustPolicy.satisfies?(:authenticated, "authenticated", false)
    refute TrustPolicy.satisfies?(:authenticated, "internal", false)
    refute TrustPolicy.satisfies?(:authenticated, "public", false)
    refute TrustPolicy.satisfies?(:authenticated, nil, false)
    refute TrustPolicy.satisfies?(:authenticated, "garbage", false)
  end

  test "satisfies?: :authenticated from loopback honours X-Trust-Level (gateway-equivalent path)" do
    assert TrustPolicy.satisfies?(:authenticated, "authenticated", true)
    assert TrustPolicy.satisfies?(:authenticated, "internal", true)
    # Loopback bypass per module doc: §4 back-side bind isolation defends in depth.
    assert TrustPolicy.satisfies?(:authenticated, "public", true)
    assert TrustPolicy.satisfies?(:authenticated, nil, true)
  end
end
