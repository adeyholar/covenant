defmodule Covenant.MutateOptimizationE2EContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false
  @moduletag :e2e
  @moduletag timeout: 180_000
  @project Covenant.ContractBuilder.fixture_project()
  @vm_project Path.expand("../../../fixtures/mutate/vm_project", __DIR__)

  setup do
    patterns = [
      Path.join(@project, "tmp/covenant/mutate/example.counter/run-*"),
      Path.join(@vm_project, "tmp/covenant/mutate/vm.checkpoint/run-*")
    ]

    previous = Enum.flat_map(patterns, &Path.wildcard/1)

    on_exit(fn ->
      for path <- Enum.flat_map(patterns, &Path.wildcard/1) -- previous, do: File.rm_rf!(path)
    end)

    :ok
  end

  @tag obligation: "covenant.mutate.I31"
  test "SIGTERM retains a verified group and resume reruns the stopped group" do
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, @vm_project},
        {:env,
         [
           {~c"MIX_ENV", ~c"test"},
           {~c"COVENANT_RESULTS_DIR", false},
           {~c"COVENANT_CHECKPOINT_WAIT", ~c"1"}
         ]},
        {:args,
         [
           "covenant.mutate",
           "vm.checkpoint",
           "--checkpoint",
           "--seed",
           "0",
           "--timeout",
           "1000",
           "--max-mutants-per-worker",
           "1",
           "--max-runtime",
           "60000"
         ]}
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    output = wait_for(port, "", "CHECKPOINT_WAIT ")
    assert output =~ "retired after 1 verified verdict(s)"
    {:os_pid, manager} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(manager)])
    {output, 1} = finished(port, output)
    assert output =~ "job cancelled by SIGTERM"
    [_, directory] = Regex.run(~r/partial results: ([^\n]+)/, output)
    assert length(Path.wildcard(Path.join(directory, "verified-*.json"))) == 1

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        [
          "covenant.mutate",
          "vm.checkpoint",
          "--resume",
          directory,
          "--seed",
          "0",
          "--timeout",
          "1000",
          "--max-mutants-per-worker",
          "1",
          "--max-runtime",
          "60000",
          "--out",
          "tmp/resume-cancelled.json"
        ],
        cd: @vm_project,
        env: [
          {"MIX_ENV", "test"},
          {"COVENANT_RESULTS_DIR", nil},
          {"COVENANT_CHECKPOINT_WAIT", "1"}
        ],
        stderr_to_stdout: true
      )

    # The known hanging mutant remains an unsorted timeout, never a kill.
    assert status == 1, output
    assert output =~ "reusing 1 verdict(s) from 1 verified group(s)"

    result =
      @vm_project |> Path.join("tmp/resume-cancelled.json") |> File.read!() |> JSON.decode!()

    assert result["summary"]["mutants"] == 3
    assert result["summary"]["timeouts"] == 1
    assert result["checkpoint"]["reused_mutants"] == 1
  end

  @tag obligation: "covenant.mutate.I31"
  test "a resumed selection checks the current baseline and reuses only sealed groups" do
    guard_file = Path.join(@project, "test/contract/example/resume_guard_contract_test.exs")
    marker = Path.join(@project, "tmp/resume-baseline-red")
    refute File.exists?(guard_file)
    File.rm(marker)

    File.write!(guard_file, """
    defmodule Example.ResumeGuardContractTest do
      use Covenant.Case, component: "example.counter", async: false
      @tag obligation: "example.counter.I1"
      test "current original baseline remains required" do
        refute File.exists?(#{inspect(marker)})
      end
    end
    """)

    on_exit(fn ->
      File.rm(guard_file)
      File.rm(marker)
    end)

    args = [
      "--only",
      "m001,m005,m039",
      "--checkpoint",
      "--max-mutants-per-worker",
      "1",
      "--out",
      "tmp/resume-first.json"
    ]

    {output, status} = mutate(args)
    assert status == 0, output
    first = matrix("tmp/resume-first.json")
    directory = first["checkpoint"]["directory"]
    assert length(Path.wildcard(Path.join(directory, "verified-*.json"))) == 3
    # Simulate a cancelled group: its raw file exists, but the parent never
    # observed a successful exit and final original-suite verification.
    seal = Path.wildcard(Path.join(directory, "verified-*.json")) |> hd()
    removed = seal |> File.read!() |> JSON.decode!() |> Map.fetch!("raw")

    missing_ids =
      directory
      |> Path.join(removed)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("mutants")
      |> Enum.map(& &1["id"])

    File.rm!(seal)

    {output, status} =
      mutate([
        "--resume",
        directory,
        "--jobs",
        "2",
        "--out",
        "tmp/resume-second.json" | Enum.take(args, 2)
      ])

    assert status == 0, output
    second = matrix("tmp/resume-second.json")
    assert second["checkpoint"]["reused_mutants"] == 2
    assert output =~ "baseline"
    for id <- missing_ids, do: assert(output =~ "  #{id} ")
    assert verdicts(first) == verdicts(second)
    # A fully cached selection still starts a fresh baseline worker.
    next = second["checkpoint"]["directory"]

    {output, status} =
      mutate(["--resume", next, "--only", "m001,m005,m039", "--out", "tmp/resume-all.json"])

    assert status == 0, output
    assert output =~ "0 mutant(s) pending"
    assert matrix("tmp/resume-all.json")["checkpoint"]["reused_mutants"] == 3
    File.write!(marker, "external state changed")

    {output, status} =
      mutate(["--resume", next, "--only", "m001,m005,m039", "--out", "tmp/resume-red.json"])

    assert status != 0
    assert output =~ "baseline is red"
    refute File.exists?(Path.join(@project, "tmp/resume-red.json"))
    File.rm!(marker)
    {output, status} = mutate(["--resume", next, "--only", "m001,m005,m039", "--seed", "1"])
    assert status != 0
    assert output =~ "inputs changed"
    refute output =~ "baseline"
  end

  @tag obligation: "covenant.mutate.I32"
  test "selective mode preserves a small exact matrix and skips independent contract compilation" do
    args = ["--only", "m001,m005,m039", "--macros", "--out", "tmp/compile-full.json"]
    {output, status} = mutate(args)
    assert status == 0, output
    first = matrix("tmp/compile-full.json")

    {output, status} =
      mutate([
        "--selective-recompile",
        "--out",
        "tmp/compile-selective.json" | Enum.take(args, 3)
      ])

    assert status == 0, output
    second = matrix("tmp/compile-selective.json")
    assert second["selective_recompile"]
    assert output =~ "recompile 0/"
    assert verdicts(first) == verdicts(second)
  end

  defp mutate(args) do
    System.cmd(
      System.find_executable("mix"),
      ["covenant.mutate", "example.counter", "--seed", "0", "--timeout", "1000" | args],
      cd: @project,
      env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil}],
      stderr_to_stdout: true
    )
  end

  defp matrix(path), do: @project |> Path.join(path) |> File.read!() |> JSON.decode!()

  defp verdicts(matrix),
    do: Enum.map(matrix["mutants"], &Map.take(&1, ~w(id at from to verdict credit killed_by)))

  defp wait_for(port, output, marker) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data
        if String.contains?(output, marker), do: output, else: wait_for(port, output, marker)

      {^port, {:exit_status, status}} ->
        flunk("manager exited #{status}: #{output}")
    after
      30_000 -> flunk("manager did not reach its test barrier: #{output}")
    end
  end

  defp finished(port, output) do
    receive do
      {^port, {:data, data}} -> finished(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      10_000 -> flunk("manager did not stop: #{output}")
    end
  end
end
