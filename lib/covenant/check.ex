defmodule Covenant.Check do
  @moduledoc """
  The checks behind `mix covenant.check`, as a pure function of the Contract
  and a test run.

  `run/3` fails (returns problems) on:

  * dangling `record`, `invariant`, `superseded_by` or `depends_on` references;
  * an active obligation with no tagged test;
  * a tag naming an obligation the Contract does not declare;
  * a tagged test that failed or could not run;
  * a `kind: exception` whose `target` no longer exists (stale exception);
  * a scope ceiling whose count exceeds its limit.

  Malformed blocks are reported earlier, by `Covenant.Contract.load/1`.

  `Report.warnings` holds what is worth saying but never fails the check: the components that
  declare no modules (no `#### Modules` paragraph in the Public surface and no `modules:` front
  matter), whose pack `mix covenant.regen` can only guess the ownership of, and the `module`
  ceilings whose counter raised, which are left unchecked.

  With `mode: :static` (`mix covenant.check --static`, where the code under
  test is not compiled) the checks that need compiled code are skipped and
  listed in `Report.skipped` instead of failing: exception targets naming a
  module or function, and `module` ceiling counters. File targets and `glob`
  counters are still checked, and `failing/2` finds nothing because static
  tests never ran.
  """

  alias Covenant.Contract
  alias Covenant.Contract.{Ceiling, Component, Obligation, Validate}
  alias Covenant.Regen.Ownership
  alias Covenant.{Coverage, Error, Results, Target}

  defmodule Report do
    @moduledoc """
    What a check produced: sorted problems, the coverage table, (static
    mode) the checks skipped for want of compiled code, as `{kind, name}`
    with kind `:exception` or `:ceiling`, and the warnings, which never
    make `ok?/1` false.
    """

    @type t :: %__MODULE__{
            problems: [Covenant.Error.t()],
            coverage: Covenant.Coverage.t(),
            skipped: [{:exception | :ceiling, String.t()}],
            warnings: [String.t()]
          }

    @enforce_keys [:problems, :coverage]
    defstruct [:problems, :coverage, skipped: [], warnings: []]

    @doc "True when no problem was found."
    @spec ok?(t()) :: boolean()
    def ok?(%__MODULE__{problems: []}), do: true
    def ok?(%__MODULE__{}), do: false
  end

  @doc """
  Runs every check. Options:

  * `:root` — the project root that file targets and glob counters resolve
    against (default: the current directory);
  * `:mode` — `:run` (default) or `:static`.
  """
  @spec run(Contract.t(), Results.t(), keyword()) :: Report.t()
  def run(%Contract{} = contract, %Results{} = results, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    static? = Keyword.get(opts, :mode, :run) == :static
    by_obligation = Results.by_obligation(results)

    {exceptions, skipped_exceptions} = stale_exceptions(contract, root, static?)
    {ceilings, skipped_ceilings, unchecked_ceilings} = ceilings(contract, root, static?)

    problems =
      Validate.dangling(contract) ++
        untested(contract, by_obligation) ++
        unknown_tags(contract, by_obligation) ++
        failing(contract, by_obligation) ++
        exceptions ++
        ceilings

    coverage =
      Coverage.compute(contract, results, covered: if(static?, do: :tagged, else: :passing))

    %Report{
      problems: Error.sort(problems),
      coverage: coverage,
      skipped: Enum.sort(skipped_exceptions ++ skipped_ceilings),
      warnings: undeclared_modules(contract) ++ unchecked_ceilings
    }
  end

  # The whole-product intent has no modules to declare, so `system` is never listed.
  defp undeclared_modules(contract) do
    undeclared =
      for {id, %Component{form: form} = component} <- contract.components,
          form != :system,
          Ownership.listed(component) == [],
          do: id

    case Enum.sort(undeclared) do
      [] -> []
      ids -> ["#{length(ids)} component(s) declare no modules: #{Enum.join(ids, ", ")}"]
    end
  end

  defp untested(contract, by_obligation) do
    for %Obligation{} = obligation <- Contract.obligations(contract),
        Obligation.testable?(obligation),
        Map.get(by_obligation, obligation.id, []) == [] do
      Error.new(
        obligation.file,
        obligation.line,
        "active obligation `#{obligation.id}` has no tagged test; " <>
          "add `@tag obligation: \"#{obligation.id}\"` to the contract test that proves it"
      )
    end
  end

  defp unknown_tags(contract, by_obligation) do
    for {id, tests} <- Enum.sort(by_obligation),
        Contract.obligation(contract, id) == nil,
        test <- tests do
      Error.new(test.file, test.line, "#{test.name} is tagged with unknown obligation `#{id}`")
    end
  end

  defp failing(contract, by_obligation) do
    for {id, tests} <- Enum.sort(by_obligation),
        Contract.obligation(contract, id) != nil,
        test <- Enum.uniq_by(tests, &{&1.module, &1.name}),
        test.state in [:failed, :invalid] do
      Error.new(test.file, test.line, "#{test.name} (obligation `#{id}`) #{test.state}")
    end
  end

  defp stale_exceptions(contract, root, static?) do
    results =
      for %Component{} = component <- Map.values(contract.components),
          %Obligation{} = exception <- Component.exceptions(component) do
        stale_exception(exception, root, static?)
      end

    {for({:problem, p} <- results, do: p), for({:skipped, s} <- results, do: s)}
  end

  defp stale_exception(%Obligation{target: target} = exception, root, static?) do
    case Target.parse(target || "") do
      {:ok, {:function, _, _, _}} when static? ->
        {:skipped, {:exception, exception.id}}

      {:ok, {:module, _}} when static? ->
        {:skipped, {:exception, exception.id}}

      {:ok, parsed} ->
        if Target.exists?(parsed, root) do
          nil
        else
          {:problem,
           Error.new(
             exception.file,
             exception.line,
             "exception `#{exception.id}` targets #{Target.describe(parsed)}, which no longer exists; " <>
               "retire the exception or point it at the code it now covers"
           )}
        end

      {:error, reason} ->
        {:problem,
         Error.new(exception.file, exception.line, "exception `#{exception.id}`: #{reason}")}
    end
  end

  defp ceilings(contract, root, static?) do
    {skipped, counted} =
      Enum.split_with(contract.ceilings, &(static? and match?({:module, _, _}, &1.counter)))

    results = Enum.flat_map(counted, &ceiling(&1, root))

    {for({:problem, p} <- results, do: p), Enum.map(skipped, &{:ceiling, &1.name}),
     for({:unchecked, w} <- results, do: w)}
  end

  defp ceiling(%Ceiling{} = ceiling, root) do
    case Ceiling.count(ceiling, root: root) do
      {:ok, count} when count > ceiling.ceiling ->
        [
          {:problem,
           Error.new(
             ceiling.file,
             ceiling.line,
             "scope ceiling `#{ceiling.name}` exceeded: #{count} > #{ceiling.ceiling} (#{Ceiling.describe(ceiling)})"
           )}
        ]

      {:ok, _} ->
        []

      {:unchecked, what} ->
        [
          {:unchecked,
           "scope ceiling `#{ceiling.name}` unchecked: #{Ceiling.describe(ceiling)} raised #{what}"}
        ]

      {:error, reason} ->
        [
          {:problem,
           Error.new(
             ceiling.file,
             ceiling.line,
             "scope ceiling `#{ceiling.name}` cannot be counted: #{reason}"
           )}
        ]
    end
  end
end
