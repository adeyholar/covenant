defmodule UmbrellaProject.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      build_path: "_build",
      config_path: "config/config.exs",
      deps_path: "../../../deps",
      lockfile: "mix.lock",
      deps: []
    ]
  end
end
