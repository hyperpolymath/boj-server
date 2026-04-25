# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.CredentialDecryptor do
  @moduledoc """
  Decrypts per-invocation credentials from a POST /cartridge/:name/invoke body.

  Wire format for ENCRYPTED credentials (remote callers):

      "credentials": {
        "v": 1,
        "encrypted": true,
        "caller_pubkey": "<base64url 32-byte X25519 public key>",
        "nonce":         "<base64url 12-byte ChaCha20-Poly1305 nonce>",
        "ciphertext":    "<base64url encrypted JSON + 16-byte Poly1305 tag>"
      }

  The plaintext that was encrypted is a JSON object of env-var name → value:

      {"GITHUB_TOKEN": "ghp_xxxx", "OTHER_KEY": "value"}

  ECDH shared secret derivation:
      shared = X25519(node_private_key, caller_pubkey)
      plaintext = ChaCha20-Poly1305-Decrypt(shared[0..31], nonce, ciphertext)

  Wire format for PLAINTEXT credentials (loopback callers only):

      "credentials": {"GITHUB_TOKEN": "ghp_xxxx"}

  Plaintext is only accepted when the caller's remote IP is 127.0.0.1 or ::1.
  Any attempt to send plaintext credentials from a non-loopback address is
  rejected with 403.

  Returns {:ok, env_map} | {:error, reason_string}.
  """

  @aad "boj-invoke-v1"

  @type env_map :: %{String.t() => String.t()}
  @type result :: {:ok, env_map()} | {:error, String.t()}

  @doc """
  Extract and decrypt credentials from a request body map.

  `is_local` should be true when `conn.remote_ip` is a loopback address.
  Returns `{:ok, %{}}` (empty map) when no credentials field is present.
  """
  @spec extract(map(), boolean()) :: result()
  def extract(body, is_local) do
    case Map.get(body, "credentials") do
      nil ->
        {:ok, %{}}

      %{"encrypted" => true} = enc ->
        decrypt(enc)

      plain when is_map(plain) ->
        if is_local do
          validate_plain(plain)
        else
          {:error, "plaintext credentials are only accepted from loopback — use encrypted form for remote callers"}
        end

      _ ->
        {:error, "credentials must be a JSON object"}
    end
  end

  # ── encrypted path ────────────────────────────────────────────────────────

  defp decrypt(%{"v" => v}) when v != 1 do
    {:error, "unsupported credential encryption version #{v}"}
  end

  defp decrypt(%{"caller_pubkey" => b64_pub, "nonce" => b64_nonce, "ciphertext" => b64_ct}) do
    with {:pub, {:ok, caller_pub}} <- {:pub, Base.url_decode64(b64_pub, padding: false)},
         {:pub_len, true} <- {:pub_len, byte_size(caller_pub) == 32},
         {:nonce, {:ok, nonce}} <- {:nonce, Base.url_decode64(b64_nonce, padding: false)},
         {:nonce_len, true} <- {:nonce_len, byte_size(nonce) == 12},
         {:ct, {:ok, ct_with_tag}} <- {:ct, Base.url_decode64(b64_ct, padding: false)},
         {:ct_len, true} <- {:ct_len, byte_size(ct_with_tag) > 16} do
      tag_offset = byte_size(ct_with_tag) - 16
      <<ciphertext::binary-size(tag_offset), tag::binary-size(16)>> = ct_with_tag

      node_priv = BojRest.NodeKey.private_key()
      shared = :crypto.compute_key(:ecdh, caller_pub, node_priv, :x25519)

      case :crypto.crypto_one_time_aead(
             :chacha20_poly1305,
             shared,
             nonce,
             ciphertext,
             @aad,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) ->
          case Jason.decode(plaintext) do
            {:ok, map} -> validate_plain(map)
            {:error, _} -> {:error, "decrypted credentials are not valid JSON"}
          end

        :error ->
          {:error, "credential decryption failed — wrong node key or tampered ciphertext"}
      end
    else
      {:pub, _} -> {:error, "caller_pubkey is not valid base64url"}
      {:pub_len, _} -> {:error, "caller_pubkey must be 32 bytes"}
      {:nonce, _} -> {:error, "nonce is not valid base64url"}
      {:nonce_len, _} -> {:error, "nonce must be 12 bytes"}
      {:ct, _} -> {:error, "ciphertext is not valid base64url"}
      {:ct_len, _} -> {:error, "ciphertext too short"}
    end
  end

  defp decrypt(_), do: {:error, "encrypted credentials missing caller_pubkey, nonce, or ciphertext"}

  # ── plaintext validation ──────────────────────────────────────────────────

  # Ensure the plain map is string→string (env var names and values only).
  defp validate_plain(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, map}
    else
      {:error, "credential keys and values must all be strings"}
    end
  end
end
