defmodule Covenant.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :covenant,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # The fixture project under test/fixtures has its own tests; they run
      # from inside it (see test/contract/covenant/tasks), not as ours.
      test_load_filters: [
        &(String.ends_with?(&1, "_test.exs") and not String.starts_with?(&1, "test/fixtures/"))
      ],
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Covenant"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:yaml_elixir, "~> 2.12"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "The IMP Contract layer for Elixir: intent documents, decision records, " <>
      "obligation-tagged contract tests, contract coverage and regeneration packs."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"]]
  end
end
