defmodule Covenant.CheckStaticRootContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  alias Covenant.{Check, Contract, Results}

  @tag :tmp_dir
  @tag obligation: "covenant.check.I1"
  test "a static run resolves a sibling test's path against the root, not the working directory",
       %{tmp_dir: dir} do
    dir = Path.expand(dir)
    sibling = Path.join(dir, "contract")
    File.mkdir_p!(Path.join(sibling, "calc"))

    File.write!(
      Path.join(sibling, "calc/README.md"),
      "# calc\n\n## Obligations\n\n- **A1** Adds.\n"
    )

    contract = Contract.load!(Path.join(dir, "contracts"), sibling: sibling)

    test = %Results.Test{
      module: "Calc.ContractTest",
      name: "test add",
      file: "contract/calc/calc_test.exs",
      line: 3,
      component: "calc",
      obligations: ["calc/A1"],
      state: :passed
    }

    results = %Results{apps: ["static"], tests: [test]}
    refute File.cwd!() == dir

    report = Check.run(contract, results, mode: :static, root: dir, sibling: sibling)
    refute Enum.any?(report.problems, &(&1.message =~ "outside the sibling layout"))
  end
end
