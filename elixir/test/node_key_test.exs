# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.NodeKeyTest do
  use ExUnit.Case, async: false

  setup_all do
    case Process.whereis(BojRest.NodeKey) do
      nil -> start_supervised!({BojRest.NodeKey, data_dir: System.tmp_dir!()})
      _pid -> :ok
    end
    :ok
  end

  # ── key properties ──────────────────────────────────────────────────────────

  test "public_key/0 returns a 32-byte binary" do
    pub = BojRest.NodeKey.public_key()
    assert is_binary(pub)
    assert byte_size(pub) == 32
  end

  test "private_key/0 returns a 32-byte binary" do
    priv = BojRest.NodeKey.private_key()
    assert is_binary(priv)
    assert byte_size(priv) == 32
  end

  test "public key is stable across calls" do
    pub1 = BojRest.NodeKey.public_key()
    pub2 = BojRest.NodeKey.public_key()
    assert pub1 == pub2
  end

  test "private key is stable across calls" do
    priv1 = BojRest.NodeKey.private_key()
    priv2 = BojRest.NodeKey.private_key()
    assert priv1 == priv2
  end

  test "public key is consistent with private key (X25519 scalar-mult)" do
    priv = BojRest.NodeKey.private_key()
    pub = BojRest.NodeKey.public_key()
    # Re-derive public key from private key using same OTP path
    {derived_pub, ^priv} = :crypto.generate_key(:ecdh, :x25519, priv)
    assert derived_pub == pub
  end

  # ── ECDH round-trip ─────────────────────────────────────────────────────────

  test "node key participates correctly in X25519 ECDH" do
    # Caller side
    {caller_pub, caller_priv} = :crypto.generate_key(:ecdh, :x25519)
    node_pub = BojRest.NodeKey.public_key()
    node_priv = BojRest.NodeKey.private_key()

    # Both sides independently derive the same shared secret
    shared_from_caller = :crypto.compute_key(:ecdh, node_pub, caller_priv, :x25519)
    shared_from_node = :crypto.compute_key(:ecdh, caller_pub, node_priv, :x25519)

    assert shared_from_caller == shared_from_node
    assert byte_size(shared_from_caller) == 32
  end

  test "public key differs from private key" do
    pub = BojRest.NodeKey.public_key()
    priv = BojRest.NodeKey.private_key()
    # Keys are not the same bytes (would be pathological if they were)
    refute pub == priv
  end
end
