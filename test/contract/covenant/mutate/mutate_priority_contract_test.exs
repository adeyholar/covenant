defmodule Covenant.MutatePriorityContractTest do
  use Covenant.Case, component: "covenant.mutate", async: true
  alias Covenant.Mutate.{Hints, Mutant}

  @moduletag :tmp_dir
  @moduletag obligation: "covenant.mutate.I30"

  test "hints match the mutation, ignore missing modules, and use current costs", %{tmp_dir: root} do
    mutant = %Mutant{
      id: "m001",
      file: "target.ex",
      line: 2,
      column: 1,
      operator: :boolean_flip,
      from: "true",
      to: "false",
      index: 1
    }

    tests = %{
      "slow" => %{"module" => "Slow.Test"},
      "fast" => %{"module" => "Fast.Test"},
      "gone" => %{"module" => "Deleted.Test"}
    }

    path = Path.join(root, "hints.json")

    data = %{
      "component" => "example",
      "tests" => tests,
      "mutants" => [Mutant.to_map(%{mutant | verdict: :killed, killed_by: Map.keys(tests)})]
    }

    File.write!(path, Covenant.JSON.pretty(data))
    assert {:ok, hints} = Hints.load(path, "example")

    costs = [
      %{key: "slow", name: "slow", module: "Slow.Test", ms: 100, outcome: :passed},
      %{key: "fast", name: "fast", module: "Fast.Test", ms: 1, outcome: :passed}
    ]

    assert Hints.preferred(hints, %{mutant | id: "m999"}, [Slow.Test, Fast.Test], costs) == [
             %{module: Fast.Test, name: "fast"}
           ]

    assert Hints.preferred(hints, %{mutant | from: "changed"}, [Slow.Test, Fast.Test], costs) ==
             []

    assert Hints.preferred(hints, mutant, [Other.Test], costs) == []
    assert {:error, _} = Hints.load(path, "other")

    File.write!(
      path,
      Covenant.JSON.pretty(%{data | "tests" => [%{"key" => "fast", "module" => "Fast.Test"}]})
    )

    assert {:ok, raw_hints} = Hints.load(path, "example")

    assert Hints.preferred(raw_hints, mutant, [Fast.Test], costs) == [
             %{module: Fast.Test, name: "fast"}
           ]

    assert Hints.preferred(
             raw_hints,
             mutant,
             [Fast.Test],
             Enum.map(costs, &%{&1 | outcome: :excluded})
           ) == []

    assert Hints.load(nil, "example") == {:ok, %{}}
  end

  test "bad hint files fail clearly", %{tmp_dir: root} do
    path = Path.join(root, "hints.json")

    for text <- ["bad", "null", ~s({"component":"example","mutants":[null],"tests":[]})] do
      File.write!(path, text)
      assert {:error, message} = Hints.load(path, "example")
      assert message =~ "cannot read mutation hints"
    end
  end
end

defmodule Covenant.MutatePriorityE2EContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false
  @moduletag :e2e
  @moduletag timeout: 60_000
  @moduletag obligation: "covenant.mutate.I30"
  @project Path.expand("../../../fixtures/mutate/vm_project", __DIR__)
  @probe Path.expand("../../../fixtures/mutate/priority_probe.exs", __DIR__)

  test "good, wrong, and missing hints all require a real failure; passing hints run the whole suite" do
    for mode <- ["right", "wrong", "missing", "survived", "timeout", "order"] do
      {output, status} =
        System.cmd(System.find_executable("mix"), ["run", @probe, mode],
          cd: @project,
          env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil}],
          stderr_to_stdout: true
        )

      assert status == 0, output

      if mode in ["survived", "order"] do
        assert output =~ "PRIORITY_RESULT #{mode} survived exact 0"
        assert output =~ "KILLERS \n"
      else
        assert output =~ "PRIORITY_RESULT #{mode} killed"
        assert output =~ "KILLERS PriorityProbe.Killer:test witness"
      end

      if mode == "timeout", do: assert(output =~ "exact 1")
      if mode == "right", do: assert(length(Regex.scan(~r/PASSING_WITNESS/, output)) == 2)
      if mode == "right", do: assert(length(Regex.scan(~r/EXTRA_KILLER_WITNESS/, output)) == 2)
      if mode == "wrong", do: assert(length(Regex.scan(~r/PASSING_WITNESS/, output)) == 5)
    end
  end
end
