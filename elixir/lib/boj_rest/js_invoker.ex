# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.JsInvoker do
  @moduledoc """
  Invokes a JS cartridge by shelling out to Deno with `priv/js_runner.js`.

  Each call forks a fresh Deno process (Phase 1 — fork-per-call).  The ~200 ms
  cold-start overhead is acceptable until there is enough traffic to justify a
  persistent worker pool (Phase 2).

  Dispatch path:
    BojRest.Router
      → BojRest.JsInvoker.invoke/3
        → deno run priv/js_runner.js <mod_js_path> <tool_name> <args_json>
          → cartridge/*/mod.js handleTool(toolName, args)
          ← { status, data } JSON on stdout

  Deno permissions granted per invocation:
    --allow-net    cartridge fetch() calls to upstream backends
    --allow-env    cartridge Deno.env.get() for API keys / URLs
    --allow-read   dynamic import resolution of mod.js by the runner

  Resolution order for the Deno binary:
    1. DENO_PATH env var (absolute path)
    2. System PATH (System.find_executable/1)
  """

  @timeout_ms 30_000

  @type result ::
          {:ok, map()}
          | {:error,
             %{
               classification:
                 :deno_missing | :runner_missing | :js_error | :bad_output | :timeout,
               body: String.t() | map() | nil
             }}

  @doc """
  Invoke `tool_name` on the cartridge at `mod_js_path` with `args`.

  Returns `{:ok, data_map}` on success or `{:error, info_map}` on failure.
  """
  @spec invoke(String.t(), String.t() | nil, map()) :: result()
  def invoke(mod_js_path, tool_name, args) do
    with {:deno, deno} when deno != nil <- {:deno, deno_path()},
         {:runner, runner} when runner != nil <- {:runner, runner_path()},
         {:mod, true} <- {:mod, File.regular?(mod_js_path)} do
      args_json = Jason.encode!(args)

      cmd_args = [
        "run",
        "--allow-net",
        "--allow-env",
        "--allow-read",
        runner,
        mod_js_path,
        tool_name || "",
        args_json
      ]

      task = Task.async(fn -> System.cmd(deno, cmd_args, stderr_to_stdout: true) end)

      case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {stdout, 0}} ->
          parse_output(stdout)

        {:ok, {stderr, _code}} ->
          body = try_decode(String.trim(stderr))
          {:error, %{classification: :js_error, body: body}}

        nil ->
          {:error, %{classification: :timeout, body: "JS invocation timed out after #{@timeout_ms}ms"}}
      end
    else
      {:deno, nil} ->
        {:error,
         %{
           classification: :deno_missing,
           body: "deno binary not found — install Deno or set DENO_PATH env var"
         }}

      {:runner, nil} ->
        {:error,
         %{
           classification: :runner_missing,
           body: "priv/js_runner.js not found — check the Elixir release priv directory"
         }}

      {:mod, false} ->
        {:error,
         %{
           classification: :mod_missing,
           body: "mod.js not found at #{mod_js_path}"
         }}
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp parse_output(stdout) do
    case Jason.decode(String.trim(stdout)) do
      {:ok, %{"status" => status, "data" => data}} when status in 200..299 ->
        {:ok, data}

      {:ok, %{"status" => status, "data" => data}} ->
        # Application-level error returned by handleTool (4xx, 5xx)
        {:error, %{classification: :js_error, body: data, status: status}}

      {:ok, other} ->
        {:ok, other}

      {:error, _} ->
        {:error, %{classification: :bad_output, body: String.trim(stdout)}}
    end
  end

  defp try_decode(text) do
    case Jason.decode(text) do
      {:ok, m} -> m
      _ -> text
    end
  end

  @spec deno_path() :: String.t() | nil
  defp deno_path do
    env = System.get_env("DENO_PATH")

    cond do
      is_binary(env) and File.regular?(env) -> env
      true -> System.find_executable("deno")
    end
  end

  @spec runner_path() :: String.t() | nil
  defp runner_path do
    priv =
      case :code.priv_dir(:boj_rest) do
        {:error, _} -> nil
        dir -> Path.join(to_string(dir), "js_runner.js")
      end

    # Dev fallback: walk up from this file to the elixir/ project root.
    dev_fallback =
      __DIR__
      |> Path.join("../../../priv/js_runner.js")
      |> Path.expand()

    cond do
      is_binary(priv) and File.regular?(priv) -> priv
      File.regular?(dev_fallback) -> dev_fallback
      true -> nil
    end
  end
end
