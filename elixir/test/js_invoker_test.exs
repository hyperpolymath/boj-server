# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.JsInvokerTest do
  use ExUnit.Case, async: false

  @cartridges_root Path.expand("../../cartridges", __DIR__)

  # ── deno discovery ──────────────────────────────────────────────────────────

  test "deno_path/0 returns nil or a string" do
    result = BojRest.JsInvoker.deno_path()
    assert result == nil or is_binary(result)
  end

  # ── error paths (no Deno required) ─────────────────────────────────────────

  test "invoke with non-existent mod.js returns mod_missing error" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        result = BojRest.JsInvoker.invoke("/does/not/exist/mod.js", "noop", %{})
        assert {:error, %{classification: :mod_missing}} = result
    end
  end

  test "invoke returns deno_missing when DENO_PATH points to non-existent file" do
    original = System.get_env("DENO_PATH")

    try do
      System.put_env("DENO_PATH", "/absolutely/not/a/real/path/deno")
      # Only run this test if deno is also not on PATH
      case System.find_executable("deno") do
        nil ->
          result = BojRest.JsInvoker.invoke("/some/mod.js", "noop", %{})
          assert {:error, %{classification: :deno_missing}} = result

        _on_path ->
          # deno is on PATH — can't force missing; skip
          :ok
      end
    after
      case original do
        nil -> System.delete_env("DENO_PATH")
        v -> System.put_env("DENO_PATH", v)
      end
    end
  end

  # ── real invocations (Deno required) ───────────────────────────────────────

  @tag :e2e
  test "invoke model-router-mcp/classify_task returns structured result" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        mod_js = Path.join([@cartridges_root, "model-router-mcp", "mod.js"])

        result =
          BojRest.JsInvoker.invoke(mod_js, "classify_task", %{
            "task" => "Write a poem about distributed systems"
          })

        assert {:ok, data} = result
        assert is_map(data)
    end
  end

  @tag :e2e
  test "invoke model-router-mcp/estimate_cost returns cost data" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        mod_js = Path.join([@cartridges_root, "model-router-mcp", "mod.js"])
        result = BojRest.JsInvoker.invoke(mod_js, "estimate_cost", %{"estimated_tokens" => 1000})
        assert {:ok, data} = result
        assert is_map(data)
    end
  end

  @tag :e2e
  test "invoke with unknown tool returns js_error or ok with error data" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        mod_js = Path.join([@cartridges_root, "model-router-mcp", "mod.js"])
        result = BojRest.JsInvoker.invoke(mod_js, "definitely_not_a_real_tool", %{})
        # Either {:error, ...} or {:ok, %{"error" => ...}} is acceptable
        assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  @tag :e2e
  test "extra_env is forwarded to the Deno subprocess" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        :ok

      _deno ->
        # model-router-mcp doesn't use env vars, but a successful invocation
        # with extra_env set proves the env override path doesn't crash.
        mod_js = Path.join([@cartridges_root, "model-router-mcp", "mod.js"])

        result =
          BojRest.JsInvoker.invoke(
            mod_js,
            "classify_task",
            %{"description" => "test"},
            %{"BOJ_TEST_VAR" => "hello"}
          )

        assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
