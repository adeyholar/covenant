defmodule Covenant.RegenPackContractTest do
  use Covenant.Case, component: "covenant.regen", async: true

  alias Covenant.{Contract, ContractBuilder, Regen}
  alias Covenant.Regen.Ownership

  setup do
    {:ok, contract: Contract.load!(ContractBuilder.fixture_contracts())}
  end

  defp pack(contract, out, root \\ ContractBuilder.fixture_project()) do
    Regen.write_pack(contract, "example.counter",
      out: out,
      root: root,
      test_paths: ["test/contract"]
    )
  end

  # -- I4: re-running keeps what the agent wrote --------------------------------

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "a re-run refuses a pack directory that holds the agent's files and deletes nothing", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "pack")
    assert {:ok, _} = pack(contract, out)
    File.write!(Path.join(out, "QUESTIONS.md"), "1. why?")
    File.mkdir_p!(Path.join(out, "lib/example"))
    File.write!(Path.join(out, "lib/example/counter.ex"), "defmodule X, do: nil")

    assert {:error, message} = pack(contract, out)
    assert message =~ "QUESTIONS.md"
    assert message =~ "lib/example/counter.ex"
    assert message =~ "didn't write"
    assert message =~ "--out"

    assert File.read!(Path.join(out, "QUESTIONS.md")) == "1. why?"
    assert File.exists?(Path.join(out, "lib/example/counter.ex"))
    assert File.exists?(Path.join(out, "PROMPT.md"))
    assert File.exists?(Path.join(out, ".covenant-pack"))
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "a re-run clears exactly the files the marker lists and prunes the emptied directories", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "pack")
    assert {:ok, %{files: files}} = pack(contract, out)

    manifest =
      out |> Path.join(".covenant-pack") |> File.read!() |> String.split("\n", trim: true)

    assert hd(manifest) == "example.counter"
    assert tl(manifest) == files |> Enum.map(&Path.relative_to(&1, out)) |> Enum.sort()

    File.write!(Path.join(out, "PROMPT.md"), "edited")
    assert {:ok, %{files: again}} = pack(contract, out)
    assert again == files
    assert File.read!(Path.join(out, "PROMPT.md")) =~ "# Regenerate"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "a marker listing paths outside the pack never deletes them", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "pack")
    assert {:ok, _} = pack(contract, out)
    outside = Path.join(dir, "outside.txt")
    File.write!(outside, "keep me")
    marker = Path.join(out, ".covenant-pack")
    File.write!(marker, File.read!(marker) <> "../outside.txt\n#{outside}\n")

    assert {:ok, _} = pack(contract, out)
    assert File.read!(outside) == "keep me"
  end

  # -- I1/I2: pack contents and stubs -------------------------------------------

  defp sibling_project(dir, extra) do
    ContractBuilder.write(
      dir,
      Map.merge(
        %{
          "contracts/README.md" => "# convention\n",
          "contract/test_helper.exs" => "ExUnit.start()\n",
          "contract/calc/README.md" =>
            "# calc\n\n- **A1** Adds.\n\n```covers\nCalcNotLoaded\n```\n",
          "contract/calc/mutants.md" => "# survivors\n\nCalcNotLoaded.add/2: + -> -\n",
          "contract/calc/calc_test.exs" => "defmodule CalcTest do\n  use Covenant.Case\nend\n",
          "contract/calc/deep/more_test.exs" =>
            "defmodule CalcMoreTest do\n  use Covenant.Case\nend\n"
        },
        extra
      )
    )

    Contract.load!(Path.join(dir, "contracts"), sibling: Path.join(dir, "contract"))
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I1"
  test "a primitive's pack has its subdirectory tests, convention and helper, and no mutants.md",
       %{tmp_dir: dir} do
    contract = sibling_project(dir, %{})
    out = Path.join(dir, "pack")

    assert {:ok, %{files: files}} =
             Regen.write_pack(contract, "calc", out: out, root: dir, test_paths: [])

    relative = Enum.map(files, &Path.relative_to(&1, out))

    for file <-
          ~w(CONTRACT_CONVENTION.md PROMPT.md contract/calc/README.md contract/calc/calc_test.exs
             contract/calc/deep/more_test.exs contract/test_helper.exs) do
      assert file in relative, "#{file} is missing from the pack"
    end

    refute Enum.any?(relative, &(&1 =~ "mutants"))

    prompt = File.read!(Path.join(out, "PROMPT.md"))
    refute prompt =~ "mutants.md"
    assert prompt =~ "`CONTRACT_CONVENTION.md`"
    assert prompt =~ "`contract/test_helper.exs`"
    assert prompt =~ "`contract/calc/deep/more_test.exs`"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I1"
  test "a primitive whose covered code is not loadable says its signatures are unavailable", %{
    tmp_dir: dir
  } do
    contract = sibling_project(dir, %{})
    component = Contract.component(contract, "calc")

    prompt = Regen.prompt(component, [], layout: dir, contract: contract)
    assert prompt =~ "signatures are unavailable"
    assert prompt =~ "CalcNotLoaded"
    refute prompt =~ "lists no `Module.function/arity`"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I1"
  test "the prompt does not claim there are no signatures when they were all skipped", %{
    tmp_dir: dir
  } do
    surface = "- `Covenant.Error.new/3` — an error."

    contract =
      Contract.load!(
        ContractBuilder.demo_contracts(dir, surface, "---\nmodules: [Demo.Other]\n---\n")
      )

    component = Contract.component(contract, "demo.widget")
    environment = Ownership.environment(%{app: :covenant, build_path: Mix.Project.build_path()})

    assert [] = Regen.stubs(component, environment: environment)
    prompt = Regen.prompt(component, [], environment: environment)
    assert prompt =~ "does not own"
    assert prompt =~ "Covenant.Error"
    assert prompt =~ "Demo.Widget"
    refute prompt =~ "lists no `Module.function/arity`"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I2"
  test "default arguments render as one head with the defaults and the stub compiles", %{
    tmp_dir: dir
  } do
    surface =
      Enum.join(
        [
          "- `Demo.Widget.fetch(id, opts \\\\ [a: 1, b: 2], limit \\\\ 10)` — fetches.",
          "- `Demo.Widget.fetch/1` — one argument.",
          "- `Demo.Widget.fetch/2` — two arguments.",
          "- `Demo.Widget.size/1` — its size."
        ],
        "\n"
      )

    contract = Contract.load!(ContractBuilder.demo_contracts(dir, surface, ""))
    component = Contract.component(contract, "demo.widget")

    {"Demo.Widget", source} = List.keyfind(Regen.stubs(component), "Demo.Widget", 0)
    assert source =~ "def fetch(_id, _opts \\\\ [a: 1, b: 2], _limit \\\\ 10) do"
    assert length(String.split(source, "def fetch(")) == 2
    assert source =~ "def size(_arg1) do"

    renamed =
      String.replace(
        source,
        "defmodule Demo.Widget do",
        "defmodule Covenant.RegenDefaultsStub do"
      )

    assert [{module, _}] = Code.compile_string(renamed)
    assert_raise RuntimeError, ~r/not implemented yet/, fn -> module.fetch(1) end
  end

  # -- I8: no atoms from the Contract -------------------------------------------

  @tag obligation: "covenant.regen.I8"
  test "names in the Contract never become atoms" do
    name = "Zzcontract#{System.unique_integer([:positive])}.NoSuchModule"
    env = Ownership.environment(%{app: :shop, deps: [], build_path: "/nowhere"})

    assert Ownership.classify(name, env) == :own
    assert Ownership.module_atom(name) == nil
    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    assert Ownership.module_atom("Covenant.Error") == Covenant.Error
  end
end
