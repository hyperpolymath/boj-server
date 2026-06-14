# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
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
      # JSON Schema validation for cartridge manifests. Used by BojRest.Catalog
      # to validate each cartridge.json against the SHA-pinned schema mirror at
      # schemas/cartridge-v1.json before loading. Closes boj-server#183.
      {:ex_json_schema, "~> 0.10"},
      {:stream_data, "~> 1.1", only: [:test]},
      {:benchee, "~> 1.3", only: [:dev]}
    ]
  end

  defp package do
    [
      licenses: ["AGPL-3.0-or-later"],
      links: %{"GitHub" => "https://github.com/hyperpolymath/boj-server"}
    ]
  end
end
