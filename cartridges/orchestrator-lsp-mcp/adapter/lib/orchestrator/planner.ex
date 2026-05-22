# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Plans which domain LSP servers are relevant for a workspace and which
# should handle each individual request.
#
# active_domains/1  – reads the workspace's integration manifests via StackParser
# merged_capabilities/1 – produces the union capability set to advertise to the editor
# route/2           – selects a subset of domains for a given document URI

defmodule OrchestratorLspMcp.Orchestrator.Planner do
  @moduledoc """
  Determines which domain LSP servers are relevant for a given workspace
  and which should handle each individual request.

  ## Routing heuristics

  Routing is file-extension and path-pattern based. Examples:
  - `*.tf`, `*.hcl`, `*.ncl` → `iac`
  - `*.yaml` paths containing "k8s" or "helm" → `k8s`
  - `*.yaml` paths containing "docker" or "compose" → `container`
  - `*.sql`, `*.prisma`, `*.ecto` → `db`
  - `*.ex`, `*.exs` → `queue`, `observe`
  - `Dockerfile`, `Containerfile` → `container`
  - `*.gitignore`, `*.gitmodules` → `git`
  - paths containing "secrets", "vault", or "sops" → `secret`
  - `*.md`, `*.adoc`, `*.rst` → `ssg`
  - Unknown / catch-all → all active domains

  The routing table is intentionally heuristic and conservative.
  False-positives (routing to extra domains) are safe; false-negatives
  (missing a relevant domain) reduce feature coverage.
  """

  alias OrchestratorLspMcp.Orchestrator.StackParser

  # ──────────────────────────────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Return the list of active domain maps for `workspace_root`.

  Falls back to the full default domain set when the root is nil or when
  no integration manifests are found.
  """
  @spec active_domains(String.t() | nil) :: [map()]
  def active_domains(workspace_root) when is_binary(workspace_root) do
    StackParser.parse(workspace_root)
  end

  def active_domains(_), do: StackParser.default_domains()

  @doc """
  Produce a merged LSP ServerCapabilities map to advertise to the editor
  during the initialize handshake.

  The base set is universal; individual domains may extend it in future
  versions by returning their own capability hints from their own
  initialize responses.
  """
  @spec merged_capabilities([map()]) :: map()
  def merged_capabilities(domains) do
    base = %{
      "textDocumentSync" => 1,
      "completionProvider" => %{"triggerCharacters" => [".", ":", "/", "-"]},
      "hoverProvider" => true,
      "diagnosticProvider" => %{
        "interFileDependencies" => false,
        "workspaceDiagnostics" => false
      }
    }

    # Domains could contribute additional capabilities in future; for now the
    # base set is the universal minimum and the reduce is a no-op extension point.
    Enum.reduce(domains, base, fn _domain, acc -> acc end)
  end

  @doc """
  Select which domains from `domains` should handle a request for `uri`.

  Returns a (possibly empty) sub-list of `domains`. Returns the full
  `domains` list for URIs that do not match any specific heuristic.
  """
  @spec route(String.t(), [map()]) :: [map()]
  def route(uri, domains) do
    cond do
      uri =~ ~r/\.(tf|hcl|toml|ncl)$/ ->
        filter_domains(domains, ~w[iac])

      uri =~ ~r/\.(yaml|yml)$/ and uri =~ ~r/k8s|kubernetes|helm/ ->
        filter_domains(domains, ~w[k8s])

      uri =~ ~r/\.(yaml|yml)$/ and uri =~ ~r/docker|compose/ ->
        filter_domains(domains, ~w[container])

      uri =~ ~r/\.(sql|prisma|ecto)$/ ->
        filter_domains(domains, ~w[db])

      uri =~ ~r/\.(ex|exs)$/ ->
        filter_domains(domains, ~w[queue observe])

      uri =~ ~r/Dockerfile|Containerfile/ ->
        filter_domains(domains, ~w[container])

      uri =~ ~r/\.gitignore|\.gitmodules/ ->
        filter_domains(domains, ~w[git])

      uri =~ ~r/secrets?|vault|sops/ ->
        filter_domains(domains, ~w[secret])

      uri =~ ~r/\.(md|adoc|rst)$/ ->
        filter_domains(domains, ~w[ssg])

      true ->
        # Unknown file type: fan out to all active domains (safe over-inclusion).
        domains
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────

  defp filter_domains(domains, wanted) do
    Enum.filter(domains, &(&1.domain in wanted))
  end
end
