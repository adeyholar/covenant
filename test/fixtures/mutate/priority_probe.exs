alias Covenant.Mutate.{Hints, Mutator, Runner}

[mode] = System.argv()
root = Path.join(System.tmp_dir!(), "covenant-priority-#{System.pid()}")
File.mkdir!(root)
source = Path.join(root, "target.ex")
tests = Path.join(root, "contract_test.exs")

try do
  File.cp_r!("contracts", Path.join(root, "contracts"))
  File.write!(source, "defmodule PriorityProbe.Target do\n def value, do: true\nend")
  {:ok, ast} = Mutator.parse(File.read!(source), source)
  {:ok, _} = Mutator.compile(ast, source)

  [site] =
    Mutator.sites(ast, file: "target.ex")
    |> Enum.filter(&(&1.operator == :boolean_flip))
    |> Mutator.numbered()

  selected =
    if mode in ["right", "order"], do: "PriorityProbe.Killer", else: "PriorityProbe.Passing"

  selected = if mode == "missing", do: "Deleted.TestModule", else: selected
  key = selected <> ":test witness"

  hint = %{
    "component" => "vm.macro",
    "tests" => %{key => %{"module" => selected}},
    "mutants" => [Covenant.Mutate.Mutant.to_map(%{site | verdict: :killed, killed_by: [key]})]
  }

  hint_path = Path.join(root, "hints.json")
  File.write!(hint_path, Covenant.JSON.pretty(hint))
  {:ok, hints} = Hints.load(hint_path, "vm.macro")

  File.write!(tests, """
  defmodule PriorityProbe.Passing do
    use Covenant.Case, component: "vm.macro", async: false
    @tag obligation: "vm.macro.I1"
    test "witness" do
      IO.puts("PASSING_WITNESS")
      #{if mode == "order", do: ":persistent_term.put(:priority_ready, true)", else: ""}
      #{if mode == "timeout", do: "if not PriorityProbe.Target.value(), do: Process.sleep(1_000)", else: "assert true"}
    end
  end
  defmodule PriorityProbe.Killer do
    use Covenant.Case, component: "vm.macro", async: false
    @tag hidden: true
    @tag obligation: "vm.macro.I1"
    test "excluded", do: flunk("original filters must remain active")
    @tag obligation: "vm.macro.I1"
    test "other", do: IO.puts("EXTRA_KILLER_WITNESS")
    @tag obligation: "vm.macro.I1"
    test "witness" do
      IO.puts("KILLER_WITNESS")
      #{cond do
    mode == "order" -> "assert :persistent_term.get(:priority_ready, false)\n:persistent_term.erase(:priority_ready)"
    mode == "survived" -> "assert true"
    true -> "assert PriorityProbe.Target.value()"
  end}
    end
  end
  """)

  ExUnit.start(autorun: false, exclude: [:hidden])

  plan = %{
    component: "vm.macro",
    modules: [{PriorityProbe.Target, source}],
    test_files: [tests],
    root: root,
    seed: 0,
    timeout: 50,
    slice: {1, 1},
    fail_fast: true,
    prioritize: hints,
    keep: &(&1.operator == :boolean_flip),
    on_progress: fn _ -> :ok end
  }

  {:ok, %{mutants: [mutant]}} = Runner.run(plan)
  true = PriorityProbe.Target.value()
  IO.puts("PRIORITY_RESULT #{mode} #{mutant.verdict} #{mutant.credit} #{length(mutant.timeouts)}")
  IO.puts("KILLERS #{Enum.join(mutant.killed_by, ",")}")
after
  File.rm_rf!(root)
end
