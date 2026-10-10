defmodule Mix.Tasks.Covenant.Mutate do
  @shortdoc "Mutates a component and writes the kill matrix"

  @moduledoc """
  Mutates a component's implementation at the AST level, runs its contract
  tests against every mutant and credits each kill to the obligations tagged
  on the tests that caught it (IMP R26: every test proves it is worth keeping).

      mix covenant.mutate example.counter
      mix covenant.mutate example.counter --module Example.Counter --module Example.Counter.Log
      mix covenant.mutate example.counter --timeout 5000 --seed 42 --jobs 2
      mix covenant.mutate example.counter --out tmp/kill_matrix.json

  The modules under mutation are, in order of precedence, the `--module`
  flags, the `modules:` list in the front matter of the component's intent or
  obligations file, or the modules named in its `## Public surface` and in
  the `scope` of its obligations. The contract tests are the files declaring
  `use Covenant.Case, component: "<id>"` under the configured test paths.

  The suite runs in a worker process with `MIX_ENV=test` (one per `--jobs`),
  which boots the test environment once and hot-swaps each mutant in memory;
  no file is written by a mutant. The baseline must be green. A mutant whose
  only failures are test timeouts is a **survivor**, never a kill.

  Prints a progress line per mutant, the kill matrix (per obligation: mutants
  killed in total and uniquely), the survivors with their sort, and the
  mutation-blind tests (warn-only). Writes the matrix as JSON.

  Exit status 1 when the baseline is red, a survivor has no annotation in
  `contracts/<app>/<component>.survivors.yml`, or an annotation is stale.

  ## Options

  * `--module MOD` — an implementation module (repeatable; overrides the Contract);
  * `--timeout MS` — per-test timeout for mutant runs (default #{Covenant.Mutate.default_timeout()});
  * `--seed N` — ExUnit seed (default #{Covenant.Mutate.default_seed()}: definition order);
  * `--jobs N` — worker processes (default 1; mutants are split round-robin);
  * `--out PATH` — the kill matrix JSON (default `tmp/covenant/mutate/<component>/kill_matrix.json`);
  * `--contracts DIR` — the contracts directory;
  * `--test-path PATH` — a contract test path or glob (repeatable).

  `--raw PATH --slice I/N` are the worker's own flags; the task sets them.
  """

  use Mix.Task

  alias Covenant.{Contract, Error}
  alias Covenant.Mutate
  alias Covenant.Mutate.{Matrix, Modules, Mutant, Runner, Survivors}

  @requirements ["app.config"]

  @switches [
    module: :keep,
    timeout: :integer,
    seed: :integer,
    jobs: :integer,
    out: :string,
    contracts: :string,
    test_path: :keep,
    raw: :string,
    slice: :string
  ]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}; see `mix help covenant.mutate`")
    end

    component_id =
      case positional do
        [id] -> id
        _ -> Mix.raise("usage: mix covenant.mutate <component id> [options]")
      end

    if opts[:contracts], do: Application.put_env(:covenant, :contracts_dir, opts[:contracts])

    settings = %{
      component: component_id,
      modules: Keyword.get_values(opts, :module),
      timeout: opts[:timeout] || Mutate.default_timeout(),
      seed: opts[:seed] || Mutate.default_seed(),
      jobs: max(opts[:jobs] || 1, 1),
      contracts: opts[:contracts] || Covenant.contracts_dir(),
      test_paths:
        Keyword.get_values(opts, :test_path)
        |> then(&if(&1 == [], do: Covenant.test_paths(), else: &1)),
      out: opts[:out] || Path.join(Mutate.default_dir(component_id), "kill_matrix.json")
    }

    case opts[:raw] do
      nil -> parent(settings)
      raw -> worker(settings, raw, opts[:slice] || "1/1")
    end
  end

  # -- parent: spawn workers, merge, report -----------------------------------

  defp parent(settings) do
    contract = load_contract(settings.contracts)

    plan =
      case Mutate.plan(contract, settings.component,
             modules: settings.modules,
             test_paths: settings.test_paths
           ) do
        {:ok, plan} -> plan
        {:error, reason} -> fail(reason)
      end

    survivors_path = Survivors.path(settings.contracts, plan.component)

    annotations =
      case Survivors.load(survivors_path) do
        {:ok, annotations} -> annotations
        {:error, errors} -> fail_with(errors, "#{survivors_path} could not be parsed")
      end

    Mix.shell().info(
      "covenant.mutate: #{settings.component} — modules (#{plan.source}): #{Enum.join(plan.names, ", ")}"
    )

    Mix.shell().info("covenant.mutate: tests: #{Enum.join(plan.test_files, ", ")}")

    dir = Mutate.default_dir(settings.component)
    File.mkdir_p!(dir)
    dir |> Path.join("raw-*.json") |> Path.wildcard() |> Enum.each(&File.rm!/1)

    raws =
      1..settings.jobs
      |> Enum.map(fn i ->
        Task.async(fn -> run_worker(settings, plan, i, Path.join(dir, "raw-#{i}.json")) end)
      end)
      |> Task.await_many(:infinity)
      |> Enum.map(fn
        {:ok, raw} -> raw
        {:error, reason} -> fail(reason)
      end)

    results =
      case Mutate.merge(raws) do
        {:ok, results} -> results
        {:error, reason} -> fail(reason)
      end

    Enum.each(results.ignored, fn {name, why} ->
      Mix.shell().info("covenant.mutate: ignoring derived module #{name}: #{why}")
    end)

    matrix =
      Matrix.build(results,
        component: plan.component,
        annotations: annotations,
        survivors_path: survivors_path,
        seed: settings.seed,
        timeout: settings.timeout,
        jobs: settings.jobs
      )

    Mix.shell().info("")
    Mix.shell().info(Matrix.format(matrix))

    File.mkdir_p!(Path.dirname(settings.out))
    File.write!(settings.out, [Covenant.JSON.pretty(Matrix.to_map(matrix)), "\n"])
    Mix.shell().info("\nwrote #{settings.out}")

    unsorted = for %{mutant: m, sort: nil} <- matrix.survivors, do: m

    if unsorted != [] do
      Mix.shell().info("\nTo annotate the unsorted survivors, add to #{survivors_path}:\n")
      Enum.each(unsorted, &Mix.shell().info(Survivors.template(&1)))
    end

    Mix.shell().info("")
    Enum.each(matrix.problems, &Mix.shell().error(Error.format(&1)))

    if Matrix.ok?(matrix) do
      Mix.shell().info(
        IO.ANSI.format([:green, "covenant.mutate: every mutant is caught or sorted"])
      )

      :ok
    else
      fail("#{length(matrix.problems)} problem(s) in the kill matrix")
    end
  end

  defp run_worker(settings, plan, i, raw_path) do
    mix = System.find_executable("mix") || Mix.raise("cannot find the `mix` executable on PATH")

    args =
      [
        "covenant.mutate",
        settings.component,
        "--raw",
        raw_path,
        "--slice",
        "#{i}/#{settings.jobs}"
      ] ++
        [
          "--timeout",
          Integer.to_string(settings.timeout),
          "--seed",
          Integer.to_string(settings.seed)
        ] ++
        ["--contracts", settings.contracts] ++
        Enum.flat_map(plan.names, &["--module", &1]) ++
        Enum.flat_map(settings.test_paths, &["--test-path", &1])

    env = [{"MIX_ENV", "test"}, {"COVENANT_MUTATE_SOURCE", Atom.to_string(plan.source)}]

    case System.cmd(mix, args, env: env, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> Mutate.decode_raw(raw_path)
      {_, status} -> {:error, "worker #{i}/#{settings.jobs} exited with status #{status}"}
    end
  end

  # -- worker: boot the test env, run a slice, write raw results --------------

  defp worker(settings, raw_path, slice) do
    {i, n} = parse_slice(slice)
    prefix = if n > 1, do: "[#{i}/#{n}] ", else: ""

    Mix.Task.run("compile", [])
    Mix.Task.run("app.start", [])

    contract = load_contract(settings.contracts)

    plan =
      case Mutate.plan(contract, settings.component,
             modules: settings.modules,
             test_paths: settings.test_paths
           ) do
        {:ok, plan} -> plan
        {:error, reason} -> fail(reason)
      end

    source = source_from_env(plan.source)

    {modules, ignored} =
      case Modules.locate(plan.names, source, File.cwd!()) do
        {:ok, modules, ignored} -> {modules, ignored}
        {:error, reason} -> fail("cannot mutate `#{settings.component}`: #{reason}")
      end

    if n == 1 or i == 1 do
      Enum.each(modules, fn {module, file} ->
        Mix.shell().info(
          "#{prefix}covenant.mutate: #{inspect(module)} (#{Path.relative_to_cwd(file)})"
        )
      end)
    end

    runner_plan = %{
      component: settings.component,
      modules: modules,
      test_files: plan.test_files,
      root: File.cwd!(),
      seed: settings.seed,
      timeout: settings.timeout,
      slice: {i, n},
      on_progress: &Mix.shell().info(prefix <> progress(&1))
    }

    case Runner.run(runner_plan) do
      {:ok, result} ->
        Mix.shell().info(
          "#{prefix}covenant.mutate: baseline #{length(result.tests)} test(s) green in #{result.baseline_ms} ms; " <>
            "#{length(result.mutants)} of #{result.all} mutant(s) run"
        )

        File.mkdir_p!(Path.dirname(raw_path))

        File.write!(raw_path, [
          Mutate.encode_raw(result,
            component: settings.component,
            slice: slice,
            modules: Enum.map(modules, fn {m, _} -> inspect(m) end),
            ignored: ignored
          ),
          "\n"
        ])

        :ok

      {:error, reason} ->
        fail(reason)
    end
  end

  defp progress(%Mutant{} = m) do
    verdict =
      case m.verdict do
        :killed -> "killed by #{length(m.killed_by)} test(s)"
        :survived -> "SURVIVED"
        :timeout -> "TIMEOUT (survivor)"
        :invalid -> "invalid: #{m.reason}"
      end

    "  #{m.id} #{Mutant.at(m)} #{m.operator} #{Mutant.mutation(m)}  #{verdict}"
  end

  defp parse_slice(slice) do
    with [i, n] <- String.split(slice, "/"),
         {i, ""} <- Integer.parse(i),
         {n, ""} <- Integer.parse(n),
         true <- i >= 1 and n >= 1 and i <= n do
      {i, n}
    else
      _ -> Mix.raise("--slice must be I/N with 1 <= I <= N, got #{inspect(slice)}")
    end
  end

  # The parent resolved the names and passes them as --module; the worker must
  # still know whether they were derived (lenient) or explicit (strict).
  defp source_from_env(default) do
    case System.get_env("COVENANT_MUTATE_SOURCE") do
      "derived" -> :derived
      "front_matter" -> :front_matter
      "flag" -> :flag
      _ -> default
    end
  end

  # -- shared -----------------------------------------------------------------

  defp load_contract(dir) do
    case Contract.load(dir) do
      {:ok, contract} -> contract
      {:error, errors} -> fail_with(errors, "the Contract in #{dir} could not be parsed")
    end
  end

  @spec fail_with([Error.t()], String.t()) :: no_return()
  defp fail_with(errors, message) do
    Enum.each(Error.sort(errors), &Mix.shell().error(Error.format(&1)))
    fail(message)
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message) do
    Mix.shell().error(
      IO.ANSI.format([:red, "covenant.mutate: ", message])
      |> IO.iodata_to_binary()
    )

    exit({:shutdown, 1})
  end
end
