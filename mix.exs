defmodule Jevex.MixProject do
  use Mix.Project

  def project do
    [
      app: :jevex,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "Typed Jev decisions with a validated Elixir DSL and configurable backends",
      deps: deps(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/backends.md",
          "guides/backend-contracts.md",
          "guides/architecture.md",
          "guides/reliability.md",
          "VALIDATION.md"
        ]
      ],
      package: [
        licenses: ["MIT"],
        links: %{"Jev API specification" => "https://docs.typesafe.ai/api"},
        files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md VALIDATION.md guides)
      ],
      dialyzer: [plt_add_apps: [:mix]],
      test_coverage: [summary: [threshold: 85]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
