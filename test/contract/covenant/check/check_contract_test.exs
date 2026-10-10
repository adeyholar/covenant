defmodule Covenant.CheckContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  alias Covenant.{Check, Contract, Error, Results}
  alias Covenant.{ContractBuilder, ResultsBuilder}

  @all ["demo.widget.I1", "demo.gadget.I1"]

  defp messages(report), do: Enum.map(report.problems, &Error.format/1)

  defp short(report),
    do: report |> messages() |> Enum.map(&String.replace(&1, ~r/^.*?\/(demo|system)\//, "\\1/"))

  setup %{tmp_dir: dir} do
    {:ok, contract: Contract.load!(ContractBuilder.demo_contracts(dir)), dir: dir}
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I9"
  test "a fully tested Contract holds", %{contract: contract, dir: dir} do
    report = Check.run(contract, ResultsBuilder.results(@all), root: dir)
    assert Check.Report.ok?(report)
    assert report.coverage.totals == %{active: 2, covered: 2, ratio: 1.0}
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I1"
  test "an active obligation without a tagged test fails; retired and exception blocks need none",
       %{contract: contract, dir: dir} do
    report = Check.run(contract, ResultsBuilder.results(["demo.gadget.I1"]), root: dir)

    assert short(report) == [
             "demo/widget.intent.md:26: active obligation `demo.widget.I1` has no tagged test; add `@tag obligation: \"demo.widget.I1\"` to the contract test that proves it"
           ]

    assert report.coverage.totals == %{active: 2, covered: 1, ratio: 0.5}
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I2"
  test "a tag naming an unknown obligation fails at the test", %{contract: contract, dir: dir} do
    report = Check.run(contract, ResultsBuilder.results(@all ++ ["demo.widget.I9"]), root: dir)

    assert short(report) == [
             "test/contract/demo_contract_test.exs:3: test demo.widget.I9 #3 is tagged with unknown obligation `demo.widget.I9`"
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I3"
  test "a failing or invalid tagged test fails; the obligation is not covered", %{
    contract: contract,
    dir: dir
  } do
    report =
      Check.run(
        contract,
        ResultsBuilder.results([{"demo.widget.I1", :failed}, {"demo.gadget.I1", :invalid}]),
        root: dir
      )

    assert short(report) == [
             "test/contract/demo_contract_test.exs:1: test demo.widget.I1 #1 (obligation `demo.widget.I1`) failed",
             "test/contract/demo_contract_test.exs:2: test demo.gadget.I1 #2 (obligation `demo.gadget.I1`) invalid"
           ]

    assert report.coverage.totals.covered == 0
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I3"
  test "skipped and excluded tests count as tagged but not as coverage", %{
    contract: contract,
    dir: dir
  } do
    report =
      Check.run(
        contract,
        ResultsBuilder.results([{"demo.widget.I1", :skipped}, {"demo.gadget.I1", :excluded}]),
        root: dir
      )

    assert Check.Report.ok?(report)
    assert report.coverage.totals.covered == 0
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I4"
  test "a stale exception fails: missing function, missing module, missing file", %{dir: dir} do
    for {target, expected} <- [
          {"Covenant.Error.nope/3", "Covenant.Error.nope/3"},
          {"Covenant.Nope.Missing", "Covenant.Nope.Missing"},
          {"lib/nope.ex", "lib/nope.ex"}
        ] do
      ContractBuilder.write(dir, %{
        "demo/gadget.obligations.md" => ContractBuilder.light_obligations(target)
      })

      report = Check.run(Contract.load!(dir), ResultsBuilder.results(@all), root: dir)
      assert [message] = short(report)

      assert message =~
               "demo/gadget.obligations.md:13: exception `demo.gadget.I2` targets #{expected}, which no longer exists"
    end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I4"
  test "exception targets that exist pass: a function, a module, a file", %{dir: dir} do
    ContractBuilder.write(dir, %{"lib/present.ex" => ""})

    for target <- ["Covenant.Error.format/1", "Covenant.Error", "lib/present.ex"] do
      ContractBuilder.write(dir, %{
        "demo/gadget.obligations.md" => ContractBuilder.light_obligations(target)
      })

      assert Check.Report.ok?(
               Check.run(Contract.load!(dir), ResultsBuilder.results(@all), root: dir)
             )
    end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I4"
  test "an unreadable exception target is reported", %{dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/gadget.obligations.md" => ContractBuilder.light_obligations("what is this")
    })

    report = Check.run(Contract.load!(dir), ResultsBuilder.results(@all), root: dir)
    assert [message] = short(report)
    assert message =~ "exception `demo.gadget.I2`: cannot read target `what is this`"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I4"
  test "a retired exception is not checked", %{dir: dir} do
    text =
      ContractBuilder.light_obligations("Covenant.Nope.Missing")
      |> String.replace(
        "- **target:** `Covenant.Nope.Missing`\n- **status:** active",
        "- **target:** `Covenant.Nope.Missing`\n- **status:** retired"
      )

    ContractBuilder.write(dir, %{"demo/gadget.obligations.md" => text})

    assert Check.Report.ok?(
             Check.run(Contract.load!(dir), ResultsBuilder.results(@all), root: dir)
           )
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I5"
  test "a scope ceiling exceeded fails, one at the limit passes, an uncountable one fails", %{
    dir: dir
  } do
    ContractBuilder.write(dir, %{
      "lib/a.ex" => "",
      "lib/b.ex" => "",
      "system/scope.yml" => """
      - name: files
        ceiling: 1
        counter: { kind: glob, pattern: "lib/**/*.ex" }
      - name: files-ok
        ceiling: 2
        counter: { kind: glob, pattern: "lib/**/*.ex" }
      - name: kinds
        ceiling: 3
        counter: { kind: module, module: Example.Scope, function: event_kinds }
      - name: broken
        ceiling: 3
        counter: { kind: module, module: Example.Scope, function: nope }
      """
    })

    report = Check.run(Contract.load!(dir), ResultsBuilder.results(@all), root: dir)

    assert short(report) == [
             "system/scope.yml:1: scope ceiling `files` exceeded: 2 > 1 (glob lib/**/*.ex)",
             "system/scope.yml:10: scope ceiling `broken` cannot be counted: counter Example.Scope.nope/0 is not exported"
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I6"
  test "dangling references are part of the report", %{dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/widget.intent.md" =>
        String.replace(
          ContractBuilder.heavy_intent(),
          "- **record:** keep-size",
          "- **record:** gone"
        )
    })

    report = Check.run(Contract.load!(dir), ResultsBuilder.results(@all), root: dir)
    assert [message] = short(report)
    assert message =~ "cites record `gone`, which does not exist"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.check.I6"
  test "problems are sorted by file and line", %{dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/widget.intent.md" =>
        String.replace(
          ContractBuilder.heavy_intent(),
          "- **record:** keep-size",
          "- **record:** gone"
        )
    })

    report = Check.run(Contract.load!(dir), %Results{}, root: dir)
    assert report.problems == Error.sort(report.problems)
    assert length(report.problems) == 3
  end
end
