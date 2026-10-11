defmodule Mix.Tasks.Covenant.Check do
  @shortdoc "Checks the Contract and prints contract coverage"

  @moduledoc """
  Parses the Contract, runs the contract test suite and fails on anything
  the Contract does not hold.

      mix covenant.check
      mix covenant.check --no-run            # reuse the last results
      mix covenant.check --contracts path    # another contracts directory
      mix covenant.check --test-path apps/core/test/contract --test-path apps/web/test/contract
      mix covenant.check --static            # read the tests, compile and run nothing

  Fails (exit status 1) on:

  * a malformed obligation block, record or scope entry;
  * a dangling `record`, `invariant`, `superseded_by` or `depends_on` reference;
  * an active obligation with no tagged test;
  * a tag naming an unknown obligation;
  * a failing tagged test;
  * a `kind: exception` whose target no longer exists;
  * a scope ceiling exceeded.

  In the sibling layout (`contract/<primitive>/`, see `Covenant.Case`) it also
  fails on a primitive's obligation that no Contract test names, a `covers`
  line that names no code, two primitives covering the same code, and a
  `# Contract:` comment or primitive obligation tag in a test outside the
  sibling layout's directory. The sibling directory's tests run with the rest.

  Prints contract coverage per component and per app (the primitives as the
  app `contract`), and writes `<contracts dir>/coverage.json`
  (`<sibling dir>/coverage.json` in a project with only the sibling layout). It also warns, without failing, about the
  components that declare no modules (no `#### Modules` paragraph in the Public
  surface and no `modules:` front matter): `covenant.check: warning: N
  component(s) declare no modules: ...`. `mix covenant.regen` and `mix
  covenant.mutate` can only guess which modules such a component owns.

  ## Static mode

  `--static` does not compile or run anything. It parses every contract
  test file with `Code.string_to_quoted/2` (`Covenant.Static`), reads each
  `use Covenant.Case, component:` module and the `obligation` tag of every
  test (`@tag`, `@describetag` and `@moduletag`, strings and lists), and
  runs every check above that does not need compiled code. It also applies
  the checks `Covenant.Case` makes at compile time (untagged test, unknown
  component, another component's obligation, a retired obligation) and
  reports what only a reader can see (unparsable files, non-literal tags,
  a second `@tag obligation:` that silently replaces the first). Exception
  targets naming a module or function and `module` ceiling counters need
  the code and are listed as skipped, not failed; file targets and `glob`
  counters are checked against the root (`--root`, default `Covenant.root/0`).
  Coverage counts obligations with at least one tagged test and is written
  to `<contracts dir>/coverage.static.json`; `coverage.json` is untouched.
  Problem paths are printed relative to the root.

  The suite is run as `mix test <paths> --formatter Covenant.Formatter
  --formatter ExUnit.CLIFormatter` with `MIX_ENV=test`; results land in
  `Covenant.results_dir/0`. With `--no-run` the last results are read instead,
  which also works when `test/test_helper.exs` already lists `Covenant.Formatter`.

  ## Options

  * `--no-run` — do not run the suite, read the last results;
  * `--contracts DIR` — the contracts directory (default: config, then `contracts`);
  * `--test-path PATH` — a contract test path or glob, relative to the current directory
    (repeatable; default: config, then `test/contract`, relative to `Covenant.root/0`);
  * `--results-dir DIR` — where results are read from and written to;
  * `--static` — read the tests instead of running them (see above);
  * `--root DIR` — with `--static`, the root file targets and globs resolve against.
  """

  use Mix.Task

  alias Covenant.{Check, Contract, Coverage, Error, Results, Static}

  @requirements ["app.config"]

  @switches [
    run: :boolean,
    static: :boolean,
    root: :string,
    contracts: :string,
    test_path: :keep,
    results_dir: :string
  ]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}; see `mix help covenant.check`")
    end

    contracts_dir = opts[:contracts] || Covenant.contracts_dir()
    results_dir = opts[:results_dir] || Covenant.results_dir()

    # before the overrides below: `--contracts` redirects the Contract, not the root the
    # configured test paths resolve against
    test_paths = Covenant.test_paths(Keyword.get_values(opts, :test_path))

    run? = Keyword.get(opts, :run, true)

    if opts[:contracts], do: Application.put_env(:covenant, :contracts_dir, opts[:contracts])
    if opts[:results_dir], do: Application.put_env(:covenant, :results_dir, results_dir)

    if opts[:static] do
      static(contracts_dir, test_paths, Path.expand(opts[:root] || Covenant.root()))
    else
      check(contracts_dir, test_paths, results_dir, run?)
    end
  end

  defp check(contracts_dir, test_paths, results_dir, run?) do
    contract = load_contract(contracts_dir)
    sibling = Covenant.sibling_dir()
    suite_status = if run?, do: run_suite(test_paths ++ sibling_paths(), results_dir), else: :ok
    results = read_results(results_dir)
    report = Check.run(contract, results, sibling: sibling)
    report = %{report | problems: Error.sort(report.problems ++ strays(test_paths, sibling))}

    Enum.each(report.problems, &Mix.shell().error(Error.format(&1)))
    Mix.shell().info("")
    Mix.shell().info(Coverage.format(report.coverage))
    warn(report)

    coverage_path = coverage_path(contracts_dir, "coverage.json")
    File.write!(coverage_path, [Covenant.JSON.pretty(Coverage.to_map(report.coverage)), "\n"])
    Mix.shell().info("\nwrote #{coverage_path}")

    cond do
      suite_status != :ok ->
        fail("contract suite failed (#{suite_status})")

      not Check.Report.ok?(report) ->
        fail("#{length(report.problems)} problem(s) found in the Contract")

      true ->
        Mix.shell().info(IO.ANSI.format([:green, "covenant.check: the Contract holds"]))
        :ok
    end
  end

  defp static(contracts_dir, test_paths, root) do
    contract = load_contract(contracts_dir)
    sibling = Covenant.sibling_dir()
    scan = Static.scan(test_paths ++ sibling_paths(), relative_to: root, sibling: sibling)
    results = %Results{apps: ["static"], tests: scan.tests}
    report = Check.run(contract, results, mode: :static, root: root, sibling: sibling)

    problems =
      (scan.problems ++
         Static.problems(contract, scan) ++ report.problems ++ strays(test_paths, sibling))
      |> Enum.map(fn %Error{file: file} = error ->
        if file, do: %{error | file: Path.relative_to(Path.expand(file), root)}, else: error
      end)
      |> Error.sort()

    Mix.shell().info(
      "covenant.check --static: read #{length(scan.files)} file(s), " <>
        "#{length(scan.modules)} contract test module(s), #{length(scan.tests)} tagged test(s) " <>
        "under #{Enum.map_join(test_paths ++ sibling_paths(), ", ", &Path.relative_to(&1, root))}; no test was compiled or run"
    )

    Enum.each(problems, &Mix.shell().error(Error.format(&1)))
    Mix.shell().info("")
    Mix.shell().info(Coverage.format(report.coverage))

    if report.skipped != [] do
      count = fn kind -> Enum.count(report.skipped, &match?({^kind, _}, &1)) end

      covers =
        case count.(:covers) do
          0 -> ""
          n -> ", the covers of #{n} primitive(s)"
        end

      Mix.shell().info(
        "\nskipped (need compiled code): #{count.(:exception)} exception target(s), " <>
          "#{count.(:ceiling)} module ceiling(s)#{covers}: " <>
          Enum.map_join(report.skipped, ", ", fn {_, name} -> name end)
      )
    end

    warn(report)

    coverage_path = coverage_path(contracts_dir, "coverage.static.json")
    File.write!(coverage_path, [Covenant.JSON.pretty(Coverage.to_map(report.coverage)), "\n"])
    Mix.shell().info("\nwrote #{coverage_path}")

    if problems == [] do
      Mix.shell().info(IO.ANSI.format([:green, "covenant.check: the Contract holds statically"]))
      :ok
    else
      fail("#{length(problems)} problem(s) found in the Contract (static)")
    end
  end

  # The sibling layout's directory, when it holds a primitive's tests.
  defp sibling_paths do
    sibling = Covenant.sibling_dir()
    if Static.expand([sibling]) != [], do: [sibling], else: []
  end

  # Every test file `mix test` loads and every file of the configured contract test paths,
  # outside the sibling layout's directory: none may name a primitive's obligation.
  defp strays(test_paths, sibling) do
    Check.strays(Static.expand(test_paths) ++ project_test_files(), sibling)
  end

  # The files `mix test` loads: under the project's test paths, kept by its
  # `test_load_filters` and not dropped by its `test_ignore_filters` (Elixir 1.19).
  defp project_test_files do
    if Mix.Project.get() do
      config = Mix.Project.config()
      load = config[:test_load_filters] || [&String.ends_with?(&1, "_test.exs")]
      ignore = config[:test_ignore_filters] || []

      for path <- config[:test_paths] || ["test"],
          file <- Path.wildcard(Path.join(path, "**/*.exs")),
          filtered?(load, file),
          not filtered?(ignore, file),
          do: Path.expand(file)
    else
      []
    end
  end

  defp filtered?(filters, file) do
    Enum.any?(filters, fn
      filter when is_function(filter, 1) -> filter.(file)
      %Regex{} = regex -> Regex.match?(regex, file)
      path when is_binary(path) -> path == file
      _ -> false
    end)
  end

  # Next to the Contract: the contracts directory, or the sibling layout's in a project without one.
  defp coverage_path(contracts_dir, name) do
    dir =
      if File.dir?(contracts_dir) or not File.dir?(Covenant.sibling_dir()),
        do: contracts_dir,
        else: Covenant.sibling_dir()

    dir |> Path.join(name) |> Path.relative_to_cwd()
  end

  defp warn(%Check.Report{warnings: warnings}) do
    Enum.each(
      warnings,
      &Mix.shell().info(IO.ANSI.format([:yellow, "covenant.check: warning: ", &1]))
    )
  end

  defp load_contract(dir) do
    case Contract.load(dir, sibling: Path.relative_to_cwd(Covenant.sibling_dir())) do
      {:ok, contract} ->
        contract

      {:error, errors} ->
        Enum.each(Error.sort(errors), &Mix.shell().error(Error.format(&1)))
        fail("the Contract in #{dir} could not be parsed (#{length(errors)} problem(s))")
    end
  end

  defp run_suite(test_paths, results_dir) do
    paths =
      test_paths
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&File.exists?/1)
      |> Enum.sort()
      |> Enum.map(&Path.relative_to_cwd/1)

    if paths == [] do
      Mix.shell().info(
        "covenant.check: no contract test paths found (looked for #{Enum.join(Enum.map(test_paths, &Path.relative_to_cwd/1), ", ")})"
      )

      File.rm_rf!(results_dir)
      :ok
    else
      File.rm_rf!(results_dir)
      mix = System.find_executable("mix") || Mix.raise("cannot find the `mix` executable on PATH")

      args = paths ++ ["--formatter", "Covenant.Formatter", "--formatter", "ExUnit.CLIFormatter"]
      Mix.shell().info("covenant.check: running mix test #{Enum.join(paths, " ")}")

      env = [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", Path.expand(results_dir)}]

      case System.cmd(mix, ["test" | args],
             env: env,
             into: IO.stream(:stdio, :line),
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {_, status} -> "exit status #{status}"
      end
    end
  end

  defp read_results(results_dir) do
    case Results.read_dir(results_dir) do
      {:ok, results} ->
        results

      {:error, reason} ->
        Mix.shell().info("covenant.check: #{reason}")
        %Results{}
    end
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message) do
    Mix.shell().error(
      IO.ANSI.format([:red, "covenant.check: ", message])
      |> IO.iodata_to_binary()
    )

    exit({:shutdown, 1})
  end
end
