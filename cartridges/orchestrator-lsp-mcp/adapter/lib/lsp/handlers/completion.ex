# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Merges completion item lists from multiple domain LSP servers.
#
# Strategy:
#   1. Flatten all items from all domains into a single list.
#   2. Prefix the item's "detail" field with "[<domain>]" so the user can
#      see which domain contributed the suggestion.
#   3. Deduplicate by "label" — first occurrence wins (domain order from
#      Planner.route/2 acts as implicit priority).

defmodule OrchestratorLspMcp.LSP.Handlers.Completion do
  @moduledoc """
  Merges completion item lists from multiple domain LSP servers.

  Each domain returns a (possibly nil) list of LSP CompletionItem maps.
  This module tags each item's `detail` field with the originating domain
  and deduplicates by `label`, keeping the first occurrence.
  """

  @doc """
  Merge a keyword list of `{domain, items}` pairs into a single
  deduplicated completion list.

  ## Examples

      iex> Completion.merge([{"k8s", [%{"label" => "Pod"}]}, {"db", nil}])
      [%{"label" => "Pod", "detail" => "[k8s] "}]
  """
  @spec merge([{String.t(), list(map()) | nil}]) :: list(map())
  def merge(results) do
    results
    |> Enum.flat_map(fn {domain, items} ->
      # Treat nil (domain unavailable or no results) as an empty list.
      Enum.map(items || [], fn item ->
        detail = Map.get(item, "detail", "")
        Map.put(item, "detail", "[#{domain}] #{detail}")
      end)
    end)
    |> Enum.uniq_by(& &1["label"])
  end
end
