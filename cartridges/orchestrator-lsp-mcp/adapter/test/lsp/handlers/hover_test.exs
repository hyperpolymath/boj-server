# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule OrchestratorLspMcp.LSP.Handlers.HoverTest do
  use ExUnit.Case, async: true

  alias OrchestratorLspMcp.LSP.Handlers.Hover

  # ──────────────────────────────────────────────────────────────────────
  # Nil / empty cases
  # ──────────────────────────────────────────────────────────────────────

  test "returns nil when all domains return nil" do
    assert Hover.merge([{"k8s", nil}, {"db", nil}]) == nil
  end

  test "returns nil for empty results list" do
    assert Hover.merge([]) == nil
  end

  # ──────────────────────────────────────────────────────────────────────
  # Single domain with MarkupContent
  # ──────────────────────────────────────────────────────────────────────

  test "returns merged map when one domain has a result" do
    result = Hover.merge([{"k8s", %{"contents" => %{"value" => "A Pod is..."}}}])
    assert is_map(result)
    assert get_in(result, ["contents", "kind"]) == "markdown"
  end

  test "single domain: content includes domain heading" do
    result = Hover.merge([{"k8s", %{"contents" => %{"value" => "Pod definition"}}}])
    value = get_in(result, ["contents", "value"])
    assert String.contains?(value, "### k8s")
    assert String.contains?(value, "Pod definition")
  end

  # ──────────────────────────────────────────────────────────────────────
  # Multiple domains
  # ──────────────────────────────────────────────────────────────────────

  test "merges multiple domain results with separator" do
    results = [
      {"k8s", %{"contents" => %{"value" => "Pod info"}}},
      {"iac", %{"contents" => %{"value" => "resource block"}}}
    ]

    value = Hover.merge(results) |> get_in(["contents", "value"])
    assert String.contains?(value, "### k8s")
    assert String.contains?(value, "### iac")
    assert String.contains?(value, "---")
  end

  test "skips nil domain results and merges the rest" do
    results = [
      {"k8s", nil},
      {"db", %{"contents" => %{"value" => "Column type: TEXT"}}}
    ]

    value = Hover.merge(results) |> get_in(["contents", "value"])
    assert String.contains?(value, "### db")
    refute String.contains?(value, "### k8s")
  end

  # ──────────────────────────────────────────────────────────────────────
  # Plain string contents (non-MarkupContent)
  # ──────────────────────────────────────────────────────────────────────

  test "handles plain string contents field" do
    result = Hover.merge([{"ssg", %{"contents" => "A heading element"}}])
    value = get_in(result, ["contents", "value"])
    assert String.contains?(value, "A heading element")
  end

  # ──────────────────────────────────────────────────────────────────────
  # Output shape
  # ──────────────────────────────────────────────────────────────────────

  test "output always uses markdown kind" do
    result = Hover.merge([{"secret", %{"contents" => %{"value" => "env var"}}}])
    assert get_in(result, ["contents", "kind"]) == "markdown"
  end

  test "output contents value is a string" do
    result = Hover.merge([{"cloud", %{"contents" => %{"value" => "region"}}}])
    assert is_binary(get_in(result, ["contents", "value"]))
  end
end
