defmodule Covenant.RegenSiblingDirContractTest do
  use Covenant.Case, component: "covenant.regen", async: true

  alias Covenant.{Contract, ContractBuilder, Regen}

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I1"
  test "a custom sibling_dir's helper goes in the pack and the prompt", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "contracts/README.md" => "# convention\n",
      "specs/test_helper.exs" => "ExUnit.start()\n",
      "specs/calc/README.md" => "# calc\n\n- **A1** Adds.\n\n```covers\nCalcNotLoaded\n```\n",
      "specs/calc/calc_test.exs" => "defmodule CalcTest do\n  use Covenant.Case\nend\n"
    })

    contract = Contract.load!(Path.join(dir, "contracts"), sibling: Path.join(dir, "specs"))
    out = Path.join(dir, "pack")

    assert {:ok, %{files: files}} =
             Regen.write_pack(contract, "calc", out: out, root: dir, test_paths: [])

    relative = Enum.map(files, &Path.relative_to(&1, out))
    assert "specs/test_helper.exs" in relative
    refute "contract/test_helper.exs" in relative
    prompt = File.read!(Path.join(out, "PROMPT.md"))
    assert prompt =~ "`specs/test_helper.exs`"
    refute prompt =~ "contract/test_helper.exs"
  end
end
