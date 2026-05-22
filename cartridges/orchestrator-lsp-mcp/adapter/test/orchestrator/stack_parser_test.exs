# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule OrchestratorLspMcp.Orchestrator.StackParserTest do
  use ExUnit.Case, async: true

  alias OrchestratorLspMcp.Orchestrator.StackParser

  # ──────────────────────────────────────────────────────────────────────
  # default_domains/0
  # ──────────────────────────────────────────────────────────────────────

  test "default_domains returns a non-empty list" do
    assert StackParser.default_domains() != []
  end

  test "default_domains entries all have :domain and :port keys" do
    for d <- StackParser.default_domains() do
      assert Map.has_key?(d, :domain), "missing :domain in #{inspect(d)}"
      assert Map.has_key?(d, :port), "missing :port in #{inspect(d)}"
    end
  end

  test "default_domains covers all 11 standard non-browser LSP servers" do
    domain_names = StackParser.default_domains() |> Enum.map(& &1.domain)

    for expected <- ~w[git k8s db secret queue iac cloud container ssg proof observe] do
      assert expected in domain_names, "missing domain: #{expected}"
    end
  end

  test "default_domains assigns distinct ports" do
    ports = StackParser.default_domains() |> Enum.map(& &1.port)
    assert ports == Enum.uniq(ports), "duplicate ports in default domain list"
  end

  # ──────────────────────────────────────────────────────────────────────
  # parse/1 — missing integrations directory
  # ──────────────────────────────────────────────────────────────────────

  test "parse/1 returns default domains when workspace does not exist" do
    result = StackParser.parse("/tmp/nonexistent_workspace_zzz_xyz")
    assert is_list(result)
    assert length(result) > 0
    assert Enum.all?(result, &Map.has_key?(&1, :domain))
  end

  test "parse/1 returns default domains when no integrations directory present" do
    # Use /tmp itself — it exists but has no .machine_readable/integrations subdir.
    result = StackParser.parse("/tmp")
    assert is_list(result)
    assert length(result) > 0
  end

  # ──────────────────────────────────────────────────────────────────────
  # parse/1 — with synthetic integration files
  # ──────────────────────────────────────────────────────────────────────

  test "parse/1 reads domain and port from a valid .a2ml integration file" do
    tmp = System.tmp_dir!()
    workspace = Path.join(tmp, "test_ws_#{:erlang.unique_integer([:positive])}")
    integrations = Path.join([workspace, ".machine_readable", "integrations"])
    File.mkdir_p!(integrations)

    File.write!(Path.join(integrations, "k8s.a2ml"), """
    [metadata]
    domain   = "k8s"
    lsp_port = 9004
    """)

    result = StackParser.parse(workspace)
    assert [%{domain: "k8s", port: 9004}] = result
  after
    # Best-effort cleanup
    File.rm_rf(Path.join(System.tmp_dir!(), "test_ws_*"))
  end

  test "parse/1 falls back to default port when lsp_port is absent" do
    tmp = System.tmp_dir!()
    workspace = Path.join(tmp, "test_ws_noport_#{:erlang.unique_integer([:positive])}")
    integrations = Path.join([workspace, ".machine_readable", "integrations"])
    File.mkdir_p!(integrations)

    File.write!(Path.join(integrations, "db.a2ml"), """
    [metadata]
    domain = "db"
    """)

    result = StackParser.parse(workspace)
    assert [%{domain: "db", port: 9005}] = result
  end

  test "parse/1 ignores non-.a2ml files in integrations directory" do
    tmp = System.tmp_dir!()
    workspace = Path.join(tmp, "test_ws_mixed_#{:erlang.unique_integer([:positive])}")
    integrations = Path.join([workspace, ".machine_readable", "integrations"])
    File.mkdir_p!(integrations)

    File.write!(Path.join(integrations, "README.md"), "not an integration file")

    File.write!(Path.join(integrations, "cloud.a2ml"), """
    [metadata]
    domain   = "cloud"
    lsp_port = 9001
    """)

    result = StackParser.parse(workspace)
    assert [%{domain: "cloud", port: 9001}] = result
  end

  test "parse/1 falls back to defaults when all .a2ml files are unparseable" do
    tmp = System.tmp_dir!()
    workspace = Path.join(tmp, "test_ws_bad_#{:erlang.unique_integer([:positive])}")
    integrations = Path.join([workspace, ".machine_readable", "integrations"])
    File.mkdir_p!(integrations)

    File.write!(Path.join(integrations, "broken.a2ml"), "no fields here at all")

    result = StackParser.parse(workspace)
    # Should fall back to the full default set.
    domain_names = Enum.map(result, & &1.domain)
    assert "k8s" in domain_names
  end
end
