defmodule Covenant.Contract.ScopeContractTest do
  use Covenant.Case, component: "covenant.contract", async: true

  alias Covenant.ContractBuilder
  alias Covenant.Contract.Ceiling
  alias Covenant.Error
  alias Covenant.Parser.Scope

  @path "system/scope.yml"

  defp messages({:error, errors}), do: Enum.map(errors, &Error.format/1)

  @tag obligation: "covenant.contract.I6"
  test "parses the fixture's ceilings with their counters and lines" do
    path = Path.join(ContractBuilder.fixture_contracts(), "system/scope.yml")
    assert {:ok, [modules, kinds]} = Scope.parse_file(path)

    assert %Ceiling{
             name: "example-modules",
             ceiling: 4,
             counter: {:glob, "lib/**/*.ex"},
             record: "one-example-app",
             line: 2
           } = modules

    assert %Ceiling{
             name: "counter-event-kinds",
             ceiling: 3,
             counter: {:module, Example.Scope, :event_kinds},
             line: 7
           } = kinds

    assert modules.why =~ "small"
  end

  @tag obligation: "covenant.contract.I6"
  test "requires name, a non-negative integer ceiling and a known counter" do
    text = """
    - ceiling: 3
      counter: { kind: glob, pattern: "lib/**" }
    - name: negative
      ceiling: -1
      counter: { kind: glob, pattern: "lib/**" }
    - name: unknown-counter
      ceiling: 1
      counter: { kind: lines }
    """

    assert messages(Scope.parse(text, @path)) == [
             "system/scope.yml:1: ceiling #1 must have a `name`",
             "system/scope.yml:3: ceiling #2 `negative` must have a non-negative integer `ceiling`",
             "system/scope.yml:6: ceiling #3 `unknown-counter` needs a `counter` of kind `glob` (with `pattern`) or `module` (with `module` and `function`)"
           ]
  end

  @tag obligation: "covenant.contract.I6"
  test "an empty file holds no ceilings" do
    assert {:ok, []} = Scope.parse("", @path)
  end

  @tag obligation: "covenant.contract.I6"
  test "rejects a document that is not a list" do
    assert messages(Scope.parse("name: x\n", @path)) == [
             "system/scope.yml:1: scope.yml must be a YAML list of ceilings"
           ]
  end
end
