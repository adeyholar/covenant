defmodule Covenant.Check do
  @moduledoc """
  The checks behind `mix covenant.check`, as a pure function of the Contract
  and a test run.

  `run/3` fails (returns problems) on:

  * dangling `record`, `invariant`, `superseded_by` or `depends_on` references;
  * an active obligation with no tagged test, or (in a run) no passing one: tagged tests that
    were skipped or excluded are named in the problem;
  * a tag naming an obligation the Contract does not declare;
  * a tagged test that failed or could not run;
  * a `kind: exception` whose `target` no longer exists (stale exception);
  * a scope ceiling whose count exceeds its limit.

  Malformed blocks are reported earlier, by `Covenant.Contract.load/2`.

  `Report.warnings` holds what is worth saying but never fails the check: the components that
  declare no modules (no `#### Modules` paragraph in the Public surface and no `modules:` front
  matter), whose pack `mix covenant.regen` can only guess the ownership of, and the `module`
  ceilings whose counter raised, which are left unchecked.

  With `mode: :static` (`mix covenant.check --static`, where the code under
  test is not compiled) the checks that need compiled code are skipped and
  listed in `Report.skipped` instead of failing: exception targets naming a
  module or function, `module` ceiling counters and the `covers` lines of
  the sibling layout. File targets and `glob` counters are still checked,
  and `failing/2` finds nothing because static tests never ran.

  For the primitives of the sibling layout it also fails, as `flinch contract`
  does, on a `covers` line that names no code, on two primitives that name the
  same code, and on a test outside the sibling layout's directory that names
  a primitive's obligation (`strays/2` finds the comments and tags in the
  source).
  """

  alias Covenant.Contract
  alias Covenant.Contract.{Ceiling, Component, Obligation, Validate}
  alias Covenant.Parser.Primitive
  alias Covenant.Regen.Ownership
  alias Covenant.{Coverage, Covers, Error, Results, Target}

  defmodule Report do
    @moduledoc """
    What a check produced: sorted problems, the coverage table, (static
    mode) the checks skipped for want of compiled code, as `{kind, name}`
    with kind `:exception`, `:ceiling` or `:covers`, and the warnings, which never
    make `ok?/1` false.
    """

    @type t :: %__MODULE__{
            problems: [Covenant.Error.t()],
            coverage: Covenant.Coverage.t(),
            skipped: [{:exception | :ceiling | :covers, String.t()}],
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
    against (default: the current directory; `mix covenant.check` passes `Covenant.root/0`);
  * `:mode` — `:run` (default) or `:static`;
  * `:sibling` — the sibling layout's directory, outside which no test may
    name a primitive's obligation (default: none);
  * `:modules` — the project's modules a `covers` tree may name (default
    `Covenant.Covers.project_modules/0`).
  """
  @spec run(Contract.t(), Results.t(), keyword()) :: Report.t()
  def run(%Contract{} = contract, %Results{} = results, opts \\ []) do
    root = Keyword.get(opts, :root) || File.cwd!()
    static? = Keyword.get(opts, :mode, :run) == :static
    by_obligation = Results.by_obligation(results)

    {exceptions, skipped_exceptions} = stale_exceptions(contract, root, static?)
    {ceilings, skipped_ceilings, unchecked_ceilings} = ceilings(contract, root, static?)
    {covers, skipped_covers} = covers(contract, static?, opts)

    problems =
      Validate.dangling(contract) ++
        untested(contract, by_obligation, static?) ++
        unknown_tags(contract, by_obligation) ++
        failing(contract, by_obligation) ++
        exceptions ++
        ceilings ++
        covers ++
        overlapping(contract) ++
        outside(contract, results, root, opts[:sibling])

    coverage =
      Coverage.compute(contract, results, covered: if(static?, do: :tagged, else: :passing))

    %Report{
      problems: Error.sort(problems),
      coverage: coverage,
      skipped: Enum.sort(skipped_exceptions ++ skipped_ceilings ++ skipped_covers),
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

  # A run needs a passing test; a tagged test that was skipped or excluded proves nothing.
  # Static mode ran nothing, so a tagged test is all it can ask for.
  defp untested(contract, by_obligation, static?) do
    for %Obligation{} = obligation <- Contract.obligations(contract),
        Obligation.testable?(obligation),
        tests = Map.get(by_obligation, obligation.id, []),
        problem = untested_problem(obligation, tests, static?) do
      Error.new(obligation.file, obligation.line, problem)
    end
  end

  defp untested_problem(obligation, [], _static?), do: untested_message(obligation)
  defp untested_problem(_obligation, _tests, true), do: nil

  defp untested_problem(%Obligation{id: id}, tests, false) do
    if Enum.any?(tests, &(&1.state == :passed)) do
      nil
    else
      idle =
        tests
        |> Enum.filter(&(&1.state in [:skipped, :excluded]))
        |> Enum.uniq_by(&{&1.module, &1.name})

      if idle == [] do
        nil
      else
        "active obligation `#{id}` has no passing test: #{length(idle)} tagged test(s) were skipped or excluded: " <>
          Enum.map_join(idle, ", ", & &1.name) <>
          "; run them, or declare the obligation an exception if it is proven elsewhere"
      end
    end
  end

  defp untested_message(%Obligation{id: id} = obligation) do
    if String.contains?(id, "/") do
      "obligation `#{id}` is named by no Contract test; " <>
        "put `# Contract: #{id}` above the test in #{Path.dirname(obligation.file)} that proves it"
    else
      "active obligation `#{id}` has no tagged test; " <>
        "add `@tag obligation: \"#{id}\"` to the contract test that proves it"
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
        # a parameterized test is one result per parameter under one module and name: each failure counts
        test <- Enum.uniq_by(tests, &{&1.module, &1.name, &1.state}),
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

  # -- the sibling layout ------------------------------------------------------

  defp primitives(contract) do
    contract.components
    |> Map.values()
    |> Enum.filter(&(&1.form == :primitive))
    |> Enum.sort_by(& &1.id)
  end

  defp covers(contract, static?, opts) do
    primitives = primitives(contract)

    if static? do
      {[], for(%Component{id: id, covers: [_ | _]} <- primitives, do: {:covers, id})}
    else
      modules = Keyword.get_lazy(opts, :modules, &Covers.project_modules/0)

      problems =
        for %Component{} = primitive <- primitives,
            %Covers{} = cover <- primitive.covers,
            not Covers.exists?(cover.ref, modules) do
          Error.new(
            cover.file,
            cover.line,
            "covers `#{cover.text}` names no code in this project " <>
              "(#{covers_hint(cover.ref)}); point it at the code `#{primitive.id}` covers or delete it"
          )
        end

      {problems, []}
    end
  end

  defp covers_hint({:function, _, _, _}), do: "no public function of that name and arity"
  defp covers_hint({:tree, _}), do: "no module of that name or under it"
  defp covers_hint({:module, _}), do: "no module of that name"

  # Two primitives naming the same code leave the most-specific rule no winner.
  defp overlapping(contract) do
    contract
    |> primitives()
    |> Enum.flat_map(fn primitive -> Enum.map(primitive.covers, &{&1, primitive.id}) end)
    |> Enum.group_by(fn {cover, _} -> cover.ref end)
    |> Enum.flat_map(fn
      {_, [_]} ->
        []

      {_, [{_, first} | rest]} ->
        for {cover, id} <- rest do
          Error.new(
            cover.file,
            cover.line,
            "`#{id}` covers `#{cover.text}`, which `#{first}` covers too; one primitive owns a piece of code"
          )
        end
    end)
  end

  # A test that ran outside the sibling layout's directory but names a primitive's obligation.
  defp outside(_contract, _results, _root, nil), do: []

  defp outside(contract, %Results{tests: tests}, root, sibling) do
    for %Results.Test{file: file} = test <- tests,
        file != nil,
        Primitive.primitive_of(Path.expand(file, root), sibling) == nil,
        id <- test.obligations,
        match?(%Obligation{}, Contract.obligation(contract, id)),
        String.contains?(id, "/") do
      Error.new(file, test.line, stray_message(test.name, id))
    end
  end

  defp stray_message(name, id),
    do:
      "#{name} names `#{id}` outside the sibling layout's directory; " <>
        "a primitive's Contract tests live beside its README"

  @doc """
  The `# Contract:` comments and `obligation:` tags naming a primitive's
  obligation (`calc/A1`) in `files` outside `sibling` (the sibling layout's
  directory): only the Contract tests beside a primitive's README may name
  one. Read from the source, so they are found whether or not the test runs.
  """
  @spec strays([Path.t()], Path.t() | nil) :: [Error.t()]
  def strays(_files, nil), do: []

  def strays(files, sibling) do
    for file <- Enum.sort(Enum.uniq(files)),
        Primitive.primitive_of(file, sibling) == nil,
        {:ok, text} <- [File.read(file)],
        line <- stray_lines(text) do
      Error.new(
        file,
        line,
        "a Contract comment or tag naming a primitive's obligation outside the sibling layout's " <>
          "directory; a primitive's Contract tests live beside its README"
      )
    end
  end

  # Real comments and real `@tag`/`@describetag`/`@moduletag obligation:` attributes
  # only: the same text inside a string is not a claim.
  defp stray_lines(text) do
    case Code.string_to_quoted_with_comments(text, emit_warnings: false) do
      {:ok, ast, comments} ->
        commented =
          for %{text: c, line: line} <- comments, Primitive.contract_comment?(c), do: line

        {_, tagged} =
          Macro.prewalk(ast, [], fn
            {:@, meta, [{level, _, [value]}]} = node, acc
            when level in [:tag, :describetag, :moduletag] and is_list(value) ->
              ids = if Keyword.keyword?(value), do: List.wrap(value[:obligation]), else: []
              {node, if(Enum.any?(ids, &primitive_id?/1), do: [meta[:line] | acc], else: acc)}

            node, acc ->
              {node, acc}
          end)

        Enum.sort(Enum.uniq(commented ++ tagged))

      _ ->
        []
    end
  end

  defp primitive_id?(id),
    do: is_binary(id) and Regex.match?(~r/^[a-z][a-z0-9_]*\/[A-Z]+[0-9]+$/, id)

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
