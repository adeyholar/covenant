defmodule Covenant.MutateRunnerUnitContractTest do
  use Covenant.Case, component: "covenant.mutate", async: true

  alias Covenant.Mutate.Runner

  @tag obligation: "covenant.mutate.I19"
  test "restore reloads every original it can and names those that will not load" do
    suffix = System.unique_integer([:positive])
    good = Module.concat(Covenant.MutateRestoreGood, "M#{suffix}")
    bad = Module.concat(Covenant.MutateRestoreBad, "M#{suffix}")

    [{^good, bin}] = Code.compile_string("defmodule #{inspect(good)} do\n  def f, do: 1\nend")
    :code.purge(good)
    :code.delete(good)
    :code.purge(good)
    refute :erlang.module_loaded(good)

    assert {:error, message} =
             Runner.restore([{bad, "not a beam", ~c"nofile"}, {good, bin, ~c"nofile"}])

    assert message =~ "cannot reload #{inspect(bad)} (:badfile)"
    refute message =~ inspect(good)
    assert good.f() == 1

    assert :ok = Runner.restore([{good, bin, ~c"nofile"}])
  end

  @tag obligation: "covenant.mutate.I21"
  test "the modules of a file that yield no mutant are the ones to warn about" do
    sites = [%{module: "A"}, %{module: "A.Inner"}]
    assert Runner.without_mutants(["A", "B", "A.Inner", "C"], sites) == ["B", "C"]
    assert Runner.without_mutants(["A"], sites) == []
    assert Runner.without_mutants(["A"], []) == ["A"]
  end

  @tag obligation: "covenant.mutate.I20"
  test "a mutant's budget is ten baselines, five seconds and the per-test timeout, and a stopped worker exits 3" do
    assert Runner.budget_ms(20, 1000) == 6200
    assert Runner.budget_ms(0, 1000) == 6000
    assert Runner.budget_ms(30_000, 150_000) == 455_000
    assert Runner.timeout_exit() == 3
  end
end

defmodule Covenant.MutateRunnerE2EContractTest do
  @moduledoc """
  Drives `Covenant.Mutate.Runner.run/1` in a fixture project (`vm_project`)
  whose mutants take the VM down or never end, through `runner_probe.exs`,
  which builds the plan by hand: the engine's safety nets are reached through
  `mix covenant.mutate` only in a worker, and a stopped worker halts the VM.
  """

  use Covenant.Case, component: "covenant.mutate", async: false

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project Path.expand("../../../fixtures/mutate/vm_project", __DIR__)
  @probe Path.expand("../../../fixtures/mutate/runner_probe.exs", __DIR__)

  defp probe(component, module, file, env \\ [], args \\ []) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    test_file = "test/contract/vm/#{Path.basename(file, ".ex")}_contract_test.exs"

    System.cmd(mix, ["run", @probe, component, module, file, test_file | args],
      cd: @project,
      env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil} | env],
      stderr_to_stdout: true
    )
  end

  @tag obligation: "covenant.mutate.I19"
  test "a mutant that stops an application it can restart does not stop the run" do
    {output, 0} = probe("vm.echo", "Vm.Echo", "lib/vm/echo.ex")

    assert output =~ "Application vm exited"
    assert output =~ "RESULT: {:ok, 12}"
  end

  @tag obligation: "covenant.mutate.I19"
  test "a mutant that stops an application that will not restart ends the run, naming the mutant" do
    {output, 0} = probe("vm.echo", "Vm.Echo", "lib/vm/echo.ex", [{"VM_FUSE", "1"}])

    assert output =~
             ~r/RESULT: \{:error,\s+"mutant m\d+ \(lib\/vm\/echo\.ex:\d+:\d+ \w+\) broke the VM: it stopped :vm and :vm would not restart/
  end

  @tag obligation: "covenant.mutate.I20"
  test "a mutant that loops outside ExUnit's timeouts is a timeout, and the worker stops with exit 3" do
    {output, status} = probe("vm.spin", "Vm.Spin", "lib/vm/spin.ex")

    assert status == 3
    # the id's number is the number of mutants judged, the timed-out one included
    assert [_, number, count] = Regex.run(~r/ON_TIMEOUT m(\d+) (\d+)/, output)
    assert String.to_integer(count) == String.to_integer(number)
    refute output =~ "RESULT:"
  end

  @tag obligation: "covenant.mutate.I20"
  test "a timed-out mutant's stray processes never write into the project" do
    File.rm_rf!(Path.join(@project, "tmp"))
    on_exit(fn -> File.rm_rf!(Path.join(@project, "tmp")) end)

    {output, status} = probe("vm.writer", "Vm.Writer", "lib/vm/writer.ex")

    assert status == 3
    # the callback ran inside the worker's copy, and the cwd never went back to the project
    assert [_, in_callback] = Regex.run(~r/CWD_IN_CALLBACK (\S+)/, output)
    assert Path.basename(in_callback) =~ ~r/^covenant-mutate-/
    # the copy is gone at the halt (not recreated empty), stray writers or not
    refute File.exists?(in_callback)
    # the probe waits a second after the timeout before it halts: nothing appeared in the project
    refute File.exists?(Path.join(@project, "tmp"))
  end

  @tag obligation: "covenant.mutate.I20"
  test "many tests that each hit the per-test timeout finish, and are not a hang" do
    {output, status} = probe("vm.count", "Vm.Count", "lib/vm/count.ex", [], ["1000"])

    assert status == 0
    refute output =~ "ON_TIMEOUT"
    assert output =~ ~r/RESULT: \{:ok, \d+\}/
  end

  @tag obligation: "covenant.mutate.I21"
  test "a run with nothing to mutate is an error, and a module without mutants is warned about" do
    {output, 0} = probe("vm.point", "Vm.Point", "lib/vm/point.ex")

    assert output =~ "warning: no mutant in Vm.Point (lib/vm/point.ex)"
    assert output =~ "no mutant to run: there is nothing to mutate in Vm.Point"
  end
end
