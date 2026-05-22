# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Merges diagnostic lists from multiple domain LSP servers for a single
# document URI, to be published back to the editor via
# textDocument/publishDiagnostics.
#
# Strategy:
#   - Flatten all diagnostics from all domains.
#   - Prefix each diagnostic's "source" field with "<domain>:" so the
#     editor's Problems panel shows which server raised each issue.
#   - Preserve the full LSP Diagnostic object otherwise (range, severity,
#     message, code, etc.) so editors can render it correctly.

defmodule OrchestratorLspMcp.LSP.Handlers.Diagnostics do
  @moduledoc """
  Merges diagnostic lists from multiple domain LSP servers.

  Each domain returns a (possibly nil) list of LSP Diagnostic maps for a
  given document URI. This module tags each diagnostic's `source` field
  with the originating domain name and returns a single
  publishDiagnostics payload map.
  """

  @doc """
  Merge diagnostics from multiple domains for `uri`.

  Returns a map ready to pass to GenLSP as a publishDiagnostics notification:

      %{"uri" => uri, "diagnostics" => [...]}
  """
  @spec merge(String.t(), [{String.t(), list(map()) | nil}]) :: map()
  def merge(uri, results) do
    diagnostics =
      Enum.flat_map(results, fn {domain, diags} ->
        Enum.map(diags || [], fn d ->
          # Prepend "<domain>:" to existing source (may be empty string).
          existing_source = Map.get(d, "source", "")
          Map.put(d, "source", "#{domain}:#{existing_source}")
        end)
      end)

    %{"uri" => uri, "diagnostics" => diagnostics}
  end
end
