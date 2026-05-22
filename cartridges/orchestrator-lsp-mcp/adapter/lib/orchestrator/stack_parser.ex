# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Discovers which domain LSP servers are active for a given workspace.
#
# Discovery order (first that succeeds wins):
#   1. Read `.machine_readable/integrations/*.a2ml` files from the workspace root.
#      Each file declares at minimum:
#        [metadata]
#        domain   = "k8s"
#        lsp_port = 9004
#   2. Fall back to the full 12-domain default set when the integrations
#      directory is absent or yields no parseable files.
#
# Domain → default port mapping:
#   cloud=9001, container=9002, iac=9003, k8s=9004, db=9005,
#   queue=9006, secret=9007, git=9008, ssg=9009, proof=9010,
#   observe=9011, browser=9012

defmodule OrchestratorLspMcp.Orchestrator.StackParser do
  @moduledoc """
  Reads `.machine_readable/integrations/*.a2ml` files from a workspace root
  to discover which domain LSP servers are active.

  Falls back to the full 12-domain default set when no integration files
  are found.
  """

  # The 11 standard non-browser domains shipped with every orchestrator deployment.
  @default_domains ~w[git k8s db secret queue iac cloud container ssg proof observe]

  @doc """
  Parse the workspace at `workspace_root` and return a list of domain maps:

      [%{domain: "k8s", port: 9004}, ...]
  """
  @spec parse(String.t()) :: [%{domain: String.t(), port: non_neg_integer()}]
  def parse(workspace_root) when is_binary(workspace_root) do
    integrations_path =
      Path.join([workspace_root, ".machine_readable", "integrations"])

    if File.dir?(integrations_path) do
      parsed =
        integrations_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".a2ml"))
        |> Enum.map(&parse_integration(Path.join(integrations_path, &1)))
        |> Enum.reject(&is_nil/1)

      # If files exist but none parsed successfully, fall back to defaults.
      if parsed == [], do: default_domains(), else: parsed
    else
      default_domains()
    end
  end

  @doc "Return the full 12-domain default set with canonical port assignments."
  @spec default_domains() :: [%{domain: String.t(), port: non_neg_integer()}]
  def default_domains do
    Enum.map(@default_domains, &%{domain: &1, port: default_port(&1)})
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────

  # Parse a single .a2ml integration file.
  # Returns %{domain: _, port: _} or nil if required fields are missing.
  defp parse_integration(path) do
    content = File.read!(path)

    with domain when not is_nil(domain) <- extract_field(content, "domain"),
         port_str <- extract_field(content, "lsp_port"),
         {port, ""} <- Integer.parse(port_str || "0") do
      %{
        domain: domain,
        port: if(port > 0, do: port, else: default_port(domain))
      }
    else
      _ -> nil
    end
  end

  # Extract a single-line field value from A2ML content.
  # Handles both quoted ("value") and unquoted (value) forms.
  defp extract_field(content, field) do
    case Regex.run(~r/^\s*#{field}\s*=\s*"?([^"\n]+)"?/m, content) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  # Canonical default port assignments for the 12 standard domain servers.
  defp default_port(domain) do
    %{
      "cloud" => 9001,
      "container" => 9002,
      "iac" => 9003,
      "k8s" => 9004,
      "db" => 9005,
      "queue" => 9006,
      "secret" => 9007,
      "git" => 9008,
      "ssg" => 9009,
      "proof" => 9010,
      "observe" => 9011,
      "browser" => 9012
    }[domain] || 9099
  end
end
