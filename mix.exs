defmodule Sark.MixProject do
  use Mix.Project

  def project do
    [
      app: :sark,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sark.Application, []}
    ]
  end

  defp deps do
    [
      {:phantom_mcp, "~> 0.4"},
      {:exqlite, "~> 0.36"},
      {:plug_cowboy, "~> 2.7"},
      {:yaml_elixir, "~> 2.11"},
      {:jason, "~> 1.4"},
      {:bbmustache, "~> 1.12"},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end

  defp releases do
    [
      sark: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
