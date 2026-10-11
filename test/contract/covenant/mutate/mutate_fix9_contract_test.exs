defmodule Covenant.MutateFix9ContractTest do
  @moduledoc """
  The private copy's removal and registration, and the task's check of a survivors file.
  """

  use Covenant.Case, component: "covenant.mutate", async: false

  import ExUnit.CaptureIO

  alias Covenant.Mutate.Workdir
  alias Mix.Tasks.Covenant.Mutate, as: Task

  setup do
    dir = Path.join(System.tmp_dir!(), "fix9-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Workdir.unlock(dir)
      File.rm_rf!(dir)
    end)

    %{scratch: dir}
  end

  @tag obligation: "covenant.mutate.I15"
  test "remove unlinks a workdir path that was replaced by a symlink and never touches its target",
       %{scratch: scratch} do
    target = Path.join(scratch, "target")
    File.mkdir_p!(Path.join(target, "deps_real"))
    File.write!(Path.join(target, ".env_real"), "secret")
    File.ln_s!(Path.join(target, "deps_real"), Path.join(target, "deps"))
    File.ln_s!(Path.join(target, ".env_real"), Path.join(target, ".env"))

    workdir = Path.join(scratch, "covenant-mutate-1-link")
    File.ln_s!(target, workdir)

    assert Workdir.remove(workdir) == :ok

    assert {:error, :enoent} = File.lstat(workdir)
    assert match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(target, "deps")))
    assert match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(target, ".env")))
    assert File.read!(Path.join(target, ".env_real")) == "secret"
  end

  @tag obligation: "covenant.mutate.I15"
  test "remove removes a workdir that a mutant left unreadable (mode 000)", %{scratch: scratch} do
    workdir = Path.join(scratch, "covenant-mutate-1-locked")
    File.mkdir_p!(Path.join(workdir, "tmp/inner"))
    File.write!(Path.join(workdir, "tmp/inner/file"), "x")
    File.chmod!(Path.join(workdir, "tmp"), 0o000)
    File.chmod!(workdir, 0o000)

    assert Workdir.remove(workdir) == :ok

    refute File.exists?(workdir)
  end

  @tag obligation: "covenant.mutate.I23"
  test "the private copy is registered for the stdin watcher as soon as it exists, while it is copied",
       %{scratch: scratch} do
    root = Path.join(scratch, "root")
    base = Path.join(scratch, "base")
    File.mkdir_p!(base)

    for d <- 1..40, f <- 1..100 do
      path = Path.join(root, "d#{d}/f#{f}")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x")
    end

    on_exit(&Workdir.unregister/0)
    assert Workdir.registered() == nil
    parent = self()

    builder =
      spawn_link(fn ->
        dir = Workdir.build(root, base, "reg", true)
        send(parent, {:built, dir})
      end)

    # polls until the builder has made the directory: it must be registered by then,
    # long before the copy of the 4,000 files is done
    registered = poll_registered()
    refute_received {:built, _}
    assert registered == Path.join(base, "covenant-mutate-#{System.pid()}-reg")

    assert_receive {:built, dir}, 30_000
    assert dir == registered
    assert Workdir.registered() == dir
    refute Process.alive?(builder)

    # a watcher that finds the key removes the copy
    assert Workdir.remove_registered() == :ok
    refute File.exists?(dir)

    # and a build that was not asked to register leaves the key alone
    Workdir.unregister()
    other = Workdir.build(root, base, "plain")
    assert Workdir.registered() == nil
    Workdir.remove(other)
  end

  defp poll_registered do
    case Workdir.registered() do
      nil -> poll_registered()
      dir -> dir
    end
  end

  @tag obligation: "covenant.mutate.I22"
  test "a survivors file the strict reader refuses (two documents, merge key, duplicate key) fails the task, naming file and line",
       %{scratch: scratch} do
    path = Path.join(scratch, "x.survivors.yml")

    cases = [
      {"- id: a\n---\n[]\n", ~r/x\.survivors\.yml:3: more than one YAML document/},
      {"- &k\n  a: 1\n- <<: *k\n  b: 2\n", ~r/x\.survivors\.yml:\d+: /},
      {"- a: 1\n  a: 2\n", ~r/x\.survivors\.yml:\d+: /}
    ]

    for {text, message} <- cases do
      File.write!(path, text)

      output =
        capture_io(:stderr, fn ->
          assert catch_exit(Task.check_survivors_document(path)) == {:shutdown, 1}
        end)

      assert output =~ message
      assert output =~ "could not be parsed"
    end
  end

  @tag obligation: "covenant.mutate.I22"
  test "a single-document survivors file, a missing one and a mutants.md pass the check",
       %{scratch: scratch} do
    path = Path.join(scratch, "x.survivors.yml")
    File.write!(path, "- id: a\n")
    assert Task.check_survivors_document(path) == :ok
    assert Task.check_survivors_document(Path.join(scratch, "none.survivors.yml")) == :ok
    File.write!(Path.join(scratch, "mutants.md"), "---\n[]\n")
    assert Task.check_survivors_document(Path.join(scratch, "mutants.md")) == :ok
  end
