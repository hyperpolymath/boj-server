# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# BoJ Server Benchmarks — run with:
#   cd elixir && mix run benchmarks/boj_bench.exs
#
# All benchmarks run against the live OTP application. Start the deps first:
#   Application.ensure_all_started(:boj_rest)

Application.ensure_all_started(:boj_rest)

cartridges_root = Path.expand("../../cartridges", __DIR__)

# Start catalog if not already running
unless Process.whereis(BojRest.Catalog) do
  {:ok, _} = BojRest.Catalog.start_link(cartridges_root: cartridges_root)
end

# Start NodeKey if not already running
unless Process.whereis(BojRest.NodeKey) do
  {:ok, _} = BojRest.NodeKey.start_link(data_dir: System.tmp_dir!())
end

# Pre-compute values used across benchmarks
all_carts = BojRest.Catalog.list()
node_pub = BojRest.NodeKey.public_key()
{caller_pub, caller_priv} = :crypto.generate_key(:ecdh, :x25519)
shared = :crypto.compute_key(:ecdh, node_pub, caller_priv, :x25519)
nonce = :crypto.strong_rand_bytes(12)
plaintext = Jason.encode!(%{"API_KEY" => "benchmark-token", "DB_PASS" => "s3cr3t"})
{ciphertext, tag} =
  :crypto.crypto_one_time_aead(:chacha20_poly1305, shared, nonce, plaintext, "boj-invoke-v1", true)

encrypted_envelope = %{
  "version" => 1,
  "caller_pubkey" => Base.url_encode64(caller_pub, padding: false),
  "nonce" => Base.url_encode64(nonce, padding: false),
  "ciphertext" => Base.url_encode64(ciphertext <> tag, padding: false)
}

opts = BojRest.Router.init([])

import Plug.Test
import Plug.Conn

Benchee.run(
  %{
    # ── Catalog ──────────────────────────────────────────────────────────────
    "Catalog.list/0 (112 cartridges ETS scan)" => fn ->
      BojRest.Catalog.list()
    end,

    "Catalog.get/1 — hit" => fn ->
      BojRest.Catalog.get("boj-health")
    end,

    "Catalog.get/1 — miss" => fn ->
      BojRest.Catalog.get("__nonexistent_cartridge__")
    end,

    # ── Credential decryption ────────────────────────────────────────────────
    "CredentialDecryptor — nil (no-op path)" => fn ->
      BojRest.CredentialDecryptor.decrypt(nil, "127.0.0.1")
    end,

    "CredentialDecryptor — plaintext path (loopback)" => fn ->
      BojRest.CredentialDecryptor.decrypt(
        %{"plain" => %{"TOKEN" => "abc", "KEY" => "xyz"}},
        "127.0.0.1"
      )
    end,

    "CredentialDecryptor — ChaCha20-Poly1305 decrypt" => fn ->
      BojRest.CredentialDecryptor.decrypt(%{"encrypted" => encrypted_envelope}, "1.2.3.4")
    end,

    # ── NodeKey ──────────────────────────────────────────────────────────────
    "NodeKey.public_key/0 (GenServer call)" => fn ->
      BojRest.NodeKey.public_key()
    end,

    "NodeKey ECDH shared-secret derivation" => fn ->
      priv = BojRest.NodeKey.private_key()
      :crypto.compute_key(:ecdh, caller_pub, priv, :x25519)
    end,

    # ── Router (in-process Plug.Test, no network) ────────────────────────────
    "Router GET /health" => fn ->
      conn(:get, "/health") |> BojRest.Router.call(opts)
    end,

    "Router GET /cartridges" => fn ->
      conn(:get, "/cartridges") |> BojRest.Router.call(opts)
    end,

    "Router GET /cartridge/boj-health" => fn ->
      conn(:get, "/cartridge/boj-health") |> BojRest.Router.call(opts)
    end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  formatters: [Benchee.Formatters.Console]
)
