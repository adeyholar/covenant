defmodule Covenant do
  @moduledoc """
  Covenant implements the Contract layer of IMP (Impatient Programming) for
  Elixir projects: intent documents and decision records under `contracts/`,
  obligation-tagged contract tests, contract coverage, machine-checked record
  conditions and regeneration packs.

  ## Configuration

  All settings live under the `:covenant` application environment:

  ```elixir
  config :covenant,
    contracts_dir: "contracts",          # where the Contract lives
    test_paths: ["test/contract"],       # contract test suites run by `mix covenant.check`
    results_dir: "_build/covenant/results"  # where `Covenant.Formatter` writes its results
  ```

  Paths are relative to the directory `mix` runs in. In an umbrella, point
  `contracts_dir` at an absolute path (`Path.expand("../contracts", __DIR__)`
  from `config/config.exs`) so every app resolves the same directory, and set
  `test_paths` to `["apps/*/test/contract"]`.
  """

  alias Covenant.Contract

  @doc "The contracts directory (`:contracts_dir`, default `\"contracts\"`)."
  @spec contracts_dir() :: Path.t()
  def contracts_dir, do: Application.get_env(:covenant, :contracts_dir, "contracts")

  @doc "The contract test paths or globs (`:test_paths`, default `[\"test/contract\"]`)."
  @spec test_paths() :: [Path.t()]
  def test_paths, do: List.wrap(Application.get_env(:covenant, :test_paths, "test/contract"))

  @doc """
  The directory `Covenant.Formatter` writes results to (`:results_dir`).

  Defaults to `_build/covenant/results` next to the Mix build directory, which
  is shared by every app of an umbrella and independent of `MIX_ENV`.
  """
  @spec results_dir() :: Path.t()
  def results_dir do
    System.get_env("COVENANT_RESULTS_DIR") ||
      Application.get_env(:covenant, :results_dir) ||
      default_results_dir()
  end

  defp default_results_dir do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Mix.Project.build_path() |> Path.dirname() |> Path.join("covenant/results")
    else
      "_build/covenant/results"
    end
  end

  @doc "Where `mix covenant.check` writes coverage (`<contracts_dir>/coverage.json`)."
  @spec coverage_path() :: Path.t()
  def coverage_path, do: Path.join(contracts_dir(), "coverage.json")

  @doc "Loads the Contract from the configured directory."
  @spec load() :: {:ok, Contract.t()} | {:error, [Covenant.Error.t()]}
  def load, do: Contract.load(contracts_dir())

  @doc "Loads the Contract from `dir`."
  @spec load(Path.t()) :: {:ok, Contract.t()} | {:error, [Covenant.Error.t()]}
  def load(dir), do: Contract.load(dir)

  @doc "Loads the Contract from the configured directory, raising on problems."
  @spec load!() :: Contract.t()
  def load!, do: Contract.load!(contracts_dir())

  @doc "The Covenant version."
  @spec version() :: String.t()
  def version, do: Application.spec(:covenant, :vsn) |> to_string()
end
