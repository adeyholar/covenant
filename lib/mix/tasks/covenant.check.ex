defmodule Mix.Tasks.Covenant.Check do
  @shortdoc "Checks the Contract and prints contract coverage"

  @moduledoc """
  Parses the Contract, runs the contract test suite and fails on anything
  the Contract does not hold.

      mix covenant.check
      mix covenant.check --no-run            # reuse the last results
      mix covenant.check --contracts path    # another contracts directory
      mix covenant.check --test-path apps/core/test/contract --test-path apps/web/test/contract

  Fails (exit status 1) on:

  * a malformed obligation block, record or scope entry;
  * a dangling `record`, `invariant`, `superseded_by` or `depends_on` reference;
  * an active obligation with no tagged test;
  * a tag naming an unknown obligation;
  * a failing tagged test;
  * a `kind: exception` whose target no longer exists;
  * a scope ceiling exceeded.

  Prints contract coverage per component and per app, and writes
  `<contracts dir>/coverage.json`.

  The suite is run as `mix test <paths> --formatter Covenant.Formatter
  --formatter ExUnit.CLIFormatter` with `MIX_ENV=test`; results land in
  `Covenant.results_dir/0`. With `--no-run` the last results are read instead,
  which also works when `test/test_helper.exs` already lists `Covenant.Formatter`.

  ## Options

  * `--no-run` — do not run the suite, read the last results;
  * `--contracts DIR` — the contracts directory (default: config, then `contracts`);
  * `--test-path PATH` — a contract test path or glob (repeatable; default: config, then `test/contract`);
  * `--results-dir DIR` — where results are read from and written to.
  """

  use Mix.Task

  alias Covenant.{Check, Contract, Coverage, Error, Results}

  @requirements ["app.config"]

  @switches [run: :boolean, contracts: :string, test_path: :keep, results_dir: :string]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}; see `mix help covenant.check`")
    end

    contracts_dir = opts[:contracts] || Covenant.contracts_dir()
    results_dir = opts[:results_dir] || Covenant.results_dir()

    test_paths =
      Keyword.get_values(opts, :test_path)
      |> then(&if(&1 == [], do: Covenant.test_paths(), else: &1))

    run? = Keyword.get(opts, :run, true)

    if opts[:contracts], do: Application.put_env(:covenant, :contracts_dir, opts[:contracts])
    if opts[:results_dir], do: Application.put_env(:covenant, :results_dir, results_dir)

    contract = load_contract(contracts_dir)
    suite_status = if run?, do: run_suite(test_paths, results_dir), else: :ok
    results = read_results(results_dir)
    report = Check.run(contract, results)

    Enum.each(report.problems, &Mix.shell().error(Error.format(&1)))
    Mix.shell().info("")
    Mix.shell().info(Coverage.format(report.coverage))

    coverage_path = Path.join(contracts_dir, "coverage.json")
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

  defp load_contract(dir) do
    case Contract.load(dir) do
      {:ok, contract} ->
        contract

      {:error, errors} ->
        Enum.each(Error.sort(errors), &Mix.shell().error(Error.format(&1)))
        fail("the Contract in #{dir} could not be parsed (#{length(errors)} problem(s))")
    end
  end

  defp run_suite(test_paths, results_dir) do
    paths =
      test_paths |> Enum.flat_map(&Path.wildcard/1) |> Enum.filter(&File.exists?/1) |> Enum.sort()

    if paths == [] do
      Mix.shell().info(
        "covenant.check: no contract test paths found (looked for #{Enum.join(test_paths, ", ")})"
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
