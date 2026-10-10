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

  `contracts_dir` and `results_dir` are relative to the directory `mix` runs
  in; `test_paths` are relative to `root/0`, so every task finds the same
  tests whichever directory it runs in (a `--test-path` typed on the command
  line is relative to the directory it was typed in). In an umbrella, point
  `contracts_dir` at an absolute path (`Path.expand("../contracts", __DIR__)`
  from `config/config.exs`) so every app resolves the same directory, and set
  `test_paths` to `["apps/*/test/contract"]`.
  """

  alias Covenant.Contract

  @doc "The contracts directory (`:contracts_dir`, default `\"contracts\"`)."
  @spec contracts_dir() :: Path.t()
  def contracts_dir, do: Application.get_env(:covenant, :contracts_dir, "contracts")

  @doc """
  The contract test paths or globs (`:test_paths`, default `["test/contract"]`) as absolute
  paths: a relative entry resolves against `root/0`, never against the working directory
  (in an umbrella `mix` runs each app from `apps/<app>`, where `apps/*/test/contract` would
  match nothing).
  """
  @spec test_paths() :: [Path.t()]
  def test_paths do
    root = root()

    :covenant
    |> Application.get_env(:test_paths, "test/contract")
    |> List.wrap()
    |> Enum.map(&Path.expand(&1, root))
  end

  @doc """
  The test paths a task searches: the `--test-path` values it was given, else `test_paths/0`.

  A value typed on the command line is relative to the working directory it was typed in.
  """
  @spec test_paths([Path.t()]) :: [Path.t()]
  def test_paths([]), do: test_paths()
  def test_paths(typed), do: Enum.map(typed, &Path.expand/1)

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

  @doc """
  The project root: the directory that holds the contracts directory.

  Contract tests resolve every path from here so they never depend on the
  directory `mix test` runs in (in an umbrella, `mix test` runs each app
  from `apps/<app>`). In order:

  1. the `COVENANT_ROOT` environment variable;
  2. `config :covenant, root: ...`;
  3. the parent of `contracts_dir/0` when that is absolute;
  4. the parent of `contracts_dir/0` resolved from the nearest of the
     current directory and its ancestors where it is a directory;
  5. the current directory.

  The result is an absolute path.
  """
  @spec root() :: Path.t()
  def root do
    explicit = System.get_env("COVENANT_ROOT") || Application.get_env(:covenant, :root)
    contracts = contracts_dir()

    cond do
      explicit not in [nil, ""] -> Path.expand(explicit)
      Path.type(contracts) == :absolute -> contracts |> Path.expand() |> Path.dirname()
      true -> find_root(File.cwd!(), contracts) || File.cwd!()
    end
  end

  defp find_root(dir, contracts) do
    cond do
      File.dir?(Path.join(dir, contracts)) ->
        dir |> Path.join(contracts) |> Path.expand() |> Path.dirname()

      Path.dirname(dir) == dir ->
        nil

      true ->
        find_root(Path.dirname(dir), contracts)
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
