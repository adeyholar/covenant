defmodule Covenant.CoverageContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  alias Covenant.{Contract, Coverage}
  alias Covenant.{ContractBuilder, ResultsBuilder}

  setup do
    {:ok, contract: Contract.load!(ContractBuilder.fixture_contracts())}
  end

  @tag obligation: "covenant.check.I7"
  test "counts covered obligations per component, per app and overall", %{contract: contract} do
    results =
      ResultsBuilder.results([
        "example.counter.I1",
        "example.counter.I1",
        {"example.counter.I2", :failed},
        "example.greeter.I1"
      ])

    coverage = Coverage.compute(contract, results)

    assert coverage.totals == %{active: 5, covered: 2, ratio: 0.4}

    assert coverage.apps == %{
             "example" => %{active: 5, covered: 2, ratio: 0.4},
             "system" => %{active: 0, covered: 0, ratio: nil}
           }

    counter = coverage.components["example.counter"]
    assert %{form: :heavy, app: "example", active: 4, covered: 1, ratio: 0.25} = counter
    assert counter.obligations["example.counter.I1"].passing == 2

    assert counter.obligations["example.counter.I2"] |> Map.take([:passing, :failing]) == %{
             passing: 0,
             failing: 1
           }

    assert counter.obligations["example.counter.I5"] |> Map.take([:status, :testable]) == %{
             status: :retired,
             testable: false
           }

    greeter = coverage.components["example.greeter"]
    assert %{form: :light, active: 1, covered: 1, ratio: 1.0} = greeter

    assert greeter.obligations["example.greeter.I2"] |> Map.take([:kind, :testable]) == %{
             kind: :exception,
             testable: false
           }
  end

  @tag obligation: "covenant.check.I8"
  test "to_map is JSON-ready with string keys and a version", %{contract: contract} do
    map =
      Coverage.compute(contract, ResultsBuilder.results(["example.counter.I1"]))
      |> Coverage.to_map()

    assert map["covenant"] == Covenant.version()
    assert map["totals"] == %{"active" => 5, "covered" => 1, "coverage" => 0.2}

    assert map["components"]["example.counter"]["obligations"]["example.counter.I1"]["tests"] == [
             "test example.counter.I1 #1"
           ]

    assert map["components"]["example.greeter"]["form"] == "light"
    assert is_binary(JSON.encode!(map))
  end

  @tag obligation: "covenant.check.I7"
  test "format renders a table with percentages and n/a for empty components", %{
    contract: contract
  } do
    table =
      Coverage.compute(
        contract,
        ResultsBuilder.results(["example.counter.I1", "example.greeter.I1"])
      )
      |> Coverage.format()

    assert table =~ ~r/example\.counter\s+1\/4\s+25\.0%/
    assert table =~ ~r/example\.greeter\s+1\/1\s+100\.0%/
    assert table =~ ~r/system\s+0\/0\s+n\/a/
    assert table =~ ~r/app example\s+2\/5\s+40\.0%/
    assert table =~ ~r/total\s+2\/5\s+40\.0%/
  end
end
