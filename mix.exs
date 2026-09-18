defmodule Jevex.MixProject do
  use Mix.Project

  def project do
    [
      app: :jevex,
      version: "0.1.0",
      name: "Jevex",
      source_url: "https://github.com/kentaro/jevex",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description:
        "Jev decisions as Elixir expressions, with typed requests and configurable backends",
      deps: deps(),
      docs: [
        main: "readme",
        source_ref: "main",
        extras: [
          "README.md",
          "guides/syntax.md",
          "guides/backends.md",
          "guides/backend-contracts.md",
          "guides/architecture.md",
          "guides/reliability.md",
          "guides/publishing.md",
          "CHANGELOG.md",
          "VALIDATION.md"
        ]
      ],
      package: [
        name: "jevex",
        build_tools: ["mix"],
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/kentaro/jevex",
          "Jev API specification" => "https://docs.typesafe.ai/api"
        },
        files:
          ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md VALIDATION.md guides examples)
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
