# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule OrchestratorLspMcp.LSP.Handlers.CompletionTest do
  use ExUnit.Case, async: true

  alias OrchestratorLspMcp.LSP.Handlers.Completion

  # ──────────────────────────────────────────────────────────────────────
  # Basic merging
  # ──────────────────────────────────────────────────────────────────────

  test "merges completion items from multiple domains" do
    results = [
      {"k8s", [%{"label" => "Pod", "detail" => "resource"}]},
      {"db", [%{"label" => "SELECT", "detail" => "keyword"}]}
    ]

    merged = Completion.merge(results)
    assert length(merged) == 2
  end

  test "prefixes detail field with domain tag" do
    results = [{"k8s", [%{"label" => "Pod", "detail" => "resource"}]}]
    [item] = Completion.merge(results)
    assert String.starts_with?(item["detail"], "[k8s]")
  end

  test "preserves all non-detail fields on items" do
    results = [
      {"iac", [%{"label" => "resource", "detail" => "block", "kind" => 15, "insertText" => "resource"}]}
    ]

    [item] = Completion.merge(results)
    assert item["kind"] == 15
    assert item["insertText"] == "resource"
  end

  # ──────────────────────────────────────────────────────────────────────
  # Deduplication
  # ──────────────────────────────────────────────────────────────────────

  test "deduplicates items by label, keeping first occurrence" do
    results = [
      {"k8s", [%{"label" => "name", "detail" => "k8s metadata"}]},
      {"db", [%{"label" => "name", "detail" => "db column"}]}
    ]

    merged = Completion.merge(results)
    assert length(merged) == 1
    # First domain's tag should win.
    assert String.contains?(merged |> hd() |> Map.get("detail"), "[k8s]")
  end

  test "does not deduplicate items with different labels" do
    results = [
      {"k8s", [%{"label" => "Pod"}]},
      {"k8s", [%{"label" => "Service"}]}
    ]

    assert length(Completion.merge(results)) == 2
  end

  # ──────────────────────────────────────────────────────────────────────
  # Nil / empty domain handling
  # ──────────────────────────────────────────────────────────────────────

  test "handles nil result from a domain gracefully" do
    results = [{"k8s", nil}, {"db", [%{"label" => "SELECT"}]}]
    merged = Completion.merge(results)
    assert length(merged) == 1
    assert hd(merged)["label"] == "SELECT"
  end

  test "returns empty list when all domains return nil" do
    results = [{"k8s", nil}, {"db", nil}]
    assert Completion.merge(results) == []
  end

  test "returns empty list when results list is empty" do
    assert Completion.merge([]) == []
  end

  test "handles domain returning empty list" do
    results = [{"k8s", []}, {"db", [%{"label" => "INSERT"}]}]
    assert length(Completion.merge(results)) == 1
  end

  # ──────────────────────────────────────────────────────────────────────
  # Missing detail field
  # ──────────────────────────────────────────────────────────────────────

  test "handles items with no detail field" do
    results = [{"secret", [%{"label" => "AWS_SECRET_ACCESS_KEY"}]}]
    [item] = Completion.merge(results)
    # Should still tag even though original detail was absent.
    assert String.starts_with?(item["detail"], "[secret]")
  end
end
