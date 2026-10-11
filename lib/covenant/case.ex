defmodule Covenant.Case do
  @moduledoc """
  `ExUnit.Case` for contract tests.

  ```elixir
  defmodule Example.CounterContractTest do
    use Covenant.Case, component: "example.counter", async: true

    @tag obligation: "example.counter.I1"
    test "a counter never goes below zero" do
      ...
    end

    @tag obligation: ["example.counter.I2", "example.counter.I3"]
    test "increments are reported in order" do
      ...
    end
  end
  ```

  At compile time the module's tests are checked against the Contract:

  * every test must carry an `obligation` tag (a string or a list of strings);
  * every tagged id must exist in the Contract and be `status: active`;
  * every tagged id must belong to the module's `component`.

  A violation is a compile error that names the test's file and line, so a
  tag naming a typo or a retired obligation never reaches `mix test`.

  ## The sibling layout

  In a file under the sibling layout's directory (`contract/<primitive>/`,
  `Covenant.sibling_dir/0`) the component is the primitive the file sits in,
  and `component:` may be left out. Each test names the obligations it proves
  with comment lines directly above it, as flinch's Contract tests do:

  ```elixir
  defmodule Calc.ContractTest do
    use Covenant.Case, async: true

    # Contract: calc/A1
    test "add sums its arguments" do
      assert Calc.add(2, 3) == 5
    end
  end
  ```

  The comments are read from the source at compile time and become the
  test's `obligation` tag, so they count exactly as `@tag obligation:` does
  (which works there too; both are merged). Several ids go on one line,
  separated by commas, or on several lines. A test with neither, an unknown
  id, and another primitive's id are compile errors. Outside the sibling
  layout a `# Contract:` comment naming a primitive's obligation (`calc/A1`)
  is a compile error, since it would be silently ignored; any other
  `# Contract:` comment there is ordinary prose.

  ## Options

  * `:component` — the component id, e.g. `"example.counter"`; required
    outside the sibling layout.
  * `:contracts` — the contracts directory; defaults to
    `Covenant.contracts_dir/0` (`config :covenant, contracts_dir: ...`).
  * `:sibling` — the sibling layout's directory; defaults to `Covenant.sibling_dir/0`.
  * every other option is passed to `ExUnit.Case` (`:async`, `:register`, ...).

  The module also receives `@moduletag :contract` and
  `@moduletag covenant_component: component`, so `mix test --only contract`
  selects contract tests and `Covenant.Formatter` can credit them.
  """

  alias Covenant.Contract
  alias Covenant.Contract.{Component, Obligation}
  alias Covenant.Parser.Primitive

  defmacro __using__(opts) do
    {component, opts} = Keyword.pop(opts, :component)
    {contracts, opts} = Keyword.pop(opts, :contracts)
    {sibling, opts} = Keyword.pop(opts, :sibling)
    sibling = sibling || Covenant.sibling_dir()
    component = component(component, Primitive.primitive_of(__CALLER__.file, sibling))

    # Registered before `use ExUnit.Case`, so it runs before ExUnit's own hook
    # turns the registered tests into `__ex_unit__/0`, and the obligations read
    # from `# Contract:` comments land in the tests' tags.
    quote do
      @before_compile Covenant.Case
      use ExUnit.Case, unquote(opts)

      @covenant_component unquote(component)
      @covenant_contracts unquote(contracts)
      @covenant_sibling unquote(sibling)
      @moduletag :contract
      @moduletag covenant_component: unquote(component)
    end
  end

  defp component(nil, nil),
    do:
      raise(
        ArgumentError,
        "use Covenant.Case requires component: \"<app>.<component>\" outside the sibling layout, got: nil"
      )

  defp component(component, nil) when not is_binary(component),
    do:
      raise(
        ArgumentError,
        "use Covenant.Case requires component: \"<app>.<component>\", got: #{inspect(component)}"
      )

  defp component(component, nil), do: component
  defp component(nil, primitive), do: primitive
  defp component(primitive, primitive), do: primitive

  defp component(component, primitive),
    do:
      raise(
        ArgumentError,
        "use Covenant.Case names component #{inspect(component)}, but the file sits in the " <>
          "sibling layout's `#{primitive}` primitive; leave component: out or move the file"
      )

  defmacro __before_compile__(env) do
    Covenant.Case.__validate__(env)
    nil
  end

  @doc false
  @spec __validate__(Macro.Env.t()) :: :ok
  def __validate__(env) do
    component_id = Module.get_attribute(env.module, :covenant_component)
    dir = Module.get_attribute(env.module, :covenant_contracts) || Covenant.contracts_dir()
    sibling = Module.get_attribute(env.module, :covenant_sibling) || Covenant.sibling_dir()
    contract = load_contract(dir, sibling, env)

    component =
      Contract.component(contract, component_id) ||
        compile_error(
          env.file,
          env.line,
          "unknown component `#{component_id}` (not in #{dir} or #{sibling}); known components: " <>
            known(Contract.component_ids(contract))
        )

    if component.form == :primitive and Primitive.primitive_of(env.file, sibling) != component.id do
      compile_error(
        env.file,
        env.line,
        "#{inspect(env.module)} tests the primitive `#{component.id}`, whose Contract tests live " <>
          "beside its README in #{Path.dirname(component.file)}"
      )
    end

    # The attribute accumulates newest first; tests are checked in definition order.
    {tests, sources} =
      env.module
      |> Module.get_attribute(:ex_unit_tests)
      |> Enum.reverse()
      |> Enum.map_reduce(seed_sources(env), fn test, sources ->
        {lines, sources} = source_lines(test.tags[:file], sources)
        {validate_test(test, lines, component, contract), sources}
      end)

    if component.form == :primitive, do: check_orphan_comments(tests, sources, env)

    if component.form == :primitive do
      Module.delete_attribute(env.module, :ex_unit_tests)
      Module.register_attribute(env.module, :ex_unit_tests, accumulate: true)
      Enum.each(tests, &Module.put_attribute(env.module, :ex_unit_tests, &1))
    end

    :ok
  end

  # A `# Contract:` comment that is not directly above a test (above a `setup`,
  # a `defp`, a blank line) would be silently ignored, so it is an error.
  defp check_orphan_comments(tests, sources, env) do
    for {file, lines} <- sources do
      attached =
        for %{tags: %{file: ^file, line: line}} <- tests,
            n <- Primitive.attached_comment_lines(lines, line),
            into: MapSet.new(),
            do: n

      # only this module's own lines: another `Covenant.Case` module in the file has its own check
      range = if file == env.file, do: Primitive.module_range(lines, env.line)

      case Enum.find(
             Primitive.contract_comment_lines(lines, range),
             &(not MapSet.member?(attached, &1))
           ) do
        nil ->
          :ok

        n ->
          compile_error(
            file,
            n,
            "this `# Contract:` comment is not directly above a test, so it would be ignored; " <>
              "put it on the lines above a `test`, or remove it"
          )
      end
    end

    :ok
  end

  defp load_contract(dir, sibling, env) do
    case Contract.load(dir, sibling: sibling) do
      {:ok, contract} ->
        contract

      {:error, errors} ->
        compile_error(
          env.file,
          env.line,
          Exception.message(%Covenant.ContractError{errors: errors})
        )
    end
  end

  # The module's own file is always read, so a module with no test still has its comments checked.
  defp seed_sources(env), do: elem(source_lines(env.file, %{}), 1)

  defp source_lines(nil, sources), do: {[], sources}

  defp source_lines(file, sources) do
    case Map.fetch(sources, file) do
      {:ok, lines} ->
        {lines, sources}

      :error ->
        lines =
          case File.read(file) do
            {:ok, text} -> String.split(text, ["\r\n", "\n"])
            {:error, _} -> []
          end

        {lines, Map.put(sources, file, lines)}
    end
  end

  defp validate_test(%ExUnit.Test{name: name, tags: tags} = test, lines, component, contract) do
    file = tags[:file]
    line = tags[:line]
    # Outside the sibling layout only a comment naming a primitive id is a claim;
    # `# Contract: never negative` is prose.
    commented =
      cond do
        line == nil -> []
        component.form == :primitive -> Primitive.comment_ids(lines, line)
        true -> Primitive.claimed_ids(lines, line)
      end

    ids =
      case {component.form, commented, obligation_ids(tags[:obligation])} do
        {:primitive, [], :missing} ->
          compile_error(
            file,
            line,
            "#{name} names no obligation; put `# Contract: #{component.id}/<id>` on the line above it " <>
              "(or tag it `@tag obligation: \"#{component.id}/<id>\"`)"
          )

        {:primitive, commented, :missing} ->
          commented

        {_, _, :invalid} ->
          compile_error(
            file,
            line,
            "#{name} has an invalid obligation tag #{inspect(tags[:obligation])}; " <>
              "expected a string or a list of strings"
          )

        {:primitive, commented, tagged} ->
          Enum.uniq(commented ++ tagged)

        {_, [_ | _], _} ->
          compile_error(
            file,
            line,
            "#{name} has a `# Contract:` comment, which only Contract tests in the sibling layout's " <>
              "contract/<primitive>/ directories carry; tag it `@tag obligation: ...` instead"
          )

        {_, [], :missing} ->
          compile_error(
            file,
            line,
            "#{name} has no obligation tag; every test in a Covenant.Case module must be " <>
              "tagged `@tag obligation: \"#{component.id}.I<n>\"` (a list is allowed). " <>
              "Tests that do not state an obligation are implementation tests and belong outside test/contract."
          )

        {_, [], tagged} ->
          tagged
      end

    Enum.each(ids, &validate_id(&1, name, file, line, component, contract))
    %{test | tags: Map.put(tags, :obligation, ids)}
  end

  defp validate_id(id, name, file, line, %Component{} = component, contract) do
    case Contract.obligation(contract, id) do
      nil ->
        compile_error(
          file,
          line,
          "#{name} is tagged with unknown obligation `#{id}`; " <>
            "`#{component.id}` declares: #{known(Enum.map(component.obligations, & &1.id))}"
        )

      %Obligation{component_id: other} when other != component.id ->
        compile_error(
          file,
          line,
          "#{name} is tagged with `#{id}`, which belongs to component `#{other}`, " <>
            "but this module tests `#{component.id}`; move the test to that component's contract test file"
        )

      %Obligation{status: :retired} = obligation ->
        compile_error(
          file,
          line,
          "#{name} is tagged with `#{id}`, which is retired (#{obligation.file}:#{obligation.line}); " <>
            "retired obligations keep their number but take no tests — re-tag the test with the obligation that replaced it"
        )

      %Obligation{} ->
        :ok
    end
  end

  defp obligation_ids(nil), do: :missing
  defp obligation_ids(id) when is_binary(id), do: [id]

  defp obligation_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &is_binary/1), do: ids, else: :invalid
  end

  defp obligation_ids(_), do: :invalid

  defp known([]), do: "(none)"
  defp known(ids), do: ids |> Enum.sort() |> Enum.join(", ")

  @spec compile_error(Path.t(), pos_integer() | nil, String.t()) :: no_return()
  defp compile_error(file, line, description) do
    raise CompileError, file: file, line: line, description: description
  end
end
