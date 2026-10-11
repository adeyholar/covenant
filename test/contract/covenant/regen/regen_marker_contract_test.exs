defmodule Covenant.RegenMarkerContractTest do
  use Covenant.Case, component: "covenant.regen", async: true

  alias Covenant.{Contract, ContractBuilder, Regen}

  setup do
    {:ok, contract: Contract.load!(ContractBuilder.fixture_contracts())}
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "an empty or blank marker is not a pack: refused, nothing deleted", %{
    contract: contract,
    tmp_dir: dir
  } do
    for {content, n} <- Enum.with_index(["", "\n\n"]) do
      out = Path.join(dir, "pack#{n}")
      File.mkdir_p!(out)
      File.write!(Path.join(out, ".covenant-pack"), content)
      File.write!(Path.join(out, "keep.md"), "mine")

      assert {:error, message} =
               Regen.write_pack(contract, "example.counter",
                 out: out,
                 root: ContractBuilder.fixture_project(),
                 test_paths: ["test/contract"]
               )

      assert message =~ "not a pack Covenant wrote"
      assert File.read!(Path.join(out, "keep.md")) == "mine"
    end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "a contract test outside the root is recorded relative to the pack, and a re-run succeeds",
       %{contract: contract, tmp_dir: dir} do
    root = Path.join(dir, "root")
    File.mkdir_p!(root)
    out = Path.join(dir, "pack")
    outside = Path.join(ContractBuilder.fixture_project(), "test/contract")

    run = fn ->
      Regen.write_pack(contract, "example.counter", out: out, root: root, test_paths: [outside])
    end

    assert {:ok, %{files: files}} = run.()

    manifest =
      out |> Path.join(".covenant-pack") |> File.read!() |> String.split("\n", trim: true)

    refute Enum.any?(tl(manifest), &(Path.type(&1) == :absolute))
    assert Enum.any?(tl(manifest), &String.ends_with?(&1, "_test.exs"))
    assert Enum.all?(files, &String.starts_with?(&1, out <> "/"))
    assert {:ok, %{files: ^files}} = run.()
  end
end
