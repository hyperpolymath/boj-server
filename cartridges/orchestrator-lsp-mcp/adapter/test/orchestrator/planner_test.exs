# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule OrchestratorLspMcp.Orchestrator.PlannerTest do
  use ExUnit.Case, async: true

  alias OrchestratorLspMcp.Orchestrator.Planner

  # A representative subset of domains used across routing tests.
  @domains [
    %{domain: "k8s", port: 9004},
    %{domain: "db", port: 9005},
    %{domain: "iac", port: 9003},
    %{domain: "container", port: 9002},
    %{domain: "git", port: 9008},
    %{domain: "secret", port: 9007},
    %{domain: "ssg", port: 9009},
    %{domain: "queue", port: 9006},
    %{domain: "observe", port: 9011}
  ]

  # ──────────────────────────────────────────────────────────────────────
  # route/2 — file-type routing heuristics
  # ──────────────────────────────────────────────────────────────────────

  test "routes terraform (.tf) files to iac domain" do
    result = Planner.route("file:///workspace/main.tf", @domains)
    assert [%{domain: "iac"}] = result
  end

  test "routes HCL files to iac domain" do
    result = Planner.route("file:///workspace/vars.hcl", @domains)
    assert [%{domain: "iac"}] = result
  end

  test "routes Nickel (.ncl) files to iac domain" do
    result = Planner.route("file:///workspace/config.ncl", @domains)
    assert [%{domain: "iac"}] = result
  end

  test "routes k8s YAML to k8s domain" do
    result = Planner.route("file:///workspace/k8s/deployment.yaml", @domains)
    assert [%{domain: "k8s"}] = result
  end

  test "routes helm YAML to k8s domain" do
    result = Planner.route("file:///workspace/helm/values.yaml", @domains)
    assert [%{domain: "k8s"}] = result
  end

  test "routes docker-compose YAML to container domain" do
    result = Planner.route("file:///workspace/docker-compose.yaml", @domains)
    assert [%{domain: "container"}] = result
  end

  test "routes SQL files to db domain" do
    result = Planner.route("file:///workspace/schema.sql", @domains)
    assert [%{domain: "db"}] = result
  end

  test "routes Elixir files to queue and observe domains" do
    result = Planner.route("file:///workspace/lib/worker.ex", @domains)
    domain_names = Enum.map(result, & &1.domain)
    assert "queue" in domain_names
    assert "observe" in domain_names
  end

  test "routes Containerfile to container domain" do
    result = Planner.route("file:///workspace/Containerfile", @domains)
    assert [%{domain: "container"}] = result
  end

  test "routes .gitignore to git domain" do
    result = Planner.route("file:///workspace/.gitignore", @domains)
    assert [%{domain: "git"}] = result
  end

  test "routes secrets path to secret domain" do
    result = Planner.route("file:///workspace/secrets/vault.yaml", @domains)
    assert [%{domain: "secret"}] = result
  end

  test "routes .adoc files to ssg domain" do
    result = Planner.route("file:///workspace/docs/README.adoc", @domains)
    assert [%{domain: "ssg"}] = result
  end

  test "routes unknown file types to all domains" do
    result = Planner.route("file:///workspace/unknown.xyz", @domains)
    assert result == @domains
  end

  # ──────────────────────────────────────────────────────────────────────
  # merged_capabilities/1
  # ──────────────────────────────────────────────────────────────────────

  test "merged_capabilities returns a capability map" do
    caps = Planner.merged_capabilities(@domains)
    assert is_map(caps)
  end

  test "merged_capabilities includes completionProvider" do
    caps = Planner.merged_capabilities(@domains)
    assert Map.has_key?(caps, "completionProvider")
  end

  test "merged_capabilities includes hoverProvider" do
    caps = Planner.merged_capabilities(@domains)
    assert caps["hoverProvider"] == true
  end

  test "merged_capabilities includes textDocumentSync" do
    caps = Planner.merged_capabilities(@domains)
    assert Map.has_key?(caps, "textDocumentSync")
  end

  # ──────────────────────────────────────────────────────────────────────
  # active_domains/1
  # ──────────────────────────────────────────────────────────────────────

  test "active_domains falls back to defaults for nil root" do
    domains = Planner.active_domains(nil)
    assert is_list(domains)
    assert length(domains) > 0
  end

  test "active_domains falls back to defaults for nonexistent root" do
    domains = Planner.active_domains("/tmp/nonexistent_xyz_workspace")
    assert is_list(domains)
    assert Enum.all?(domains, &Map.has_key?(&1, :domain))
  end
end
