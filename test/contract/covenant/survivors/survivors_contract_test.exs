defmodule Covenant.SurvivorsContractTest do
  @moduledoc """
  The survivor keys of `covenant.mutate` (I8, I9): how a survivors-file entry
  and a `mutants.md` declaration name the survivors they sort. Pure calls, so
  `mix covenant.mutate covenant.mutate` can run this file against its mutants.
  """

  use Covenant.Case, component: "covenant.mutate", async: true

  alias Covenant.Contract.Component
  alias Covenant.Mutate.{Matrix, Mutant, Survivors}
  alias Covenant.Mutate.Survivors.Annotation
  alias Covenant.Parser.Primitive

  @component %Component{
    id: "lab",
    app: "contract",
    name: "lab",
    form: :primitive,
    file: "README.md"
  }

  defp mutant(id, line, attrs \\ []) do
    struct!(
      Mutant,
      [
        id: id,
        file: "lib/lab.ex",
        line: line,
        column: 9,
        operator: :integer_shift,
        from: "1",
        to: "2",
        index: line,
        module: "Lab.Retry",
        function: "run/1",
        verdict: :survived
      ] ++ attrs
    )
  end

  defp declarations!(lines) do
    {:ok, annotations} =
      Primitive.declarations("## Kept\n\n```unpromised\n#{lines}\n```\n", "mutants.md")

    annotations
  end

  defp matrix(mutants, annotations) do
    {annotations, unresolved} = Survivors.resolve(annotations, mutants)

    test = %{
      key: "T:t",
      module: "T",
      name: "t",
      file: "t.exs",
      line: 1,
      obligations: ["lab/A1"],
      mutation_blind: nil,
      outcome: :passed
    }

    matrix =
      Matrix.build(
        %{tests: [test], mutants: mutants, modules: ["Lab.Retry"], files: [], baseline_ms: 1},
        component: @component,
        annotations: annotations
      )

    {matrix, unresolved}
  end

  @tag obligation: "covenant.mutate.I9"
  test "a declaration names exactly one mutant, and is ambiguous when several share its change" do
    first = mutant("m001", 10)
    second = mutant("m002", 40)

    {[], [error]} = Survivors.resolve(declarations!("Lab.Retry.run/1: 1 -> 2"), [first, second])
    assert error.file == "mutants.md" and error.line == 4

    assert error.message ==
             "ambiguous: 2 mutants in Lab.Retry.run/1 share 1 -> 2; add #1 to #2 to name one (in source order)"

    {[only], []} = Survivors.resolve(declarations!("Lab.Retry.run/1: 1 -> 2"), [first])
    assert only.pinned == "m001"
    assert Survivors.matches?(only, first)
    refute Survivors.matches?(only, %{first | id: "m009"})
  end

  @tag obligation: "covenant.mutate.I9"
  test "#k counts every mutant of the unit sharing the change in source order, killed or not" do
    # ids out of source order, and the first one killed: #2 is still the one at line 40
    killed = mutant("m003", 10, verdict: :killed, killed_by: ["T:t"])
    later = mutant("m001", 40)
    middle = mutant("m002", 25)
    other = mutant("m004", 30, to: "0")

    {[two], []} =
      Survivors.resolve(declarations!("Lab.Retry.run/1: 1 -> 2 #2"), [
        later,
        killed,
        middle,
        other
      ])

    assert two.pinned == "m002"

    {[three], []} =
      Survivors.resolve(declarations!("Lab.Retry.run/1: 1 -> 2 #3"), [
        later,
        killed,
        middle,
        other
      ])

    assert three.pinned == "m001"

    {[], [error]} =
      Survivors.resolve(declarations!("Lab.Retry.run/1: 1 -> 2 #4"), [later, killed, middle])

    assert error.message == "#4: only 3 mutant(s) in Lab.Retry.run/1 share 1 -> 2"
  end

  @tag obligation: "covenant.mutate.I9"
  test "staleness is per line: each line needs its own survivor, a wildcard at least one" do
    first = mutant("m001", 10)
    second = mutant("m002", 40)
    lines = "Lab.Retry.run/1: 1 -> 2 #1\nLab.Retry.run/1: 1 -> 2 #2"

    {sorted, []} = matrix([first, second], declarations!(lines))
    assert sorted.problems == []
    assert Enum.map(sorted.survivors, & &1.sort) == ["unpromised", "unpromised"]

    killed = %{second | verdict: :killed, killed_by: ["T:t"]}
    {stale, []} = matrix([first, killed], declarations!(lines))
    assert [problem] = stale.problems
    assert problem.line == 5
    assert problem.message =~ "(m002) is contradicted: a Contract test kills that mutant"

    {one, []} = matrix([first, second], declarations!("Lab.Retry.run/1: 1 -> 2 #1"))
    assert [%{message: message}] = one.problems
    assert message =~ "mutant m002 (integer_shift `1` → `2`) survived"

    {missing, []} = matrix([first], declarations!("Lab.Retry.run/1: 3 -> 4"))
    assert Enum.any?(missing.problems, &(&1.message =~ "matches no surviving mutant"))

    {wild, []} = matrix([first, second], declarations!("Lab.Retry.run/1: *"))
    assert wild.problems == []

    gone = Enum.map([first, second], &%{&1 | verdict: :killed, killed_by: ["T:t"]})
    {wild_stale, []} = matrix(gone, declarations!("Lab.Retry.run/1: *"))

    assert [%{message: "declaration `Lab.Retry.run/1: *` (m001) is contradicted" <> _}] =
             wild_stale.problems
  end

  @tag obligation: "covenant.mutate.I9"
  test "wildcards and survivors-file entries pass through resolve unpinned" do
    yaml = %Annotation{
      at: "lib/lab.ex:10:9",
      operator: "integer_shift",
      mutation: "`1` → `2`",
      sort: "equivalent",
      reason: "r",
      file: "lab.survivors.yml",
      line: 1
    }

    [wild] = declarations!("Lab.Retry.run/1: *")
    {[^yaml, ^wild], []} = Survivors.resolve([yaml, wild], [mutant("m001", 10)])
  end

  @tag obligation: "covenant.mutate.I9"
  test "a survivor's mutants.md line carries #k when other mutants of its unit share the change" do
    first = mutant("m001", 10)
    second = mutant("m002", 40)
    lone = mutant("m003", 50, to: "0")
    all = [second, first, lone]

    assert Survivors.template(second, format: :md, mutants: all) == "Lab.Retry.run/1: 1 -> 2 #2"
    assert Survivors.template(first, format: :md, mutants: all) == "Lab.Retry.run/1: 1 -> 2 #1"
    assert Survivors.template(lone, format: :md, mutants: all) == "Lab.Retry.run/1: 1 -> 0"
    assert Survivors.template(lone, format: :md) == "Lab.Retry.run/1: 1 -> 0"
  end
end
