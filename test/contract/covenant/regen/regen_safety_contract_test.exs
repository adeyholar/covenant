defmodule Covenant.RegenSafetyContractTest do
  use Covenant.Case,
    component: "covenant.regen",
    async: true

  alias Covenant.{Contract, ContractBuilder, Regen}

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

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "refuses a non-empty directory without the marker and deletes nothing", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "lib")
    File.mkdir_p!(Path.join(out, "nested"))
    File.write!(Path.join(out, "impl.ex"), "defmodule Impl, do: nil")
    File.write!(Path.join([out, "nested", "deep.ex"]), "x")

    assert {:error, message} = pack(contract, out)
    assert message =~ "refusing to write the pack to #{out}"
    assert message =~ ".covenant-pack"

    assert File.read!(Path.join(out, "impl.ex")) == "defmodule Impl, do: nil"
    assert File.read!(Path.join([out, "nested", "deep.ex"])) == "x"
    refute File.exists?(Path.join(out, ".covenant-pack"))
    refute File.exists?(Path.join(out, "PROMPT.md"))
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "a missing or empty directory is written, and the pack carries the marker", %{
    contract: contract,
    tmp_dir: dir
  } do
    missing = Path.join(dir, "missing")
    assert {:ok, _} = pack(contract, missing)
    assert File.read!(Path.join(missing, ".covenant-pack")) =~ "example.counter"

    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)
    assert {:ok, _} = pack(contract, empty)
    assert File.exists?(Path.join(empty, "PROMPT.md"))
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "re-running into its own previous pack replaces it", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")
    assert {:ok, _} = pack(contract, out)
    File.write!(Path.join(out, "stale.txt"), "old")
    File.mkdir_p!(Path.join(out, "stale_dir"))
    File.write!(Path.join(out, "stale_dir/x"), "old")

    assert {:ok, %{files: files}} = pack(contract, out)
    refute File.exists?(Path.join(out, "stale.txt"))
    refute File.exists?(Path.join(out, "stale_dir"))
    assert Path.join(out, "PROMPT.md") in files
    assert File.exists?(Path.join(out, ".covenant-pack"))
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "clearing a pack unlinks symlinks without following them", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "pack")
    assert {:ok, _} = pack(contract, out)

    outside = Path.join(dir, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep.txt"), "keep")
    File.ln_s!(outside, Path.join(out, "link"))

    assert {:ok, _} = pack(contract, out)
    assert File.read!(Path.join(outside, "keep.txt")) == "keep"
    refute File.exists?(Path.join(out, "link"))
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "a file at the out path is refused", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "file")
    File.write!(out, "x")
    assert {:error, message} = pack(contract, out)
    assert message =~ "not a directory"
    assert File.read!(out) == "x"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "find_tests reads the declaration from the syntax tree", %{tmp_dir: dir} do
    tests = Path.join(dir, "test/contract")
    File.mkdir_p!(tests)

    File.write!(Path.join(tests, "multi_test.exs"), """
    defmodule MultiTest do
      use Covenant.Case,
        component: "example.counter",
        async: true
    end
    """)

    File.write!(Path.join(tests, "commented_test.exs"), """
    defmodule CommentedTest do
      # use Covenant.Case, component: "example.counter"
      @doc \"\"\"
      use Covenant.Case, component: "example.counter"
      \"\"\"
    end
    """)

    File.write!(Path.join(tests, "other_test.exs"), """
    defmodule OtherTest do
      use Covenant.Case, component: "example.greeter"
    end
    """)

    assert Regen.find_tests("example.counter", ["test/contract"], dir) ==
             ["test/contract/multi_test.exs"]
  end
end