end

defmodule Covenant.MutateFix9E2EContractTest do
  @moduledoc """
  Fixtures of `vm_project` whose unmutated re-run hangs after a mutant, or whose
  mutant hangs the compilation.
  """

  use Covenant.Case, component: "covenant.mutate", async: false

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project Path.expand("../../../fixtures/mutate/vm_project", __DIR__)
  @probe Path.expand("../../../fixtures/mutate/runner_probe.exs", __DIR__)

  defp mix(args, env) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    env = [{"COVENANT_RESULTS_DIR", nil}, {"COVENANT_TMPDIR_LOG", nil} | env]
    System.cmd(mix, args, cd: @project, env: env, stderr_to_stdout: true)
  end

  defp probe(component, module, file) do
    test_file = "test/contract/vm/#{Path.basename(file, ".ex")}_contract_test.exs"
    mix(["run", @probe, component, module, file, test_file], [{"MIX_ENV", "test"}])
  end

  @tag obligation: "covenant.mutate.I20"
  test "an unmutated re-run that outruns its budget abandons the copy and halts with exit 3, naming the last mutant" do
    {output, status} = probe("vm.hang", "Vm.Hang", "lib/vm/hang.ex")

    assert status == 3
    assert output =~ ~r/did not finish within \d+ ms after the last mutant, mutant m002 /
    # the working directory never went back to the project: the copy is gone at the halt
    assert output =~ "CWD_AT_HALT {:error, :enoent}"
    # no mutant timed out: nothing to persist
    refute output =~ "ON_TIMEOUT"
    refute output =~ "RESULT:"
  end

  @tag obligation: "covenant.mutate.I22"
  test "the task reports a stopped sanity re-run as an error naming the mutant, and starts no new worker" do
    {output, status} =
      mix(["covenant.mutate", "vm.hang", "--out", "tmp/hang.json"], [{"MIX_ENV", "dev"}])

    assert status == 1
    assert output =~ "stopped by its watchdog outside a mutant"
    assert output =~ "after the last mutant, mutant m002"
    refute output =~ "starting a new worker"
  end

  @tag obligation: "covenant.mutate.I20"
  test "a mutant that hangs the compilation is a timeout, and the worker stops with exit 3" do
    {output, status} = probe("vm.compile", "Vm.Compile", "lib/vm/compile.ex")

    assert status == 3
    assert output =~ "ON_TIMEOUT m001 1"
    assert output =~ "LAST_VERDICT timeout"
    assert output =~ "CWD_AT_HALT {:error, :enoent}"
    refute output =~ "RESULT:"
  end

  @tag obligation: "covenant.mutate.I22"
  test "the task carries on after a mutant that hangs the compilation" do
    {output, status} =
      mix(["covenant.mutate", "vm.compile", "--out", "tmp/compile.json"], [{"MIX_ENV", "dev"}])

    assert status == 1
    assert output =~ ~r/m001 .* \[timeout\]/
    assert output =~ "stopped by its watchdog"
  end
end
