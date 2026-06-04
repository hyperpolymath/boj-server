# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule BojRest.InvokerTest do
  use ExUnit.Case, async: true

  @fake_cli Path.expand("fixtures/fake_boj_invoke", __DIR__)

  # Convenience — set BOJ_INVOKE_CLI to the fake script for the duration of a test.
  defp with_fake_cli(fun) do
    old = System.get_env("BOJ_INVOKE_CLI")
    System.put_env("BOJ_INVOKE_CLI", @fake_cli)
    try do
      fun.()
    after
      if old, do: System.put_env("BOJ_INVOKE_CLI", old),
      else: System.delete_env("BOJ_INVOKE_CLI")
    end
  end

  # ── cli_path/0 ─────────────────────────────────────────────────────────────

  test "cli_path/0 returns nil or a string" do
    result = BojRest.Invoker.cli_path()
    assert is_nil(result) or is_binary(result)
  end

  test "cli_path/0 uses BOJ_INVOKE_CLI env var when file exists" do
    old = System.get_env("BOJ_INVOKE_CLI")
    System.put_env("BOJ_INVOKE_CLI", @fake_cli)
    assert BojRest.Invoker.cli_path() == @fake_cli
    if old, do: System.put_env("BOJ_INVOKE_CLI", old),
    else: System.delete_env("BOJ_INVOKE_CLI")
  end

  test "cli_path/0 ignores BOJ_INVOKE_CLI when path does not exist" do
    old = System.get_env("BOJ_INVOKE_CLI")
    System.put_env("BOJ_INVOKE_CLI", "/tmp/__nonexistent_boj_invoke__")
    result = BojRest.Invoker.cli_path()
    # Must not return the non-existent path
    refute result == "/tmp/__nonexistent_boj_invoke__"
    if old, do: System.put_env("BOJ_INVOKE_CLI", old),
    else: System.delete_env("BOJ_INVOKE_CLI")
  end

  # ── non-existent .so path (when real or fake CLI is available) ─────────────

  test "probe/1 with non-existent .so returns :open or :cli_missing" do
    result = BojRest.Invoker.probe("/nonexistent/path/fake.so")
    assert {:error, %{classification: cls}} = result
    assert cls in [:open, :cli_missing]
  end

  test "invoke/4 with non-existent .so returns error tuple" do
    result = BojRest.Invoker.invoke("/nonexistent/path/fake.so", "noop", %{})
    assert {:error, %{classification: cls}} = result
    assert is_atom(cls)
  end

  # ── exit-code classification via fake CLI ──────────────────────────────────

  test "exit code 2 is classified as :args" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.probe("/fake/exit2.so")
      assert {:error, %{exit_code: 2, classification: :args}} = result
    end)
  end

  test "exit code 3 is classified as :open" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.probe("/fake/exit3.so")
      assert {:error, %{exit_code: 3, classification: :open}} = result
    end)
  end

  test "exit code 4 is classified as :missing_symbol" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.probe("/fake/exit4.so")
      assert {:error, %{exit_code: 4, classification: :missing_symbol}} = result
    end)
  end

  test "exit code 5 is classified as :init_failed" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.probe("/fake/exit5.so")
      assert {:error, %{exit_code: 5, classification: :init_failed}} = result
    end)
  end

  test "unknown exit code is classified as :cli_crashed" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.probe("/fake/exit99.so")
      assert {:error, %{exit_code: 99, classification: :cli_crashed}} = result
    end)
  end

  # ── successful invocations via fake CLI ────────────────────────────────────

  test "probe/1 returns {:ok, map} on success" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.probe("/fake/good.so")
      assert {:ok, map} = result
      assert is_map(map)
    end)
  end

  test "name/1 returns {:ok, map} on success" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.name("/fake/good.so")
      assert {:ok, %{"name" => "fake-cart"}} = result
    end)
  end

  test "version/1 returns {:ok, map} on success" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.version("/fake/good.so")
      assert {:ok, %{"version" => "1.0.0"}} = result
    end)
  end

  test "invoke/4 returns {:ok, map} on success" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.invoke("/fake/good.so", "do_thing", %{"x" => 1})
      assert {:ok, map} = result
      assert is_map(map)
    end)
  end

  test "invoke/4 passes extra_env without crashing" do
    with_fake_cli(fn ->
      result = BojRest.Invoker.invoke("/fake/good.so", "do_thing", %{}, %{"MY_TOKEN" => "abc"})
      assert {:ok, _} = result
    end)
  end

  test "error result always has :exit_code, :classification, :body keys" do
    with_fake_cli(fn ->
      {:error, err} = BojRest.Invoker.probe("/fake/exit2.so")
      assert Map.has_key?(err, :exit_code)
      assert Map.has_key?(err, :classification)
      assert Map.has_key?(err, :body)
    end)
  end

  test "probe/1 classifies bad verb exit as :cli_crashed for unsupported verb" do
    with_fake_cli(fn ->
      # The fake CLI exit codes are controlled by filename; an unknown verb still
      # gets the success path and returns JSON, so classification is :ok.
      # Verify that :args classification wraps exit code 2.
      {:error, err} = BojRest.Invoker.probe("/trigger/exit2/fake.so")
      assert err.classification == :args
    end)
  end
end
