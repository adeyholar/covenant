defmodule Covenant.Contract.ValidateContractTest do
  use Covenant.Case, component: "covenant.contract", async: true

  alias Covenant.Contract
  alias Covenant.Contract.Validate
  alias Covenant.ContractBuilder
  alias Covenant.Error

  defp load!(dir), do: Contract.load!(dir)
  defp messages(errors), do: Enum.map(errors, &Error.format/1)

  @tag obligation: "covenant.contract.I9"
  test "the fixture Contract has no dangling references" do
    assert Validate.dangling(load!(ContractBuilder.fixture_contracts())) == []
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I9"
  test "the demo Contract has no dangling references", %{tmp_dir: dir} do
    assert Validate.dangling(load!(ContractBuilder.demo_contracts(dir))) == []
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I9"
  test "an obligation citing a missing record", %{tmp_dir: dir} do
    ContractBuilder.demo_contracts(dir)

    ContractBuilder.write(dir, %{
      "demo/widget.intent.md" =>
        String.replace(
          ContractBuilder.heavy_intent(),
          "- **record:** keep-size",
          "- **record:** keep-sizes"
        )
    })

    assert [message] = messages(Validate.dangling(load!(dir)))

    assert message =~
             ~r/widget.intent.md:26: obligation `demo.widget.I1` cites record `keep-sizes`, which does not exist/
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I9"
  test "a record protecting a missing invariant, superseded by or depending on a missing record",
       %{tmp_dir: dir} do
    ContractBuilder.demo_contracts(dir)

    ContractBuilder.write(dir, %{
      "demo/widget.decisions.yml" =>
        ContractBuilder.widget_records() <>
          """
          - id: later
            date: "2026-10-09"
            decision: d
            driver: d
            approved_by: lead
            invariant: [demo.widget.I1, demo.widget.I7]
            superseded_by: newest
            depends_on: [keep-size, gone]
          """
    })

    assert messages(Validate.dangling(load!(dir)))
           |> Enum.map(&String.replace(&1, ~r/^.*decisions.yml:/, "")) == [
             "10: record `later` protects invariant `demo.widget.I7`, which does not exist",
             "10: record `later` is superseded by `newest`, which does not exist",
             "10: record `later` depends on `gone`, which does not exist"
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I9"
  test "a ceiling citing a missing record", %{tmp_dir: dir} do
    ContractBuilder.demo_contracts(dir)

    ContractBuilder.write(dir, %{
      "system/scope.yml" =>
        "- name: files\n  ceiling: 10\n  counter: { kind: glob, pattern: \"lib/**\" }\n  record: nope\n"
    })

    assert [message] = messages(Validate.dangling(load!(dir)))
    assert message =~ "scope.yml:1: ceiling `files` cites record `nope`, which does not exist"
  end
end
