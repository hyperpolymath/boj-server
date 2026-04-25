# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.MixProject do
  use Mix.Project

  def project do
    [
      app: :boj_rest,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      releases: [
        boj_rest: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ],
      deps: deps(),
      description: "BoJ Server REST — HTTP surface for mcp-bridge",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BojRest.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:test]}
    ]
  end

  defp package do
    [
      licenses: ["MPL-2.0"],
      links: %{"GitHub" => "https://github.com/hyperpolymath/boj-server"}
    ]
  end
end
