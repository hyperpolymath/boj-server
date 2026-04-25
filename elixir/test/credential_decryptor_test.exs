# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.CredentialDecryptorTest do
  use ExUnit.Case, async: false

  setup_all do
    case Process.whereis(BojRest.NodeKey) do
      nil -> start_supervised!({BojRest.NodeKey, data_dir: System.tmp_dir!()})
      _pid -> :ok
    end
    :ok
  end

  # ── no credentials ──────────────────────────────────────────────────────────

  test "nil credentials returns empty env map" do
    assert {:ok, %{}} = BojRest.CredentialDecryptor.extract(%{}, true)
    assert {:ok, %{}} = BojRest.CredentialDecryptor.extract(%{}, false)
  end

  test "body without credentials key returns empty env map" do
    assert {:ok, %{}} = BojRest.CredentialDecryptor.extract(%{"tool" => "noop"}, true)
  end

  # ── plaintext path ──────────────────────────────────────────────────────────

  test "plaintext credentials accepted from loopback" do
    body = %{"credentials" => %{"TOKEN" => "abc123"}}
    assert {:ok, %{"TOKEN" => "abc123"}} = BojRest.CredentialDecryptor.extract(body, true)
  end

  test "plaintext credentials rejected from non-loopback" do
    body = %{"credentials" => %{"TOKEN" => "abc123"}}
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
    assert String.contains?(reason, "loopback")
  end

  test "plaintext credentials with non-string values rejected" do
    body = %{"credentials" => %{"TOKEN" => 42}}
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, true)
    assert String.contains?(reason, "string")
  end

  test "multiple plaintext credentials accepted from loopback" do
    creds = %{"TOKEN_A" => "val1", "TOKEN_B" => "val2", "URL" => "https://example.com"}
    body = %{"credentials" => creds}
    assert {:ok, ^creds} = BojRest.CredentialDecryptor.extract(body, true)
  end

  # ── encrypted path ──────────────────────────────────────────────────────────

  test "encrypted credentials with correct ECDH round-trip decrypts successfully" do
    # Caller generates ephemeral keypair
    {caller_pub, caller_priv} = :crypto.generate_key(:ecdh, :x25519)
    node_pub = BojRest.NodeKey.public_key()

    # Caller derives shared secret and encrypts
    shared = :crypto.compute_key(:ecdh, node_pub, caller_priv, :x25519)
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = Jason.encode!(%{"GITHUB_TOKEN" => "ghp_test123"})
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, shared, nonce, plaintext, "boj-invoke-v1", true)

    body = %{
      "credentials" => %{
        "v" => 1,
        "encrypted" => true,
        "caller_pubkey" => Base.url_encode64(caller_pub, padding: false),
        "nonce" => Base.url_encode64(nonce, padding: false),
        "ciphertext" => Base.url_encode64(ciphertext <> tag, padding: false)
      }
    }

    assert {:ok, %{"GITHUB_TOKEN" => "ghp_test123"}} =
             BojRest.CredentialDecryptor.extract(body, false)
  end

  test "encrypted credentials with wrong node key return error" do
    # Encrypt with a different node key (simulates tampered ciphertext)
    {caller_pub, _caller_priv} = :crypto.generate_key(:ecdh, :x25519)
    {wrong_node_pub, wrong_node_priv} = :crypto.generate_key(:ecdh, :x25519)

    wrong_shared = :crypto.compute_key(:ecdh, wrong_node_pub, wrong_node_priv, :x25519)
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = Jason.encode!(%{"K" => "v"})
    {ct, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, wrong_shared, nonce, plaintext, "boj-invoke-v1", true)

    body = %{
      "credentials" => %{
        "v" => 1,
        "encrypted" => true,
        "caller_pubkey" => Base.url_encode64(caller_pub, padding: false),
        "nonce" => Base.url_encode64(nonce, padding: false),
        "ciphertext" => Base.url_encode64(ct <> tag, padding: false)
      }
    }

    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
    assert String.contains?(reason, "decryption failed")
  end

  test "unsupported credential version returns error" do
    body = %{
      "credentials" => %{
        "v" => 99,
        "encrypted" => true,
        "caller_pubkey" => "x",
        "nonce" => "x",
        "ciphertext" => "x"
      }
    }
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
    assert String.contains?(reason, "version")
  end

  test "encrypted credentials missing caller_pubkey returns error" do
    body = %{
      "credentials" => %{
        "encrypted" => true,
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "ciphertext" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }
    }
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
    assert is_binary(reason)
  end

  test "malformed base64 in caller_pubkey returns error" do
    body = %{
      "credentials" => %{
        "v" => 1,
        "encrypted" => true,
        "caller_pubkey" => "!!!not-base64!!!",
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "ciphertext" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }
    }
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
    assert String.contains?(reason, "base64")
  end

  test "wrong pubkey size (not 32 bytes) returns error" do
    body = %{
      "credentials" => %{
        "v" => 1,
        "encrypted" => true,
        "caller_pubkey" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "ciphertext" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }
    }
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
    assert String.contains?(reason, "32 bytes")
  end

  test "wrong nonce size (not 12 bytes) returns error" do
    {caller_pub, _} = :crypto.generate_key(:ecdh, :x25519)
    body = %{
      "credentials" => %{
        "v" => 1,
        "encrypted" => true,
        "caller_pubkey" => Base.url_encode64(caller_pub, padding: false),
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
        "ciphertext" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }
    }
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, false)
    assert String.contains?(reason, "12 bytes")
  end

  test "credentials as non-map returns error" do
    body = %{"credentials" => "just-a-string"}
    assert {:error, reason} = BojRest.CredentialDecryptor.extract(body, true)
    assert is_binary(reason)
  end
end
