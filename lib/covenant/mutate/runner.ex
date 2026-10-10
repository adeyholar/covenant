defmodule Covenant.Mutate.Runner do
  @moduledoc """
  Runs a component's contract tests against every mutant, in one VM.

  The test environment is booted once: ExUnit is started with `autorun: false`
  **before** the project's `test_helper.exs` is required (the helper's own
  `ExUnit.start` then cannot arm the at-exit run), the component's contract
  test files are required, and the formatters are replaced by `Collector` so
  that `Covenant.Formatter` never overwrites the real results with a mutant's.

  Then, per mutant: the implementation modules of the file are purged, the
  mutated AST is compiled and loaded in memory (`Covenant.Mutate.Mutator.compile/2`),
  `ExUnit.run/1` runs the test modules, and the originals are reloaded from
  their beam files. No file is written by a mutant.

  The baseline (unmutated) run must be green; otherwise nothing is mutated.
  Every test runs with the plan's `timeout` — or, when the plan gives none,
  with `Covenant.Mutate.default_timeout/1` of the baseline's own durations —
  and a failure that is only an `ExUnit.TimeoutError` never counts as a kill
  (record `timeouts-are-survivors`).

  With `fail_fast: true` a mutant's run stops at its first failing test
  (`max_failures: 1`): the verdict is the same, the credit is `:partial`. A
  timeout counts as a failure to ExUnit, so a run that stopped on nothing but a
  timeout says nothing about the tests it skipped, and is run again in full.
  """

  alias Covenant.Mutate
  alias Covenant.Mutate.{Mutant, Mutator, Workdir}

  # what the baseline runs under when the plan gives no timeout: ExUnit's own default
  @baseline_timeout 60_000

  defmodule Collector do
    @moduledoc """
    The ExUnit formatter of a mutant run: collects every finished test and
    sends them to the `:covenant_sink` process at suite end.
    """

    use GenServer

    @impl true
    def init(opts) do
      {:ok,
       %{
         sink: Keyword.fetch!(opts, :covenant_sink),
         root: Keyword.fetch!(opts, :covenant_root),
         finished: []
       }}
    end

    @impl true
    def handle_cast({:test_finished, %ExUnit.Test{} = test}, state),
      do:
        {:noreply,
         %{state | finished: [Covenant.Mutate.Runner.entry(test, state.root) | state.finished]}}

    def handle_cast({:suite_finished, _}, state) do
      send(state.sink, {:covenant_mutate_run, Enum.reverse(state.finished)})
      {:noreply, state}
    end

    def handle_cast(_event, state), do: {:noreply, state}
  end

  @typedoc "A finished test: identity, obligations and outcome."
  @type entry :: %{
          key: String.t(),
          module: String.t(),
          name: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          obligations: [String.t()],
          mutation_blind: String.t() | nil,
          outcome: :passed | :failed | :timeout | :invalid | :skipped | :excluded,
          ms: non_neg_integer()
        }

  @typedoc """
  What a run needs:

  * `:component` — the component id;
  * `:modules` — `{module, source file}` pairs (`Covenant.Mutate.Modules.locate/3`);
  * `:test_files` — the component's contract test files;
  * `:root` — the project root (files are reported relative to it);
  * `:seed` — the ExUnit seed;
  * `:timeout` — per-test timeout in ms for the mutant runs, or `nil` to
    measure it from the baseline (`Covenant.Mutate.default_timeout/1`);
  * `:slice` — `{i, n}`: run every n-th mutant starting at the i-th (1-based);
  * `:on_progress` — called with each mutant once it has a verdict;
  * `:on_eta` — (optional) called with `%{done: d, total: t, elapsed_ms: ms}`
    after every 25th mutant of the slice (`Covenant.Mutate.progress_due?/2`);
  * `:fail_fast` — (optional, default `false`) stop each mutant's run at its
    first failing test: exact verdict, `credit: :partial` on a kill;
  * `:isolate` — (optional, default `false`) run the tests from a private
    working directory (`Covenant.Mutate.Workdir`), so that parallel workers
    never share ExUnit's `:tmp_dir` paths.
  """
  @type plan :: %{
          required(:component) => String.t(),
          required(:modules) => [{module(), Path.t()}],
          required(:test_files) => [Path.t()],
          required(:root) => Path.t(),
          required(:seed) => non_neg_integer(),
          required(:timeout) => pos_integer() | nil,
          required(:slice) => {pos_integer(), pos_integer()},
          required(:on_progress) => (Mutant.t() -> any()),
          optional(:on_eta) => (map() -> any()),
          optional(:fail_fast) => boolean(),
          optional(:isolate) => boolean()
        }

  @type result :: %{
          tests: [entry()],
          mutants: [Mutant.t()],
          all: non_neg_integer(),
          baseline_ms: non_neg_integer(),
          timeout_ms: pos_integer(),
          files: [Path.t()]
        }

  @doc "Boots the suite, checks the baseline and runs the plan's slice of mutants."
  @spec run(plan()) :: {:ok, result()} | {:error, String.t()}
  def run(plan) do
    with {:ok, files} <- prepare_files(plan),
         {:ok, modules} <- boot_suite(plan) do
      isolated(plan, fn -> run_suite(plan, files, modules) end)
    end
  end

  defp run_suite(plan, files, modules) do
    with {:ok, tests, baseline_ms} <- baseline(modules) do
      timeout = plan.timeout || Mutate.default_timeout(tests)
      ExUnit.configure(timeout: timeout)

      mutants = files |> Enum.flat_map(& &1.mutants) |> Mutator.numbered()
      {i, n} = plan.slice

      slice =
        mutants
        |> Enum.with_index()
        |> Enum.filter(fn {_, position} -> rem(position, n) == i - 1 end)

      started = System.monotonic_time(:millisecond)

      verdicts =
        slice
        |> Enum.with_index(1)
        |> Enum.map(fn {{mutant, _}, done} ->
          file = Enum.find(files, &(&1.relative == mutant.file))
          mutant = run_mutant(mutant, file, modules, Map.get(plan, :fail_fast, false))
          plan.on_progress.(mutant)
          eta(plan, done, length(slice), started)
          mutant
        end)

      {:ok,
       %{
         tests: tests,
         mutants: verdicts,
         all: length(mutants),
         baseline_ms: baseline_ms,
         timeout_ms: timeout,
         files: Enum.map(files, & &1.relative)
       }}
    end
  end

  defp eta(%{on_eta: on_eta}, done, total, started) do
    if Mutate.progress_due?(done, total) do
      on_eta.(%{
        done: done,
        total: total,
        elapsed_ms: System.monotonic_time(:millisecond) - started
      })
    end
  end

  defp eta(_plan, _done, _total, _started), do: :ok

  # ExUnit puts a test's `:tmp_dir` under `tmp/` in the OS process's working
  # directory, so workers running side by side must not share it. The suite is
  # already compiled and loaded, so only what the tests do at run time sees the
  # private directory.
  defp isolated(%{isolate: true, root: root}, fun) do
    workdir = Workdir.build(root)

    try do
      Workdir.within(workdir, fun)
    after
      Workdir.remove(workdir)
    end
  end

  defp isolated(_plan, fun), do: fun.()

  # -- files ------------------------------------------------------------------

  defp prepare_files(plan) do
    root = Path.expand(plan.root)

    plan.modules
    |> Enum.group_by(fn {_, file} -> file end, fn {module, _} -> module end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {file, modules}, {:ok, acc} ->
      case prepare_file(file, modules, root) do
        {:ok, prepared} -> {:cont, {:ok, acc ++ [prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare_file(file, modules, root) do
    relative = Path.relative_to(file, root)

    with {:ok, source} <- read(file),
         {:ok, ast} <- Mutator.parse(source, file),
         {:ok, compiled} <- roundtrip(ast, file) do
      originals = Enum.map(compiled, fn {module, bin} -> original(module, bin) end)
      restore(originals)
      targets = Enum.map(modules, &inspect/1)
      mutants = Mutator.sites(ast, file: relative, modules: targets)

      {:ok, %{file: file, relative: relative, ast: ast, originals: originals, mutants: mutants}}
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  # The unmutated AST must compile: otherwise every mutant would be "invalid"
  # for a reason that has nothing to do with the mutation.
  defp roundtrip(ast, file) do
    case Mutator.compile(ast, file) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> {:error, "#{file} does not compile from its own AST: #{reason}"}
    end
  end

  # The beam Mix compiled is the version to restore; a module without one
  # (defined in-memory) falls back to the roundtrip binary.
  defp original(module, roundtrip_bin) do
    case :code.get_object_code(module) do
      {^module, bin, beam} -> {module, bin, beam}
      :error -> {module, roundtrip_bin, ~c"nofile"}
    end
  end

  defp purge(originals), do: Enum.each(originals, fn {module, _, _} -> :code.purge(module) end)

  defp restore(originals) do
    purge(originals)

    Enum.each(originals, fn {module, bin, beam} ->
      {:module, ^module} = :code.load_binary(module, beam, bin)
    end)
  end

  # -- suite ------------------------------------------------------------------

  defp boot_suite(plan) do
    ExUnit.start(autorun: false, formatters: [])

    (Mix.Project.config()[:test_paths] || ["test"])
    |> Enum.map(&Path.join([plan.root, &1, "test_helper.exs"]))
    |> Enum.filter(&File.exists?/1)
    |> Enum.each(&Code.require_file/1)

    ExUnit.configure(
      autorun: false,
      formatters: [Collector],
      covenant_sink: self(),
      covenant_root: Path.expand(plan.root),
      seed: plan.seed,
      timeout: plan.timeout || @baseline_timeout,
      capture_log: true,
      max_failures: :infinity,
      colors: [enabled: false]
    )

    modules =
      plan.test_files
      |> Enum.map(&Path.expand(&1, plan.root))
      |> Enum.flat_map(fn file -> Code.require_file(file) || [] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&contract_module?(&1, plan.component))

    if modules == [] do
      {:error,
       "no contract test module declares `use Covenant.Case, component: \"#{plan.component}\"` " <>
         "in #{Enum.join(plan.test_files, ", ")}"}
    else
      {:ok, modules}
    end
  end

  defp contract_module?(module, component) do
    function_exported?(module, :__ex_unit__, 0) and
      module.__ex_unit__().tags[:covenant_component] == component
  end

  defp baseline(modules) do
    {us, tests} = :timer.tc(fn -> run_tests(modules) end)
    red = Enum.filter(tests, &(&1.outcome in [:failed, :timeout, :invalid]))

    cond do
      tests == [] ->
        {:error, "the contract test modules #{inspect(modules)} define no tests"}

      red != [] ->
        {:error,
         "the baseline is red; fix the suite before mutating:\n" <>
           Enum.map_join(red, "\n", &"  #{&1.name} (#{&1.module}) #{&1.outcome}")}

      true ->
        {:ok, tests, div(us, 1000)}
    end
  end

  @doc false
  @spec run_tests([module()], pos_integer() | :infinity) :: [entry()]
  def run_tests(modules, max_failures \\ :infinity) do
    ExUnit.configure(max_failures: max_failures)
    ExUnit.run(modules)

    receive do
      {:covenant_mutate_run, tests} -> tests
    after
      5_000 -> raise "the mutant run finished but the collector reported nothing"
    end
  end

  # -- mutants ----------------------------------------------------------------

  defp run_mutant(mutant, file, modules, fail_fast) do
    purge(file.originals)

    result =
      case Mutator.compile(Mutator.apply(file.ast, mutant), file.file) do
        {:error, reason} -> %{mutant | verdict: :invalid, reason: reason}
        {:ok, _} -> judge(mutant, modules, fail_fast)
      end

    restore(file.originals)
    %{result | replacement: nil}
  end

  defp judge(mutant, modules, false), do: verdict(mutant, run_tests(modules))

  # Stopping at the first failure leaves a kill's credit partial; a survivor ran every test.
  # A timeout is a failure to ExUnit, so a run that stopped on one proves nothing about the
  # tests it skipped (a later one may kill the mutant): the whole suite settles it.
  defp judge(mutant, modules, true) do
    case verdict(mutant, run_tests(modules, 1)) do
      %Mutant{verdict: :killed} = killed -> %{killed | credit: :partial}
      %Mutant{verdict: :timeout} -> verdict(mutant, run_tests(modules))
      survived -> survived
    end
  end

  @doc "The verdict of a mutant given the tests that ran against it."
  @spec verdict(Mutant.t(), [entry()]) :: Mutant.t()
  def verdict(%Mutant{} = mutant, tests) do
    killers = for t <- tests, t.outcome in [:failed, :invalid], do: t.key
    timeouts = for t <- tests, t.outcome == :timeout, do: t.key

    verdict =
      cond do
        killers != [] -> :killed
        timeouts != [] -> :timeout
        true -> :survived
      end

    %{mutant | verdict: verdict, killed_by: killers, timeouts: timeouts}
  end

  @doc """
  The identity, obligations, outcome and duration (`ms`, rounded up) of a finished
  `ExUnit.Test`; files are relative to `root`.
  """
  @spec entry(ExUnit.Test.t(), Path.t()) :: entry()
  def entry(%ExUnit.Test{tags: tags} = test, root) do
    module = inspect(test.module)
    name = Atom.to_string(test.name)

    %{
      key: module <> ":" <> name,
      module: module,
      name: name,
      file: tags[:file] && Path.relative_to(tags[:file], root),
      line: tags[:line],
      obligations: tags[:obligation] |> List.wrap() |> Enum.map(&to_string/1),
      mutation_blind: tags[:mutation_blind] && to_string(tags[:mutation_blind]),
      outcome: outcome(test.state),
      ms: div(test.time + 999, 1000)
    }
  end

  defp outcome(nil), do: :passed
  defp outcome({:skipped, _}), do: :skipped
  defp outcome({:excluded, _}), do: :excluded
  defp outcome({:invalid, _}), do: :invalid

  defp outcome({:failed, failures}) do
    if Enum.all?(failures, &match?({_, %ExUnit.TimeoutError{}, _}, &1)),
      do: :timeout,
      else: :failed
  end
end
