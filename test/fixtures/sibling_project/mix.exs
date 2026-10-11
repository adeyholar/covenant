defmodule Calc.MixProject do
  use Mix.Project

  # The sibling-layout fixture of Covenant's own test suite: the Contract in
  # contract/<primitive>/, as flinch, qualm and exhale read it, with the
  # Contract tests beside each README. Dependencies are shared with the parent
  # project (deps_path); the lockfile is this project's own.
  def project do
    [
      app: :calc,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps_path: "../../../deps",
      lockfile: "mix.lock",
      test_paths: ["test", "contract"],
      deps: [{:covenant, path: "../../..", runtime: false}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
