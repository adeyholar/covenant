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
             counter: {:module, "Example.Scope", "event_kinds"},
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

  @ceiling """
  - name: modules
    ceiling: 4
    counter: { kind: glob, pattern: "lib/**" }
  """

  @tag obligation: "covenant.contract.I11"
  test "a second YAML document is an error, not silently dropped" do
    assert messages(Scope.parse(@ceiling <> "---\n[]\n", @path)) == [
             "system/scope.yml:5: more than one YAML document in the file"
           ]
  end

  @tag obligation: "covenant.contract.I11"
  test "a merge key is an error, not silently ignored" do
    assert messages(Scope.parse(@ceiling <> "  <<: { ceiling: 1 }\n", @path)) == [
             "system/scope.yml:4: merge keys (`<<`) are not supported"
           ]
  end

  @tag obligation: "covenant.contract.I11"
  test "a repeated mapping key is an error, not silently resolved" do
    assert messages(Scope.parse(@ceiling <> "  ceiling: 1\n", @path)) == [
             "system/scope.yml:4: key `ceiling` is repeated (first at line 2)"
           ]
  end

  @tag obligation: "covenant.contract.I11"
  test "fields of the wrong type are errors, not crashes" do
    text = """
    - name: { bad: data }
      ceiling: 1
      counter: { kind: glob, pattern: "lib/**" }
    - name: typed
      ceiling: 1
      why: [a]
      record: { b: c }
      counter: { kind: glob, pattern: "lib/**" }
    - name: other
      ceiling: 1
      counter: { kind: module, module: [a], function: b }
    """

    assert messages(Scope.parse(text, @path)) == [
             "system/scope.yml:1: ceiling #1 must have a `name`",
             "system/scope.yml:4: ceiling #2 `typed` `why` must be text",
             "system/scope.yml:9: ceiling #3 `other` needs a `counter` of kind `glob` (with `pattern`) or `module` (with `module` and `function`)"
           ]
  end
end
