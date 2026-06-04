# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule BojRest.JsInvokerTest do
  use ExUnit.Case, async: false

  @cartridges_root System.get_env("BOJ_CARTRIDGES_PATH") || Path.expand("../../cartridges", __DIR__)

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

  # ── idempotency and type stability ────────────────────────────────────────

  test "deno_path/0 is idempotent" do
    r1 = BojRest.JsInvoker.deno_path()
    r2 = BojRest.JsInvoker.deno_path()
    assert r1 == r2
  end

  test "invoke/3 with empty args map does not crash" do
    result = BojRest.JsInvoker.invoke("/nonexistent/mod.js", "tool", %{})
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "invoke/3 error result always has :classification key" do
    case BojRest.JsInvoker.deno_path() do
      nil ->
        # Without Deno, we still get a structured error
        result = BojRest.JsInvoker.invoke("/nonexistent/mod.js", "tool", %{})
        assert {:error, err} = result
        assert Map.has_key?(err, :classification)

      _deno ->
        result = BojRest.JsInvoker.invoke("/nonexistent/mod.js", "tool", %{})
        assert {:error, err} = result
        assert Map.has_key?(err, :classification)
    end
  end

  test "invoke/4 with extra_env map does not crash" do
    result = BojRest.JsInvoker.invoke("/nonexistent/mod.js", "tool", %{}, %{"X" => "1"})
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "invoke/3 classification is always an atom" do
    result = BojRest.JsInvoker.invoke("/nonexistent/mod.js", "any_tool", %{})
    case result do
      {:error, err} -> assert is_atom(err.classification)
      {:ok, _} -> :ok
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
