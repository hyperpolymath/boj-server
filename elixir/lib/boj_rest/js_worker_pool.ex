# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule BojRest.JsWorkerPool do
  @moduledoc """
  Supervisor managing a fixed pool of persistent Deno worker processes.

  Each worker (`BojRest.JsWorker`) holds one live Deno process and handles
  invocations via stdin/stdout JSON.  Worker selection uses consistent hashing
  on `mod_js_path` so the same cartridge consistently routes to the same worker,
  maximising the module cache hit rate inside the Deno process.

  Pool size defaults to 5 (configurable via `:js_worker_pool_size` in the
  `:boj_rest` application env).

  If Deno or the pool worker script is absent, the pool starts with 0 workers
  (instead of crashing) and `BojRest.JsInvoker.invoke/4` falls back to the
  fork-per-call path automatically.
  """
  use Supervisor
  require Logger

  @default_size 5

  # ── public API ───────────────────────────────────────────────────────────────

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Return the pool size that was configured at startup, or 0 if the pool is empty.
  """
  @spec pool_size() :: non_neg_integer()
  def pool_size do
    Application.get_env(:boj_rest, :js_worker_pool_size, @default_size)
  end

  @doc """
  Invoke `tool_name` on `mod_js_path` via the pool.

  Uses consistent hashing on `mod_js_path` to select the same worker each time,
  maximising Deno module-cache locality.  Falls back gracefully to
  `BojRest.JsInvoker.invoke/4` (fork-per-call) when the pool is not running.
  """
  @spec invoke(String.t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, map()}
  def invoke(mod_js_path, tool_name, args, extra_env \\ %{}) do
    case pick_worker(mod_js_path) do
      nil ->
        BojRest.JsInvoker.invoke(mod_js_path, tool_name, args, extra_env)

      worker ->
        BojRest.JsWorker.invoke(worker, mod_js_path, tool_name, args, extra_env)
    end
  end

  # ── Supervisor callbacks ────────────────────────────────────���───────────────

  @impl true
  def init(opts) do
    deno = BojRest.JsInvoker.deno_path()
    runner = runner_path()
    size = Keyword.get(opts, :pool_size, Application.get_env(:boj_rest, :js_worker_pool_size, @default_size))

    if is_nil(deno) or is_nil(runner) do
      Logger.warning("JsWorkerPool: Deno binary or pool worker script not found — starting with 0 workers; JS invocations will use fork-per-call fallback")
      Supervisor.init([], strategy: :one_for_one)
    else
      workers =
        for i <- 0..(size - 1) do
          name = worker_name(i)

          %{
            id: name,
            start: {BojRest.JsWorker, :start_link, [[name: name, deno_path: deno, runner_path: runner]]},
            restart: :permanent
          }
        end

      Logger.info("JsWorkerPool: starting #{size} workers", deno: deno)
      Supervisor.init(workers, strategy: :one_for_one)
    end
  end

  # ── private ────────────────────────────────────────────────────────────��───

  defp pick_worker(mod_js_path) do
    size = Application.get_env(:boj_rest, :js_worker_pool_size, @default_size)
    idx = :erlang.phash2(mod_js_path, size)
    name = worker_name(idx)

    case Process.whereis(name) do
      nil -> nil
      _pid -> name
    end
  end

  defp worker_name(i), do: :"boj_js_worker_#{i}"

  defp runner_path do
    priv =
      case :code.priv_dir(:boj_rest) do
        {:error, _} -> nil
        dir -> Path.join(to_string(dir), "js_pool_worker.js")
      end

    dev_fallback =
      __DIR__
      |> Path.join("../../../priv/js_pool_worker.js")
      |> Path.expand()

    cond do
      is_binary(priv) and File.regular?(priv) -> priv
      File.regular?(dev_fallback) -> dev_fallback
      true -> nil
    end
  end
end
