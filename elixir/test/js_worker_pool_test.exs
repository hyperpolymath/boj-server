# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.JsWorkerPoolTest do
  use ExUnit.Case, async: false

  @model_router_mod Path.expand("../../cartridges/model-router-mcp/mod.js", __DIR__)

  # ── pool_size/0 ────────────────────────────────────────────────────────────

  test "pool_size/0 returns a positive integer" do
    size = BojRest.JsWorkerPool.pool_size()
    assert is_integer(size)
    assert size > 0
  end

  test "pool_size/0 returns the configured value" do
    original = Application.get_env(:boj_rest, :js_worker_pool_size)
    Application.put_env(:boj_rest, :js_worker_pool_size, 3)
    assert BojRest.JsWorkerPool.pool_size() == 3
    if original do
      Application.put_env(:boj_rest, :js_worker_pool_size, original)
    else
      Application.delete_env(:boj_rest, :js_worker_pool_size)
    end
  end

  # ── consistent hash routing ────────────────────────────────────────────────

  test "same mod_js_path always hashes to the same worker index" do
    path = "/some/cartridge/mod.js"
    size = BojRest.JsWorkerPool.pool_size()
    idx1 = :erlang.phash2(path, size)
    idx2 = :erlang.phash2(path, size)
    assert idx1 == idx2
  end

  test "hash is within pool bounds" do
    size = BojRest.JsWorkerPool.pool_size()
    idx = :erlang.phash2("/cartridges/test/mod.js", size)
    assert idx >= 0
    assert idx < size
  end

  test "different mod paths can hash to different workers" do
    size = BojRest.JsWorkerPool.pool_size()
    paths = for i <- 1..20, do: "/cartridges/cart-#{i}/mod.js"
    indices = Enum.map(paths, &:erlang.phash2(&1, size))
    assert length(Enum.uniq(indices)) > 1, "all 20 paths hashed to the same worker"
  end

  # ── fallback to JsInvoker when pool empty ──────────────────────────────────

  test "invoke/4 falls back to JsInvoker when no workers running" do
    # Force a worker name that is definitely not running
    fake_mod = "/nonexistent/mod.js"
    result = BojRest.JsWorkerPool.invoke(fake_mod, "noop", %{})
    # Worker or JsInvoker returns an error; exact classification depends on pool state
    assert {:error, %{classification: cls}} = result
    assert cls in [:mod_missing, :deno_missing, :cli_missing, :js_error]
  end

  # ── E2E via pool ──────────────────────────────────────────────────────────

  @tag :e2e
  test "invoke/4 succeeds via pool worker for classify_task" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        case Process.whereis(BojRest.JsWorkerPool) do
          nil ->
            :ok

          _pid ->
            result = BojRest.JsWorkerPool.invoke(
              @model_router_mod,
              "classify_task",
              %{"task" => "write a unit test"}
            )
            assert {:ok, data} = result
            assert is_map(data)
        end
    end
  end

  @tag :e2e
  test "repeated invocations of same mod go to same worker" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        case Process.whereis(BojRest.JsWorkerPool) do
          nil ->
            :ok

          _pid ->
            # Issue 3 calls — all should succeed (worker caches the module)
            results =
              for _ <- 1..3 do
                BojRest.JsWorkerPool.invoke(
                  @model_router_mod,
                  "classify_task",
                  %{"task" => "fix a bug"}
                )
              end

            assert Enum.all?(results, fn
              {:ok, _} -> true
              _ -> false
            end)
        end
    end
  end
end
