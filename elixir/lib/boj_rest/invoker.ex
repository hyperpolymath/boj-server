# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.Invoker do
  @moduledoc """
  Shells out to `boj-invoke` (built by `zig build invoke` in `ffi/zig/`)
  for cartridge probe/name/version. Skinny Phase 2 per ADR-0005.

  No pool yet — each invocation spawns a fresh child. Pool comes in the
  follow-up once the cartridge ABI gap (ADR-0006) is closed and there is
  actual traffic to amortise. Fork-per-request is ~1 ms; acceptable for
  the skeleton.

  Tool-level dispatch (the `tool` field of `POST /cartridge/:name/invoke`)
  is not wired here — the caller gets a classified 501 with the probe
  result as evidence the cartridge loaded. Real dispatch waits on
  ADR-0006 + a reference cartridge implementation.
  """

  @cli_binary "boj-invoke"

  # Exit codes from ffi/zig/src/boj_invoke_cli.zig
  @exit_ok 0
  @exit_args 2
  @exit_open 3
  @exit_symbol 4
  @exit_init 5

  @type verb :: :probe | :name | :version
  @type so_path :: String.t()
  @type result ::
          {:ok, map()}
          | {:error,
             %{
               exit_code: non_neg_integer(),
               classification:
                 :args
                 | :open
                 | :missing_symbol
                 | :init_failed
                 | :cli_missing
                 | :cli_crashed,
               body: map() | String.t() | nil
             }}

  @doc """
  Probe a cartridge .so: runs init, reads name+version, runs deinit.
  Returns `{:ok, %{"name" => ..., "version" => ...}}` on success.
  """
  @spec probe(so_path()) :: result()
  def probe(so_path), do: run(so_path, "probe")

  @spec name(so_path()) :: result()
  def name(so_path), do: run(so_path, "name")

  @spec version(so_path()) :: result()
  def version(so_path), do: run(so_path, "version")

  @doc """
  Invoke a tool on a cartridge: runs init, calls invoke, runs deinit.

  `extra_env` is an optional map of env-var name → value injected into the
  boj-invoke subprocess for this invocation only (Option A credential
  forwarding). Vars are merged over the inherited environment.

  Returns `{:ok, map()}` on success (JSON output parsed).
  """
  @spec invoke(so_path(), String.t(), map(), map()) :: result()
  def invoke(so_path, tool_name, args, extra_env \\ %{}) do
    args_json = Jason.encode!(args)
    run(so_path, "invoke", [tool_name, args_json], extra_env)
  end

  # ── internals ───────────────────────────────────────────────────────

  @spec run(so_path(), String.t(), [String.t()], map()) :: result()
  defp run(so_path, verb, extra_args \\ [], extra_env \\ %{}) do
    cli = cli_path()

    if cli == nil do
      {:error,
       %{
         exit_code: -1,
         classification: :cli_missing,
         body: "boj-invoke CLI not found — run `zig build invoke` in ffi/zig/"
       }}
    else
      cmd_args = [so_path, verb] ++ extra_args
      env_overrides = Enum.map(extra_env, fn {k, v} -> {k, v} end)

      case System.cmd(cli, cmd_args, stderr_to_stdout: true, env: env_overrides) do
        {stdout, @exit_ok} ->
          case Jason.decode(stdout) do
            {:ok, map} -> {:ok, map}
            _ -> {:error, classified(@exit_ok, :cli_crashed, stdout)}
          end

        {stdout_or_err, code} ->
          body = try_decode(stdout_or_err)

          classification =
            case code do
              @exit_args -> :args
              @exit_open -> :open
              @exit_symbol -> :missing_symbol
              @exit_init -> :init_failed
              _ -> :cli_crashed
            end

          {:error, classified(code, classification, body)}
      end
    end
  end

  defp classified(code, cls, body),
    do: %{exit_code: code, classification: cls, body: body}

  defp try_decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, m} -> m
      _ -> String.trim(bytes)
    end
  end

  @doc """
  Return the path to the boj-invoke binary, or `nil` if not built.
  Search order:
  1. `BOJ_INVOKE_CLI` env var if set
  2. `../ffi/zig/zig-out/bin/boj-invoke` relative to the Elixir project
  3. PATH
  """
  @spec cli_path() :: String.t() | nil
  def cli_path do
    env_path = System.get_env("BOJ_INVOKE_CLI")
    project_path =
      Path.expand("../ffi/zig/zig-out/bin/boj-invoke", Application.app_dir(:boj_rest))
      |> fallback_if_missing()

    cond do
      env_path && File.regular?(env_path) -> env_path
      project_path -> project_path
      true -> System.find_executable(@cli_binary)
    end
  end

  defp fallback_if_missing(path) do
    # Application.app_dir points into _build; walk back up to the repo path
    # for the dev-workflow case where the Zig binary was built at repo root.
    # __DIR__ is elixir/lib/boj_rest/; need three levels up to reach the repo root.
    repo_relative =
      Path.expand("../../../ffi/zig/zig-out/bin/boj-invoke", __DIR__)

    cond do
      File.regular?(path) -> path
      File.regular?(repo_relative) -> repo_relative
      true -> nil
    end
  end
end
