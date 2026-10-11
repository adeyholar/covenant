defmodule Covenant.MutateRound4ContractTest do
  @moduledoc """
  The runner and the workdir against suites with a slow teardown, a test that hangs
  after another has killed, a base directory inside the project, and a parent that dies.
  """

  use Covenant.Case, component: "covenant.mutate", async: false

  alias Covenant.Mutate.Workdir

  @moduletag :e2e
  @moduletag timeout: 300_000

  @vm Path.expand("../../../fixtures/mutate/vm_project", __DIR__)
  @probe Path.expand("../../../fixtures/mutate/runner_probe.exs", __DIR__)

  defp probe(component, module, file, env \\ [], args \\ []) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    test_file = "test/contract/vm/#{Path.basename(file, ".ex")}_contract_test.exs"

    System.cmd(mix, ["run", @probe, component, module, file, test_file | args],
      cd: @vm,
      env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil} | env],
      stderr_to_stdout: true
    )
  end

  defp scratch do
    dir = Path.join(System.tmp_dir!(), "covenant-round4-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @tag obligation: "covenant.mutate.I19"
  test "a suite whose teardown outlasts a mutant's timeout is measured with it: no unreliable worker, no timeout survivor" do
    {output, status} = probe("vm.slow", "Vm.Slow", "lib/vm/slow.ex")

    assert status == 0, output
    assert output =~ ~r/RESULT: \{:ok, \d+\}/
    assert [_, verdicts] = Regex.run(~r/VERDICTS (%\{.*\})/, output)
    assert verdicts =~ "survived:"
    refute verdicts =~ "timeout:"
  end

  @tag obligation: "covenant.mutate.I19"
  test "a test that leaves a read-only directory in its tmp_dir does not make the next run of it fail" do
    {output, status} = probe("vm.chmod", "Vm.Chmod", "lib/vm/chmod.ex")

    assert status == 0, output
    assert output =~ ~r/RESULT: \{:ok, \d+\}/
  end

  @tag obligation: "covenant.mutate.I20"
  test "a mutant killed by an early test that a later one then hangs is a partial kill, not a timeout" do
    {output, status} = probe("vm.early", "Vm.Early", "lib/vm/early.ex", [], ["1000"])

    assert status == 3, output
    assert output =~ "ON_TIMEOUT"
    assert output =~ ~r/LAST_VERDICT killed partial \["Vm\.EarlyContractTest:test inc steps up/
  end

  @tag obligation: "covenant.mutate.I15"
  test "a base directory under the project root is refused, except under its top-level tmp" do
    root = scratch()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "x")
    File.mkdir_p!(Path.join(root, ".tmp"))

    error = assert_raise ArgumentError, fn -> Workdir.build(root, Path.join(root, ".tmp")) end
    assert error.message =~ "lies under the project root"
    assert File.ls!(Path.join(root, ".tmp")) == []
    assert_raise ArgumentError, fn -> Workdir.build(root, root) end

    File.mkdir_p!(Path.join(root, "tmp/base"))
    dir = Workdir.build(root, Path.join(root, "tmp/base"))
    assert File.read!(Path.join(dir, "lib/a.ex")) == "x"
    Workdir.remove(dir)
  end

  @tag obligation: "covenant.mutate.I15"
  test "the copy leaves out the caches and tools' directories at the top level, and the dialyzer PLTs" do
    root = scratch()

    for path <-
          ~w(cover/a doc/a .lexical/a .expert/a priv/plts/a priv/keep/a lib/cover/a lib/priv/plts/a) do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), "x")
    end

    File.write!(Path.join(root, "erl_crash.dump"), "x")
    File.write!(Path.join(root, "lib/erl_crash.dump"), "x")

    dir = Workdir.build(root, scratch())

    for gone <- ~w(cover doc .lexical .expert erl_crash.dump priv/plts) do
      refute File.exists?(Path.join(dir, gone)), gone
    end

    for kept <- ~w(priv/keep/a lib/cover/a lib/priv/plts/a lib/erl_crash.dump) do
      assert File.exists?(Path.join(dir, kept)), kept
    end

    Workdir.remove(dir)
  end

  @tag obligation: "covenant.mutate.I20"
  test "a stopped worker leaves no directory behind: the copy is removed, and the halt follows" do
    {output, status} = probe("vm.spin", "Vm.Spin", "lib/vm/spin.ex")

    assert status == 3, output
    assert [_, in_callback] = Regex.run(~r/CWD_IN_CALLBACK (\S+)/, output)
    refute File.exists?(in_callback)
  end

  @tag obligation: "covenant.mutate.I23"
  test "a worker whose parent dies removes its copy of the project" do
    base = scratch()
    mix = System.find_executable("mix") || raise "mix not on PATH"

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["covenant.mutate", "vm.spin", "--out", "tmp/orphan.json"],
        cd: @vm,
        env: [{~c"MIX_ENV", ~c"dev"}, {~c"TMPDIR", String.to_charlist(base)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    runs = Path.join(@vm, "tmp/covenant")
    File.rm_rf!(runs)
    on_exit(fn -> File.rm_rf!(runs) end)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    copies = fn -> Path.wildcard(Path.join(base, "covenant-mutate-*")) end
    # a copy that is built and entered (the worker records it only then)
    built = fn -> Enum.any?(copies.(), &File.exists?(Path.join(&1, "mix.exs"))) end
    assert wait_until(60_000, built), "the worker made no copy"
    Process.sleep(1_000)

    # the parent dies: the worker's standard input ends, and it halts
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert wait_until(20_000, fn -> copies.() == [] end), "left: #{inspect(copies.())}"
  end

  defp wait_until(ms, fun) do
    cond do
      fun.() -> true
      ms <= 0 -> false
      true -> Process.sleep(100) && wait_until(ms - 100, fun)
    end
  end
end
