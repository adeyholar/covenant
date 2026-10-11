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
    sibling_dir: "contract",             # the sibling layout: contract/<primitive>/README.md; false turns it off
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

  `sibling_dir` is relative to `root/0`. A project may use the `contracts/`
  layout, the sibling layout, or both. `sibling_dir: false` (or `nil`) turns the
  sibling layout off entirely: `sibling_dir/0` is `nil` and nothing looks for a `contract/`
  directory.

  ## The project root

  `root/0` is the directory of the Mix project (the umbrella root, for an app of an umbrella),
  never one above it and never moved by `--contracts` or a nested `contracts_dir` such as
  `docs/contracts`. Run `mix covenant.check` from an umbrella app and it runs `mix test` from
  the umbrella root, so each app's contract tests run in that app's own VM. Set `COVENANT_ROOT`
  or `config :covenant, root: ...` to say otherwise.
  """

  alias Covenant.Contract

  @doc "The contracts directory (`:contracts_dir`, default `\"contracts\"`)."
  @spec contracts_dir() :: Path.t()
  def contracts_dir do
    case System.get_env("COVENANT_CONTRACTS_DIR") do
      dir when dir in [nil, ""] -> Application.get_env(:covenant, :contracts_dir, "contracts")
      dir -> dir
    end
  end

  @doc """
  The sibling layout's Contract directory (`:sibling_dir`, default `"contract"`),
  as an absolute path resolved against `root/0`, or `nil` when the layout is turned off
  (`sibling_dir: false` or `nil`). Each primitive is a directory in
  it with a README.md, and its Contract tests sit beside the README.
  """
  @spec sibling_dir() :: Path.t() | nil
  def sibling_dir do
    case sibling() do
      nil -> nil
      dir -> Path.expand(dir, root())
    end
  end

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
  The project root: the directory of the Mix project, or of the umbrella an app belongs to.

  Contract tests resolve every path from here so they never depend on the
  directory `mix test` runs in (in an umbrella, `mix test` runs each app
  from `apps/<app>`). In order:

  1. the `COVENANT_ROOT` environment variable;
  2. `config :covenant, root: ...`;
  3. the parent of `contracts_dir/0` when that is absolute;
  4. the nearest of the current directory and its ancestors, up to the Mix project's directory
     (the umbrella's, for an app) and never above it, that holds
     `contracts_dir/0`, or the sibling layout's directory (`:sibling_dir`)
     with a primitive (a subdirectory with a README.md) in it; a contracts directory
     below it (`docs/contracts`) does not make `docs` the root;
  5. the parent of `:sibling_dir` when that is absolute;
  6. the Mix project's directory, else the current directory.

  The result is an absolute path.
  """
  @spec root() :: Path.t()
  def root do
    explicit = System.get_env("COVENANT_ROOT") || Application.get_env(:covenant, :root)
    contracts = contracts_dir()

    cond do
      explicit not in [nil, ""] ->
        Path.expand(explicit)

      Path.type(contracts) == :absolute ->
        contracts |> Path.expand() |> Path.dirname()

      true ->
        bound = project_dir(cwd())
        find_root(cwd(), contracts, sibling(), bound) || sibling_root() || bound || cwd()
    end
  end

  defp cwd, do: File.cwd!()

  defp sibling do
    case Application.get_env(:covenant, :sibling_dir, "contract") do
      off when off in [nil, false] -> nil
      dir -> dir
    end
  end

  defp sibling_root do
    if sibling() && Path.type(sibling()) == :absolute,
      do: sibling() |> Path.expand() |> Path.dirname()
  end

  # The nearest directory at or above `dir` holding a mix.exs, extended to the umbrella
  # that holds it as an app; nil when there is none (not a Mix project).
  defp project_dir(dir) do
    case nearest_mix_exs(dir) do
      nil -> nil
      project -> umbrella_of(project) || project
    end
  end

  defp nearest_mix_exs(dir) do
    cond do
      File.regular?(Path.join(dir, "mix.exs")) -> dir
      Path.dirname(dir) == dir -> nil
      true -> nearest_mix_exs(Path.dirname(dir))
    end
  end

  defp umbrella_of(project) do
    apps = Path.dirname(project)
    root = Path.dirname(apps)

    with true <- apps != project and root != apps,
         {:ok, text} <- File.read(Path.join(root, "mix.exs")),
         true <- apps_dir?(apps_path(text), apps, root) do
      root
    else
      _ -> nil
    end
  end

  # A literal `apps_path` must name the candidate; a value computed in the file
  # (`apps_path: @apps`) counts only for a directory named `apps`.
  defp apps_dir?({:literal, path}, apps, root), do: Path.expand(path, root) == apps
  defp apps_dir?(:computed, apps, _root), do: Path.basename(apps) == "apps"
  defp apps_dir?(nil, _apps, _root), do: false

  # The one reading of a mix.exs's `apps_path:`, with `#` comments removed: its
  # literal (`"apps"`, `'apps'`, `~c"apps"`), `:computed` for any other value, or
  # nil when the file declares none.
  defp apps_path(text) do
    code = Regex.replace(~r/#(?!\{).*/, text, "")

    case Regex.run(~r/\bapps_path:\s*(?:~c)?(["'])(.*?)\1/, code) do
      [_, _, path] -> {:literal, path}
      nil -> if Regex.match?(~r/\bapps_path:/, code), do: :computed
    end
  end

  @doc """
  True when `dir` holds a `mix.exs` that declares `apps_path:` (an umbrella root).
  """
  @spec umbrella?(Path.t()) :: boolean()
  def umbrella?(dir) do
    case File.read(Path.join(dir, "mix.exs")) do
      {:ok, text} -> apps_path(text) != nil
      _ -> false
    end
  end

  # The nearest directory holding either layout wins, so a project nested in
  # another (a fixture inside a repository) finds its own Contract. A sibling
  # directory counts only when a primitive is in it, so the classic layout's
  # `test/contract` never passes for one.
  defp find_root(dir, contracts, sibling, bound) do
    found =
      cond do
        Path.type(contracts) != :absolute and File.dir?(Path.join(dir, contracts)) ->
          contracts

        (sibling && Path.type(sibling) != :absolute) and primitives?(Path.join(dir, sibling)) ->
          sibling

        true ->
          nil
      end

    cond do
      found -> root_of(dir, found)
      Path.dirname(dir) == dir or dir == bound -> nil
      true -> find_root(Path.dirname(dir), contracts, sibling, bound)
    end
  end

  # `dir` holds `found` (relative): the root, unless `found` climbs (`../../contracts`),
  # where the root is the directory it names the child of.
  defp root_of(dir, found) do
    if ".." in Path.split(found),
      do: dir |> Path.join(found) |> Path.expand() |> Path.dirname(),
      else: dir
  end

  defp primitives?(dir),
    do: dir |> Path.join("*/README.md") |> Path.wildcard() |> Enum.any?()

  @doc "Where `mix covenant.check` writes coverage (`<contracts_dir>/coverage.json`)."
  @spec coverage_path() :: Path.t()
  def coverage_path, do: Path.join(contracts_dir(), "coverage.json")

  @doc "Loads the Contract from the configured directories (`contracts_dir/0` and `sibling_dir/0`)."
  @spec load() :: {:ok, Contract.t()} | {:error, [Covenant.Error.t()]}
  def load, do: load(contracts_dir())

  @doc "Loads the Contract from `dir`, with the sibling layout from `sibling_dir/0`."
  @spec load(Path.t()) :: {:ok, Contract.t()} | {:error, [Covenant.Error.t()]}
  def load(dir), do: Contract.load(dir, sibling: sibling_dir())

  @doc "Loads the Contract from the configured directories, raising on problems."
  @spec load!() :: Contract.t()
  def load!, do: Contract.load!(contracts_dir(), sibling: sibling_dir())

  @doc "The Covenant version."
  @spec version() :: String.t()
  def version, do: Application.spec(:covenant, :vsn) |> to_string()
end
