defmodule Example.MixProject do
  use Mix.Project

  # The fixture project of Covenant's own test suite: a tiny app with a real
  # Contract under contracts/, an implementation under lib/ and contract
  # tests under test/contract/. Covenant's e2e tests run `mix covenant.*`
  # in this directory. Dependencies are shared with the parent project
  # (deps_path) so no network is needed; the lockfile is this project's own.
  def project do
    [
      app: :example,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps_path: "../../../deps",
      lockfile: "mix.lock",
      deps: [{:covenant, path: "../../..", runtime: false}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
