defmodule Vm.MixProject do
  use Mix.Project

  # A fixture project for the mutate runner's safety nets (health checks,
  # watchdog): components whose mutants take the VM down or never end.
  # Dependencies are shared with the parent project.
  def project do
    [
      app: :vm,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps_path: "../../../../deps",
      lockfile: "mix.lock",
      deps: [{:covenant, path: "../../../..", runtime: false}]
    ]
  end

  def application do
    [mod: {Vm.Application, []}, extra_applications: [:logger]]
  end
end
