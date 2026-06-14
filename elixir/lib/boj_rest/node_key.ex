# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule BojRest.NodeKey do
  @moduledoc """
  Holds the node's long-lived X25519 keypair used for credential encryption
  under Option A of the auth design (docs/AUTH-DESIGN.adoc).

  Callers encrypt their credentials with:
    shared_secret = X25519(their_privkey, node_pubkey)
    ciphertext    = ChaCha20-Poly1305(shared_secret, nonce, plaintext_credentials_json)

  The node decrypts by deriving the same shared secret from its private key
  and the caller's public key (included in the request).

  Key persistence order:
    1. BOJ_NODE_PRIVATE_KEY env var  — base64url-encoded 32-byte scalar
    2. BOJ_NODE_KEY_FILE env var     — path to a file containing the base64url scalar
    3. <data_dir>/boj-node.key       — auto-generated and persisted on first boot
    4. In-memory ephemeral           — fallback if data_dir is not writable (dev)

  The public key is served at GET /.well-known/boj-node-pubkey so callers
  can discover it without out-of-band configuration.
  """
  use GenServer
  require Logger

  @table :boj_node_key

  # ── public API ────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Return the node's X25519 public key as a 32-byte binary."
  @spec public_key() :: binary()
  def public_key do
    [{:public, pub}] = :ets.lookup(@table, :public)
    pub
  end

  @doc "Return the node's X25519 private key (scalar) as a 32-byte binary."
  @spec private_key() :: binary()
  def private_key do
    [{:private, priv}] = :ets.lookup(@table, :private)
    priv
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    data_dir = Keyword.get(opts, :data_dir, "/data")

    {pub, priv} = load_or_generate(data_dir)
    :ets.insert(@table, {:public, pub})
    :ets.insert(@table, {:private, priv})

    Logger.info("BoJ node key loaded — pubkey #{Base.url_encode64(pub, padding: false)}")
    {:ok, %{pub: pub}}
  end

  # ── key management ────────────────────────────────────────────────────────

  defp load_or_generate(data_dir) do
    case load_from_env() do
      {:ok, priv} ->
        {derive_public(priv), priv}

      :not_found ->
        key_file = Path.join(data_dir, "boj-node.key")

        case load_from_file(key_file) do
          {:ok, priv} ->
            {derive_public(priv), priv}

          :not_found ->
            generate_and_persist(key_file)
        end
    end
  end

  defp load_from_env do
    case System.get_env("BOJ_NODE_PRIVATE_KEY") do
      nil ->
        case System.get_env("BOJ_NODE_KEY_FILE") do
          nil -> :not_found
          path -> load_from_file(path)
        end

      b64 ->
        case Base.url_decode64(b64, padding: false) do
          {:ok, priv} when byte_size(priv) == 32 -> {:ok, priv}
          _ -> :not_found
        end
    end
  end

  defp load_from_file(path) do
    case File.read(path) do
      {:ok, content} ->
        b64 = String.trim(content)

        case Base.url_decode64(b64, padding: false) do
          {:ok, priv} when byte_size(priv) == 32 ->
            Logger.debug("Node key loaded from #{path}")
            {:ok, priv}

          _ ->
            Logger.warning("Node key file #{path} is malformed — regenerating")
            :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  defp generate_and_persist(key_file) do
    {pub, priv} = :crypto.generate_key(:ecdh, :x25519)

    case File.write(key_file, Base.url_encode64(priv, padding: false)) do
      :ok ->
        Logger.info("Generated new node key → #{key_file}")

      {:error, reason} ->
        Logger.warning("Could not persist node key to #{key_file}: #{inspect(reason)} — using ephemeral key")
    end

    {pub, priv}
  end

  defp derive_public(priv) do
    # OTP :crypto does not expose a standalone scalar-mult for x25519;
    # generate_key with a provided private key is the supported path.
    {pub, ^priv} = :crypto.generate_key(:ecdh, :x25519, priv)
    pub
  end
end
