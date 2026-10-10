defmodule Covenant.RegenContractTest do
  use Covenant.Case, component: "covenant.regen", async: true

  alias Covenant.{Contract, Regen}
  alias Covenant.ContractBuilder

  setup do
    {:ok, contract: Contract.load!(ContractBuilder.fixture_contracts())}
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I1"
  test "writes the full pack for a heavy component", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")

    assert {:ok, %{dir: ^out, files: files}} =
             Regen.write_pack(contract, "example.counter",
               out: out,
               root: ContractBuilder.fixture_project(),
               test_paths: ["test/contract"]
             )

    assert Enum.map(files, &Path.relative_to(&1, out)) == [
             "CONTRACT_CONVENTION.md",
             "PROMPT.md",
             "REGENERATION_BRIEF.md",
             "contracts/example/counter.decisions.yml",
             "contracts/example/counter.intent.md",
             "contracts/system/decisions.yml",
             "contracts/system/intent.md",
             "stubs/lib/example/counter.ex",
             "test/contract/example/counter_contract_test.exs"
           ]

    assert File.read!(Path.join(out, "contracts/example/counter.intent.md")) ==
             File.read!(
               Path.join(ContractBuilder.fixture_contracts(), "example/counter.intent.md")
             )

    assert File.read!(Path.join(out, "REGENERATION_BRIEF.md")) =~
             "Questions\nanswered in earlier rounds"

    refute File.exists?(Path.join(out, "lib/example/counter.ex"))

    prompt = File.read!(Path.join(out, "PROMPT.md"))
    assert prompt =~ "# Regenerate `example.counter`"
    assert prompt =~ "must not look for it"
    assert prompt =~ "- `example.counter.I1` — A counter never goes below zero"
    refute prompt =~ "example.counter.I5"
    assert prompt =~ "`test/contract/example/counter_contract_test.exs`"
    assert prompt =~ "`stubs/lib/example/counter.ex` (`Example.Counter`)"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I2"
  test "stubs compile and raise until implemented", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")

    {:ok, _} =
      Regen.write_pack(contract, "example.counter",
        out: out,
        root: ContractBuilder.fixture_project(),
        test_paths: ["test/contract"]
      )

    source = File.read!(Path.join(out, "stubs/lib/example/counter.ex"))

    assert source =~ "defmodule Example.Counter do"

    assert source =~
             ~s|@doc "new(opts) :: t — a counter at zero; `opts[:max]` sets the cap (default 100, record `configurable-max`)."|

    assert source =~ "def increment(_counter, _by) do"
    assert source =~ "def value(_arg1) do"
    assert source =~ ~s(raise "example.counter: Example.Counter.to_map/1 is not implemented yet")

    renamed =
      String.replace(
        source,
        "defmodule Example.Counter do",
        "defmodule Covenant.RegenTest.Stub do"
      )

    [{module, _}] = Code.compile_string(renamed)
    assert_raise RuntimeError, ~r/not implemented yet/, fn -> module.new([]) end
    assert function_exported?(module, :increment, 2)
    assert function_exported?(module, :to_map, 1)
  end

  @tag obligation: "covenant.regen.I2"
  test "reads signatures in both forms from the public surface", %{contract: contract} do
    sigs = Regen.signatures(Contract.component(contract, "example.counter"))

    assert Enum.map(sigs, &{&1.function, &1.args, &1.return}) == [
             {"new", ["opts"], "t"},
             {"increment", ["counter", "by"], "t"},
             {"decrement", ["counter", "by"], "t"},
             {"value", ["arg1"], nil},
             {"events", ["arg1"], nil},
             {"to_map", ["counter"], "map"}
           ]

    assert Enum.at(sigs, 1).doc == "adds `by`, clamped at `max`."
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I3"
  test "a light component without surface or brief still gets a pack that says so", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "pack")

    assert {:ok, %{files: files}} =
             Regen.write_pack(contract, "example.greeter",
               out: out,
               root: ContractBuilder.fixture_project(),
               test_paths: ["test/contract"]
             )

    relative = Enum.map(files, &Path.relative_to(&1, out))

    assert "contracts/example/greeter.obligations.md" in relative
    assert "test/contract/example/greeter_contract_test.exs" in relative
    refute Enum.any?(relative, &String.starts_with?(&1, "stubs/"))
    refute Enum.any?(relative, &String.contains?(&1, "greeter.decisions"))

    assert File.read!(Path.join(out, "REGENERATION_BRIEF.md")) =~
             "has no `## Regeneration brief` section"

    prompt = File.read!(Path.join(out, "PROMPT.md"))
    assert prompt =~ "lists no `Module.function/arity` signatures"
    assert prompt =~ "the component's obligations file"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I3"
  test "a component without tests says so in the prompt", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")

    {:ok, _} =
      Regen.write_pack(contract, "example.greeter",
        out: out,
        root: dir,
        test_paths: ["test/contract"]
      )

    assert File.read!(Path.join(out, "PROMPT.md")) =~
             ~s(no contract test file declares `use Covenant.Case, component: "example.greeter"`)
  end

  @tag obligation: "covenant.regen.I4"
  test "an unknown component is an error listing the known ones", %{contract: contract} do
    assert {:error, message} =
             Regen.write_pack(contract, "example.nope", out: "/nonexistent/never-written")

    assert message ==
             "unknown component `example.nope`; known: example.counter, example.greeter, system"
  end

  @tag obligation: "covenant.regen.I4"
  test "find_tests matches on the component declaration, through globs" do
    root = ContractBuilder.fixture_project()

    assert Regen.find_tests("example.counter", ["test/contract"], root) == [
             "test/contract/example/counter_contract_test.exs"
           ]

    assert Regen.find_tests("example.counter", ["test/*"], root) == [
             "test/contract/example/counter_contract_test.exs"
           ]

    assert Regen.find_tests("example.nope", ["test/contract"], root) == []
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "rewrites an existing pack directory from scratch", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")
    File.mkdir_p!(out)
    File.write!(Path.join(out, "stale.txt"), "old")
    {:ok, _} = Regen.write_pack(contract, "example.greeter", out: out, root: dir, test_paths: [])
    refute File.exists?(Path.join(out, "stale.txt"))
  end
end
