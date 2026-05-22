# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Merges hover responses from multiple domain LSP servers into a single
# MarkupContent block presented to the editor.
#
# Strategy:
#   - Filter out nil responses (domain had nothing to say).
#   - Extract the "value" string from each domain's "contents" map.
#   - Emit one markdown section per domain headed by "### <domain>".
#   - Separate sections with a horizontal rule ("---").
#   - Return nil when no domain produced a result (editor hides the hover).

defmodule OrchestratorLspMcp.LSP.Handlers.Hover do
  @moduledoc """
  Merges hover responses from multiple domain LSP servers.

  Each domain may return nil (no hover for this position) or a map
  containing a `"contents"` key (MarkupContent or plain string).
  Results are concatenated into a single markdown document with a
  per-domain heading, or nil when all domains return nil.
  """

  @doc """
  Merge a keyword list of `{domain, hover_result}` pairs.

  Returns a merged LSP Hover map (`%{"contents" => %{"kind" => "markdown", ...}}`)
  or `nil` if every domain returned nil.
  """
  @spec merge([{String.t(), map() | nil}]) :: map() | nil
  def merge(results) do
    contents =
      results
      |> Enum.reject(fn {_domain, r} -> is_nil(r) end)
      |> Enum.map(fn {domain, r} ->
        # Support both MarkupContent (%{"contents" => %{"value" => ...}})
        # and plain string contents (%{"contents" => "..."}).
        body =
          get_in(r, ["contents", "value"]) ||
            get_in(r, ["contents"]) ||
            ""

        "### #{domain}\n\n#{body}"
      end)

    case contents do
      [] ->
        nil

      sections ->
        %{
          "contents" => %{
            "kind" => "markdown",
            "value" => Enum.join(sections, "\n\n---\n\n")
          }
        }
    end
  end
end
