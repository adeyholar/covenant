defmodule Covenant.Contract.RecordsContractTest do
  use Covenant.Case, component: "covenant.contract", async: true

  alias Covenant.ContractBuilder
  alias Covenant.Contract.{Condition, Record}
  alias Covenant.Error
  alias Covenant.Parser.Records

  @path "demo/widget.decisions.yml"

  defp parse(text), do: Records.parse(text, @path, "demo.widget")
  defp messages({:error, errors}), do: Enum.map(errors, &Error.format/1)

  @tag obligation: "covenant.contract.I5"
  test "parses the fixture's counter records with line provenance" do
    path = Path.join(ContractBuilder.fixture_contracts(), "example/counter.decisions.yml")
    assert {:ok, records} = Records.parse_file(path, "example.counter")

    assert Enum.map(records, & &1.id) == [
             "clamp-at-zero",
             "positive-steps",
             "fixed-max-100",
             "configurable-max"
           ]

    assert Enum.map(records, & &1.line) == [1, 20, 36, 46]

    [clamp, _, fixed, configurable] = records

    assert %Record{
             component_id: "example.counter",
             date: "2026-10-09",
             invariant: ["example.counter.I1"]
           } = clamp

    assert [%{option: "Raise ArgumentError on underflow", rejected: rejected} | _] =
             clamp.alternatives

    assert rejected =~ "rescue"

    assert [
             %Condition{
               text: "Elixir is at least 1.18",
               check: %{"kind" => "elixir", "version" => ">= 1.18.0"}
             },
             %Condition{check: nil}
           ] = clamp.conditions

    assert clamp.source == ["test/fixtures/example_project"]
    assert fixed.superseded_by == "configurable-max"
    assert fixed.kind == "fact"
    assert Record.superseded?(fixed)
    assert configurable.depends_on == ["fixed-max-100"]
    refute Record.superseded?(configurable)
  end

  @tag obligation: "covenant.contract.I5"
  test "parses a minimal record and wraps scalar invariant and source" do
    assert {:ok, [record]} = parse(ContractBuilder.widget_records())
    assert record.id == "keep-size"
    assert record.invariant == ["demo.widget.I1"]
    assert record.source == []
    assert record.alternatives == []
    assert record.approved_by == "lead"
  end

  @tag obligation: "covenant.contract.I5"
  test "reports each missing required key at the record's item line" do
    text = """
    - id: keep-size
      date: "2026-10-09"
      decision: The size is stored.
      driver: v1 lost it.
      approved_by: lead

    - id: second
      decision: Something.
    """

    assert messages(parse(text)) == [
             "demo/widget.decisions.yml:7: record `second` is missing `date`",
             "demo/widget.decisions.yml:7: record `second` is missing `driver`",
             "demo/widget.decisions.yml:7: record `second` is missing `approved_by`"
           ]
  end

  @tag obligation: "covenant.contract.I5"
  test "labels a record without an id by its position" do
    text = """
    - date: "2026-10-09"
      decision: Something.
      driver: Someone.
      approved_by: lead
    """

    assert messages(parse(text)) == ["demo/widget.decisions.yml:1: record #1 is missing `id`"]
  end

  @tag obligation: "covenant.contract.I5"
  test "rejects a non kebab-case id and a malformed date" do
    text = """
    - id: Keep_Size
      date: 2026/10/09
      decision: d
      driver: d
      approved_by: lead
    """

    assert messages(parse(text)) == [
             "demo/widget.decisions.yml:1: record `Keep_Size` id must be kebab-case (got `Keep_Size`)",
             "demo/widget.decisions.yml:1: record `Keep_Size` date must be `YYYY-MM-DD` (got `2026/10/09`)"
           ]
  end

  @tag obligation: "covenant.contract.I5"
  test "rejects an unknown kind, a non-list alternatives and a check without a kind" do
    text = """
    - id: keep-size
      date: "2026-10-09"
      decision: d
      driver: d
      approved_by: lead
      kind: whim
      alternatives: none
      conditions:
        - text: fine
          check: { name: postgrex }
    """

    assert messages(parse(text)) == [
             "demo/widget.decisions.yml:1: record `keep-size` has unknown `kind` \"whim\" (expected one of: fact, cross-system, known-gap)",
             "demo/widget.decisions.yml:1: record `keep-size` `alternatives` must be a list",
             "demo/widget.decisions.yml:1: record `keep-size` condition #1 `check` must be a mapping with a `kind`"
           ]
  end

  @tag obligation: "covenant.contract.I5"
  test "accepts plain-string conditions" do
    text = ContractBuilder.widget_records() <> "    - Plain premise\n"
    assert {:ok, [record]} = parse(text)

    assert [
             %Condition{check: %{"kind" => "elixir"}},
             %Condition{text: "Plain premise", check: nil}
           ] = record.conditions
  end

  @tag obligation: "covenant.contract.I4"
  test "rejects duplicate ids, pointing at the second" do
    text = ContractBuilder.widget_records() <> ContractBuilder.widget_records()

    assert messages(parse(text)) == [
             "demo/widget.decisions.yml:10: record `keep-size` is declared twice (first at line 1)"
           ]
  end

  @tag obligation: "covenant.contract.I5"
  test "rejects a document that is not a list" do
    assert messages(parse("id: keep-size\n")) == [
             "demo/widget.decisions.yml:1: decision records must be a YAML list of records"
           ]
  end

  @tag obligation: "covenant.contract.I5"
  test "reports invalid YAML with its line" do
    assert [message] = messages(parse("- id: a\n  date: \"2026-10-09\n  decision: x\n"))
    assert message =~ ~r/^demo\/widget.decisions.yml:\d+: invalid YAML: /
  end

  @tag obligation: "covenant.contract.I5"
  test "an empty file holds no records" do
    assert {:ok, []} = parse("")
  end

  @tag obligation: "covenant.contract.I7"
  test "parse_file reports an unreadable file" do
    assert {:error, [%Error{line: nil, message: message}]} =
             Records.parse_file("nope.yml", "demo.widget")

    assert message =~ "cannot read file"
  end
end
