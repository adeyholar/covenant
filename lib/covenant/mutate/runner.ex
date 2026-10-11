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

  # a mutant's wall-clock budget: ExUnit's per-test timeout does not bound a
  # `setup_all`, nor a test tagged `timeout: :infinity`
  @budget_factor 10
  @budget_extra_ms 5_000
  @timeout_exit 3

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
  * `:on_timeout` — (optional) called with the results so far, the timed-out
    mutant included with the verdict `:timeout`, and that mutant when a
    mutant's run outlasts its wall-clock budget (`budget_ms/2`); it is meant to
    write the results to disk and `System.halt(timeout_exit())`. If it returns,
    the run is an error;
  * `:skip` — (optional) ids of mutants not to run (those a worker that was
    stopped had already judged);
  * `:isolate` — (optional, default `true`) run the tests from a private copy
    of the project (`Covenant.Mutate.Workdir`), so that a mutant's relative
    writes and deletes never reach the project and parallel workers never
    share ExUnit's `:tmp_dir` paths; `false` runs in the project root.
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
          optional(:keep) => (Mutant.t() -> boolean()),
          optional(:on_timeout) => (result(), Mutant.t() -> any()),
          optional(:skip) => [String.t()],
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
      case isolated(plan, fn -> run_suite(plan, files, modules) end) do
        {:timeout, result, mutant} -> expired(plan, result, mutant)
        other -> other
      end
    end
  end

  defp run_suite(plan, files, modules) do
    with {:ok, tests, baseline_ms} <- baseline(modules) do
      timeout = plan.timeout || Mutate.default_timeout(tests)
      ExUnit.configure(timeout: timeout)
      apps = started_apps()
      budget = budget_ms(baseline_ms, timeout)

      mutants =
        files
        |> Enum.flat_map(& &1.mutants)
        |> Enum.filter(Map.get(plan, :keep, fn _ -> true end))
        |> Mutator.numbered()

      {i, n} = plan.slice
      skip = Map.get(plan, :skip, [])

      slice =
        mutants
        |> Enum.with_index()
        |> Enum.filter(fn {_, position} -> rem(position, n) == i - 1 end)
        |> Enum.reject(fn {mutant, _} -> mutant.id in skip end)

      result = fn verdicts ->
        %{
          tests: tests,
          mutants: verdicts,
          all: length(mutants),
          baseline_ms: baseline_ms,
          timeout_ms: timeout,
          files: Enum.map(files, & &1.relative)
        }
      end

      env = %{
        plan: plan,
        files: files,
        modules: modules,
        apps: apps,
        budget: budget,
        total: length(slice),
        started: System.monotonic_time(:millisecond),
        result: result
      }

      slice
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {{mutant, _}, done}, verdicts ->
        case step(mutant, done, verdicts, env) do
          {:ok, ran} -> {:cont, [ran | verdicts]}
          other -> {:halt, other}
        end
      end)
      |> finish(modules, env)
    end
  end

  # One mutant: run it, then check that the VM still holds what the baseline had.
  defp step(mutant, done, verdicts, env) do
    file = Enum.find(env.files, &(&1.relative == mutant.file))
    fail_fast = Map.get(env.plan, :fail_fast, false)

    case run_mutant(mutant, file, env.modules, fail_fast, env.budget) do
      {:ok, ran} ->
        with :ok <- healthy(ran, env) do
          env.plan.on_progress.(ran)
          eta(env.plan, done, env.total, env.started)
          {:ok, ran}
        end

      {:error, reason} ->
        {:error, reason}

      :budget ->
        timed_out(mutant, verdicts, env)
    end
  end

  defp finish({:error, reason}, _modules, _env), do: {:error, reason}
  defp finish({:timeout, _, _} = timeout, _modules, _env), do: timeout

  defp finish([], _modules, env), do: {:ok, env.result.([])}

  defp finish([last | _] = verdicts, modules, env) do
    case run_tests(modules, :infinity, env.budget) do
      {:ok, tests} ->
        if red(tests) == [] do
          {:ok, env.result.(Enum.reverse(verdicts))}
        else
          {:error,
           "the unmutated suite is red after the last mutant, #{describe(last)}; " <>
             "this worker's results are unreliable:\n#{format_red(tests)}"}
        end

      :budget ->
        {:error,
         "the unmutated suite did not finish within #{env.budget} ms after the last mutant, " <>
           "#{describe(last)}; this worker's results are unreliable"}
    end
  end

  # What the mutant that outran its time budget leaves behind: it is a timeout (a
  # survivor, never a kill). The VM is suspect (a test may still be spinning), so
  # nothing more runs: `run/1` hands the results to the plan's `:on_timeout`.
  defp timed_out(mutant, verdicts, env) do
    timed_out = %{
      mutant
      | verdict: :timeout,
        reason: "ran past its time budget of #{env.budget} ms (a watchdog stopped the worker)",
        replacement: nil
    }

    {:timeout, env.result.(Enum.reverse([timed_out | verdicts])), timed_out}
  end

  # The working directory is the project's again here. `:on_timeout` persists the
  # results and halts the worker with `timeout_exit/0`; without one, or if it
  # returns, the run is an error.
  defp expired(plan, result, mutant) do
    with %{on_timeout: on_timeout} <- plan, do: on_timeout.(result, mutant)

    {:error,
     "#{describe(mutant)} ran past its time budget (#{mutant.reason}); a test loops outside " <>
       "ExUnit's per-test timeout"}
  end

  @doc "The wall-clock budget of one mutant's run, in ms, given the baseline's duration and per-test timeout."
  @spec budget_ms(non_neg_integer(), pos_integer()) :: pos_integer()
  def budget_ms(baseline_ms, timeout_ms),
    do: @budget_factor * baseline_ms + @budget_extra_ms + timeout_ms

  @doc "The exit status of a worker its watchdog stopped."
  @spec timeout_exit() :: pos_integer()
  def timeout_exit, do: @timeout_exit

  # -- health -----------------------------------------------------------------

  defp started_apps,
    do: 10_000 |> Application.started_applications() |> MapSet.new(&elem(&1, 0))

  # A mutant can take the VM with it: purging its module kills a process running
  # the old code, a supervisor gives up, an application stops, and every later
  # mutant then "fails" its tests, which would be credited as kills. So after each
  # mutant's restore the applications the baseline had must all still run (else
  # they are restarted and the unmutated suite must be green again), and the
  # worker's directory must still exist. The mutant whose run did it keeps its verdict.
  defp healthy(mutant, env) do
    with :ok <- directory(mutant) do
      case MapSet.to_list(MapSet.difference(env.apps, started_apps())) do
        [] -> :ok
        missing -> recover(mutant, missing, env)
      end
    end
  end

  defp directory(mutant) do
    case File.cwd() do
      {:ok, cwd} ->
        if File.dir?(cwd),
          do: :ok,
          else: {:error, "#{describe(mutant)} broke the VM: it deleted the working directory"}

      {:error, _} ->
        {:error, "#{describe(mutant)} broke the VM: it deleted the working directory"}
    end
  end

  defp recover(mutant, missing, env) do
    names = Enum.map_join(missing, ", ", &inspect/1)

    failed =
      Enum.find_value(missing, fn app ->
        case Application.ensure_all_started(app) do
          {:ok, _} -> nil
          {:error, reason} -> {app, reason}
        end
      end)

    with nil <- failed,
         {:ok, tests} <- run_tests(env.modules, :infinity, env.budget),
         [] <- red(tests) do
      :ok
    else
      {app, reason} ->
        {:error,
         "#{describe(mutant)} broke the VM: it stopped #{names} and #{inspect(app)} " <>
           "would not restart (#{inspect(reason)})"}

      :budget ->
        {:error,
         "#{describe(mutant)} broke the VM: it stopped #{names}, and the unmutated suite " <>
           "did not finish within #{env.budget} ms after they restarted"}

      red ->
        {:error,
         "#{describe(mutant)} broke the VM: it stopped #{names}, and the unmutated suite " <>
           "is red after they restarted:\n#{format_red(red)}"}
    end
  end

  defp red(tests), do: Enum.filter(tests, &(&1.outcome in [:failed, :timeout, :invalid]))

  defp format_red(tests),
    do:
      Enum.map_join(red(tests) |> List.wrap(), "\n", &"  #{&1.name} (#{&1.module}) #{&1.outcome}")

  defp describe(%Mutant{} = mutant),
    do: "mutant #{mutant.id} (#{Mutant.at(mutant)} #{mutant.operator})"

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

  # A mutant runs the project's own code, so it must not run in the project
  # root, and ExUnit puts a test's `:tmp_dir` under `tmp/` in the OS process's
  # working directory, so workers running side by side must not share it. The
  # suite is already compiled and loaded, so only what the tests do at run time
  # sees the private copy.
  defp isolated(%{isolate: false}, fun), do: fun.()

  defp isolated(%{root: root}, fun) do
    workdir = Workdir.build(root)

    try do
      Workdir.within(workdir, fun)
    after
      Workdir.remove(workdir)
    end
  end

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
    |> nothing_to_mutate(plan)
  end

  # A run without a single mutant site proves nothing, and is usually a module
  # that is not defined where it was said to be.
  defp nothing_to_mutate({:ok, files}, plan) do
    if Enum.all?(files, &(&1.mutants == [])) do
      {:error,
       "no mutant to run: there is nothing to mutate in #{Enum.map_join(plan.modules, ", ", fn {m, _} -> inspect(m) end)} " <>
         "where #{if match?([_], plan.modules), do: "it was", else: "they were"} found"}
    else
      {:ok, files}
    end
  end

  defp nothing_to_mutate(error, _plan), do: error

  defp prepare_file(file, modules, root) do
    relative = Path.relative_to(file, root)

    with {:ok, source} <- read(file),
         {:ok, ast} <- Mutator.parse(source, file),
         {:ok, compiled} <- roundtrip(ast, file) do
      originals = Enum.map(compiled, fn {module, bin} -> original(module, bin) end)
      targets = Enum.map(modules, &inspect/1)
      mutants = Mutator.sites(ast, file: relative, modules: targets)

      with :ok <- restore(originals) do
        for module <- without_mutants(targets, mutants) do
          IO.puts(
            :stderr,
            "warning: no mutant in #{module} (#{relative}): it is not defined there or has nothing to mutate"
          )
        end

        {:ok, %{file: file, relative: relative, ast: ast, originals: originals, mutants: mutants}}
      end
    end
  end

  @doc false
  @spec without_mutants([String.t()], [Mutant.t()]) :: [String.t()]
  def without_mutants(targets, mutants) do
    present = MapSet.new(mutants, & &1.module)
    Enum.reject(targets, &MapSet.member?(present, &1))
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

  # Loads every original back and answers an error naming those that would not
  # load (a NIF `on_load` that fails on a second load, say); the others are restored.
  @doc false
  @spec restore([{module(), binary(), charlist()}]) :: :ok | {:error, String.t()}
  def restore(originals) do
    purge(originals)

    failed =
      Enum.flat_map(originals, fn {module, bin, beam} ->
        case :code.load_binary(module, beam, bin) do
          {:module, ^module} -> []
          {:error, reason} -> ["#{inspect(module)} (#{inspect(reason)})"]
        end
      end)

    case failed do
      [] -> :ok
      _ -> {:error, "cannot reload #{Enum.join(failed, ", ")}; the module is left unloaded"}
    end
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
    {us, {:ok, tests}} = :timer.tc(fn -> run_tests(modules, :infinity, :infinity) end)
    red = red(tests)

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

  # The suite runs in a task and this process waits for the collector's report, so
  # a suite that never ends (a `setup_all` that loops) is `:budget`, not a hang.
  @doc false
  @spec run_tests([module()], pos_integer() | :infinity, pos_integer() | :infinity) ::
          {:ok, [entry()]} | :budget
  def run_tests(modules, max_failures, budget) do
    ExUnit.configure(max_failures: max_failures)
    task = Task.async(fn -> ExUnit.run(modules) end)

    receive do
      {:covenant_mutate_run, tests} ->
        Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
        {:ok, tests}
    after
      budget ->
        Task.shutdown(task, :brutal_kill)
        :budget
    end
  end

  # -- mutants ----------------------------------------------------------------

  defp run_mutant(mutant, file, modules, fail_fast, budget) do
    purge(file.originals)

    judged =
      case Mutator.compile(Mutator.apply(file.ast, mutant), file.file) do
        {:error, reason} -> {:ok, %{mutant | verdict: :invalid, reason: reason}}
        {:ok, _} -> judge(mutant, modules, fail_fast, budget)
      end

    case {judged, restore(file.originals)} do
      {_, {:error, reason}} -> {:error, "#{describe(mutant)}: #{reason}"}
      {{:ok, result}, :ok} -> {:ok, %{result | replacement: nil}}
      {:budget, :ok} -> :budget
    end
  end

  defp judge(mutant, modules, false, budget) do
    with {:ok, tests} <- run_tests(modules, :infinity, budget), do: {:ok, verdict(mutant, tests)}
  end

  # Stopping at the first failure leaves a kill's credit partial; a survivor ran every test.
  # A timeout is a failure to ExUnit, so a run that stopped on one proves nothing about the
  # tests it skipped (a later one may kill the mutant): the whole suite settles it.
  defp judge(mutant, modules, true, budget) do
    with {:ok, tests} <- run_tests(modules, 1, budget) do
      case verdict(mutant, tests) do
        %Mutant{verdict: :killed} = killed -> {:ok, %{killed | credit: :partial}}
        %Mutant{verdict: :timeout} -> judge(mutant, modules, false, budget)
        survived -> {:ok, survived}
      end
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
