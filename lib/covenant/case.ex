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

  ## Options

  * `:component` (required) — the component id, e.g. `"example.counter"`.
  * `:contracts` — the contracts directory; defaults to
    `Covenant.contracts_dir/0` (`config :covenant, contracts_dir: ...`).
  * every other option is passed to `ExUnit.Case` (`:async`, `:register`, ...).

  The module also receives `@moduletag :contract` and
  `@moduletag covenant_component: component`, so `mix test --only contract`
  selects contract tests and `Covenant.Formatter` can credit them.
  """

  alias Covenant.Contract
  alias Covenant.Contract.Obligation

  defmacro __using__(opts) do
    {component, opts} = Keyword.pop(opts, :component)
    {contracts, opts} = Keyword.pop(opts, :contracts)

    if not is_binary(component) do
      raise ArgumentError,
            "use Covenant.Case requires component: \"<app>.<component>\", got: #{inspect(component)}"
    end

    quote do
      use ExUnit.Case, unquote(opts)

      @covenant_component unquote(component)
      @covenant_contracts unquote(contracts)
      @moduletag :contract
      @moduletag covenant_component: unquote(component)
      @before_compile Covenant.Case
    end
  end

  defmacro __before_compile__(env) do
    Covenant.Case.__validate__(env)
    nil
  end

  @doc false
  @spec __validate__(Macro.Env.t()) :: :ok
  def __validate__(env) do
    component_id = Module.get_attribute(env.module, :covenant_component)
    dir = Module.get_attribute(env.module, :covenant_contracts) || Covenant.contracts_dir()
    contract = load_contract(dir, env)

    component =
      Contract.component(contract, component_id) ||
        compile_error(
          env.file,
          env.line,
          "unknown component `#{component_id}` (not in #{dir}); known components: " <>
            known(Contract.component_ids(contract))
        )

    env.module
    |> Module.get_attribute(:ex_unit_tests)
    |> Enum.reverse()
    |> Enum.each(&validate_test(&1, component, contract))

    :ok
  end

  defp load_contract(dir, env) do
    case Contract.load(dir) do
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

  defp validate_test(%ExUnit.Test{name: name, tags: tags}, component, contract) do
    file = tags[:file]
    line = tags[:line]

    case obligation_ids(tags[:obligation]) do
      :missing ->
        compile_error(
          file,
          line,
          "#{name} has no obligation tag; every test in a Covenant.Case module must be " <>
            "tagged `@tag obligation: \"#{component.id}.I<n>\"` (a list is allowed). " <>
            "Tests that do not state an obligation are implementation tests and belong outside test/contract."
        )

      :invalid ->
        compile_error(
          file,
          line,
          "#{name} has an invalid obligation tag #{inspect(tags[:obligation])}; " <>
            "expected a string or a list of strings"
        )

      ids ->
        Enum.each(ids, &validate_id(&1, name, file, line, component, contract))
    end
  end

  defp validate_id(id, name, file, line, component, contract) do
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
