defmodule Covenant.MutateSelectionContractTest do
  use Covenant.Case, component: "covenant.mutate", async: true

  alias Covenant.Mutate.{Mutant, Selection, Survivors}
  alias Covenant.Mutate.Survivors.Annotation

  @moduletag :tmp_dir
  @moduletag obligation: "covenant.mutate.I29"

  test "IDs are explicit, repeatable, unique, and validated" do
    assert Selection.ids(["m0003,m0001", " m0003 "]) == {:ok, ["m0003", "m0001"]}
    assert Selection.ids([]) == {:ok, []}

    for values <- [[""], ["m0001,"], ["1"], ["m0001..m0005"]] do
      assert {:error, message} = Selection.ids(values)
      assert message =~ "--only expects"
    end

    sites = [mutant("m0001", 1), mutant("m0002", 2), mutant("m0003", 3)]
    assert {:ok, [first, last]} = Selection.choose(sites, ["m0003", "m0001"])
    assert [first.id, last.id] == ["m0001", "m0003"]
    assert Selection.choose(sites, []) == {:ok, sites}
    assert {:error, message} = Selection.choose(sites, ["m9999"])
    assert message =~ "m9999"
  end

  test "catalog numbering follows sorted files and filters ownership first", %{tmp_dir: root} do
    a = Path.join(root, "a.ex")
    b = Path.join(root, "b.ex")
    File.write!(a, "defmodule SelectA do\n def value, do: true\nend")
    File.write!(b, "defmodule SelectB do\n def value, do: false\nend")
    modules = [{SelectB, b}, {SelectA, a}]
    catalog = Selection.catalog(modules, root, true, fn m -> m.operator == :boolean_flip end)
    assert Enum.map(catalog, &{&1.id, &1.file}) == [{"m001", "a.ex"}, {"m002", "b.ex"}]
    assert {:ok, [last]} = Selection.choose(catalog, ["m002"])
    assert last.file == "b.ex"
  end

  test "only known excluded annotations are deferred" do
    selected = mutant("m0001", 1)
    excluded = mutant("m0002", 2)
    unknown = mutant("m9999", 9)
    annotations = Enum.map([selected, excluded, unknown], &annotation/1)
    assert {active, [], 1} = Selection.annotations(annotations, [selected, excluded], [selected])
    assert Enum.map(active, & &1.at) == [Mutant.at(selected), Mutant.at(unknown)]
    assert Survivors.find(active, %{selected | verdict: :killed}) != nil
  end

  test "raw checkpoints retain selection scope and mixed scopes cannot merge", %{tmp_dir: root} do
    path = Path.join(root, "raw.json")

    result = %{
      files: [],
      all: 1,
      baseline_ms: 1,
      timeout_ms: 1000,
      tests: [],
      mutants: [%{mutant("m0002", 2) | verdict: :survived}]
    }

    File.write!(path, Covenant.Mutate.encode_raw(result, component: "example", only: ["m0002"]))
    assert {:ok, raw} = Covenant.Mutate.decode_raw(path)
    assert raw.only == ["m0002"]
    assert {:error, message} = Covenant.Mutate.merge([raw, %{raw | only: []}])
    assert message =~ "different mutant selections"
  end

  test "occurrence declarations are resolved before selection" do
    sites = [mutant("m0001", 1), mutant("m0002", 2)]

    declaration = %Annotation{
      at: "Example.value/0",
      operator: "*",
      sort: "equivalent",
      reason: "test",
      file: "mutants.md",
      line: 1,
      unit: "Example.value/0",
      change: "true -> false",
      from: "true",
      to: "false",
      occurrence: 2
    }

    assert {[resolved], [], 0} = Selection.annotations([declaration], sites, [List.last(sites)])
    assert resolved.pinned == "m0002"
    assert {[], [], 1} = Selection.annotations([declaration], sites, [hd(sites)])

    assert {[], [_], 0} =
             Selection.annotations([%{declaration | occurrence: nil}], sites, [hd(sites)])
  end

  defp mutant(id, line) do
    %Mutant{
      id: id,
      file: "lib/example.ex",
      line: line,
      column: 1,
      operator: :boolean_flip,
      from: "true",
      to: "false",
      index: line,
      module: "Example",
      function: "value/0"
    }
  end

  defp annotation(m) do
    %Annotation{
      at: Mutant.at(m),
      operator: "boolean_flip",
      mutation: Mutant.mutation(m),
      sort: "equivalent",
      reason: "test",
      file: "survivors.yml",
      line: 1
    }
  end
end
