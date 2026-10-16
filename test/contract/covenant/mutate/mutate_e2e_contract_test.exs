defmodule Covenant.MutateE2EContractTest do
  @moduledoc """
  Runs `mix covenant.mutate` as a subprocess inside the fixture project, the
  way a user would. These tests exercise the real files, not an in-memory
  mutant, so they are left out of the self-mutation run
  (`mix covenant.mutate covenant.mutate --test-path .../mutate_contract_test.exs`).
  """

  use Covenant.Case, component: "covenant.mutate", async: false

  alias Covenant.ContractBuilder

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project ContractBuilder.fixture_project()

  defp mix(args) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    env = [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}, {"COVENANT_TMPDIR_LOG", nil}]
    System.cmd(mix, args, cd: @project, env: env, stderr_to_stdout: true)
  end

  defp mutate(component, extra \\ []), do: mix(["covenant.mutate", component | extra])

  defp read_matrix(relative), do: Path.join(@project, relative) |> File.read!() |> JSON.decode!()

  setup_all do
    File.mkdir_p!(Path.join(@project, "tmp"))

    {first_output, 0} = mutate("example.counter", ["--out", "tmp/mutate-first.json"])
    {_, 0} = mutate("example.counter", ["--out", "tmp/mutate-second.json"])

    {:ok,
     output: first_output,
     first: read_matrix("tmp/mutate-first.json"),
     second: read_matrix("tmp/mutate-second.json")}
  end

  # a throwaway copy of the fixture's contracts, so a test can break its own
  defp contracts_copy(name) do
    dir = Path.join(@project, "tmp/#{name}")
    File.rm_rf!(dir)
    ContractBuilder.copy_fixture_contracts(dir)
    {dir, "tmp/#{name}"}
  end

  @tag obligation: "covenant.mutate.I4"
  test "a mutant that does not compile is invalid: no kill, no survivor, no credit, not in the score",
       %{
         first: matrix,
         output: output
       } do
    invalid = Enum.filter(matrix["mutants"], &(&1["verdict"] == "invalid"))
    assert invalid != []

    for mutant <- invalid do
      assert mutant["killed_by"] == []
      assert mutant["timeouts"] == []
      assert mutant["obligations"] == []
      assert mutant["reason"] =~ "undefined variable"
      refute mutant["id"] in Enum.map(matrix["survivors"], & &1["id"])
    end

    assert output =~ ~r/m\d+ .*  invalid: line \d+:\d+: .*undefined variable/

    summary = matrix["summary"]
    assert summary["invalid"] == length(invalid)

    assert summary["killed"] + summary["survived"] + summary["timeouts"] + summary["invalid"] ==
             summary["mutants"]

    assert summary["score"] ==
             Float.round(
               summary["killed"] / (summary["killed"] + summary["survived"] + summary["timeouts"]),
               4
             )

    credited = matrix["obligations"] |> Map.values() |> Enum.flat_map(& &1["mutants"])
    refute Enum.any?(invalid, &(&1["id"] in credited))
  end

  @tag obligation: "covenant.mutate.I12"
  test "the matrix is written to --out as JSON and printed as a table", %{
    first: matrix,
    output: output
  } do
    assert matrix |> Map.keys() |> Enum.sort() ==
             ~w(baseline component covenant fail_fast files jobs modules mutants obligations problems seed summary survivors tests timeout_ms)

    assert matrix["covenant"] == Covenant.version()
    assert matrix["component"] == "example.counter"
    assert matrix["modules"] == ["Example.Counter"]
    assert matrix["files"] == ["lib/example/counter.ex"]
    assert {matrix["seed"], matrix["jobs"], matrix["fail_fast"]} == {0, 1, false}
    # measured from the baseline: five times its slowest test, at least a second
    assert matrix["timeout_ms"] >= 1000
    assert output =~ "per-test timeout #{matrix["timeout_ms"]} ms"
    assert %{"tests" => 7, "ms" => ms} = matrix["baseline"]
    assert is_integer(ms)
    assert matrix["problems"] == []

    summary = matrix["summary"]
    assert summary["mutants"] == length(matrix["mutants"])
    assert summary["annotated"] == length(matrix["survivors"])
    assert summary["unsorted"] == 0
    assert Enum.all?(matrix["survivors"], &(&1["sort"] != nil and &1["reason"] != nil))

    assert Map.keys(matrix["obligations"]) |> Enum.sort() ==
             ~w(example.counter.I1 example.counter.I2 example.counter.I3 example.counter.I4 example.counter.I6 example.counter.I7)

    assert Map.keys(matrix["tests"]) |> length() == 7

    assert output =~ "Kill matrix — example.counter (Example.Counter)"

    assert output =~
             "#{summary["mutants"]} mutants: #{summary["killed"]} killed, #{summary["survived"]} survived"

    assert output =~ "covenant.mutate: every mutant is caught or sorted"
  end

  @tag obligation: "covenant.mutate.I14"
  test "two runs over the same sources with the same seed give the same mutants and credit", %{
    first: first,
    second: second
  } do
    assert first["mutants"] == second["mutants"]
    assert first["obligations"] == second["obligations"]
    assert first["survivors"] == second["survivors"]
    assert first["summary"] == second["summary"]

    ids = Enum.map(first["mutants"], & &1["id"])
    assert ids == for(i <- 1..length(ids), do: "m" <> String.pad_leading("#{i}", 3, "0"))
  end

  @tag obligation: "covenant.mutate.I6"
  test "a red baseline mutates nothing and exits 1 naming the failing test" do
    broken = Path.join(@project, "test/contract/example/broken_mutate_contract_test.exs")

    File.write!(broken, """
    defmodule Example.BrokenMutateContractTest do
      use Covenant.Case, component: "example.greeter"

      @tag obligation: "example.greeter.I1"
      test "fails on purpose", do: assert Example.Greeter.greet("x") == "nope"
    end
    """)

    on_exit(fn -> File.rm(broken) end)

    {output, status} = mutate("example.greeter", ["--out", "tmp/mutate-red.json"])
    assert status == 1
    assert output =~ "the baseline is red; fix the suite before mutating:"
    assert output =~ "test fails on purpose (Example.BrokenMutateContractTest) failed"
    refute output =~ "m001"
    refute File.exists?(Path.join(@project, "tmp/mutate-red.json"))
  end

  @tag obligation: "covenant.mutate.I6"
  test "no contract test for the component, or an unknown component, exits 1 with the reason" do
    {output, status} = mutate("example.greeter", ["--test-path", "tmp/nowhere"])
    assert status == 1

    assert output =~
             "covenant.mutate: no contract test file declares `use Covenant.Case, component: \"example.greeter\"` under tmp/nowhere"

    {output, status} = mutate("example.nothing")
    assert status == 1

    assert output =~
             "unknown component `example.nothing`; known: example.counter, example.greeter"
  end

  @tag obligation: "covenant.mutate.I13"
  test "an unannotated survivor fails the task and gets a skeleton to fill" do
    {dir, relative} = contracts_copy("mutate-unsorted")
    File.rm!(Path.join(dir, "example/greeter.survivors.yml"))

    {output, status} =
      mutate("example.greeter", ["--contracts", relative, "--out", "tmp/mutate-unsorted.json"])

    assert status == 1

    assert output =~
             "lib/example/greeter.ex:10: mutant m007 (guard_removal `when is_binary(name)` → `(no guard)`) survived; " <>
               "add a test that catches it or annotate it in #{relative}/example/greeter.survivors.yml"

    assert output =~
             "To annotate the unsorted survivors, add to #{relative}/example/greeter.survivors.yml:"

    assert output =~ "- at: lib/example/greeter.ex:10:19\n  operator: guard_removal\n"
    assert output =~ "  sort: evaluation-gap\n  reason: TODO"
    assert output =~ "covenant.mutate: 1 problem(s) in the kill matrix"

    matrix = read_matrix("tmp/mutate-unsorted.json")
    assert matrix["summary"]["unsorted"] == 1
    assert [%{"sort" => nil}] = Enum.filter(matrix["survivors"], &(&1["id"] == "m007"))
  end

  @tag obligation: "covenant.mutate.I13"
  test "an annotation for a killed or a vanished mutant is stale or unmatched and fails the task",
       %{first: matrix} do
    {dir, relative} = contracts_copy("mutate-stale")
    killed = Enum.find(matrix["mutants"], &(&1["verdict"] == "killed"))
    file = Path.join(dir, "example/counter.survivors.yml")

    File.write!(
      file,
      File.read!(file) <>
        """
        - at: #{killed["at"]}
          operator: #{killed["operator"]}
          mutation: "`#{killed["from"]}` → `#{killed["to"]}`"
          sort: equivalent
          reason: Stale on purpose.
        - at: lib/example/counter.ex:999:1
          operator: integer_shift
          mutation: "`1` → `2`"
          sort: equivalent
          reason: Points at nothing.
        """
    )

    {output, status} =
      mutate("example.counter", ["--contracts", relative, "--out", "tmp/mutate-stale.json"])

    assert status == 1
    assert output =~ "#{relative}/example/counter.survivors.yml:"

    assert output =~
             "annotation for #{killed["at"]} #{killed["operator"]} (#{killed["id"]}) is stale: that mutant is now killed — delete it"

    assert output =~
             "annotation for lib/example/counter.ex:999:1 integer_shift matches no mutant; the code moved or the mutation changed — delete or update it"

    assert output =~ "2 problem(s) in the kill matrix"
  end

  @tag obligation: "covenant.mutate.I13"
  test "a survivors file that does not parse fails the task naming the file and line" do
    {dir, relative} = contracts_copy("mutate-broken-yaml")

    File.write!(Path.join(dir, "example/greeter.survivors.yml"), """
    - at: lib/example/greeter.ex:10:19
      operator: not_an_operator
      sort: equivalent
      reason: r
    """)

    {output, status} =
      mutate("example.greeter", ["--contracts", relative, "--out", "tmp/mutate-broken.json"])

    assert status == 1

    assert output =~
             "#{relative}/example/greeter.survivors.yml:1: annotation #1 has unknown `operator` `not_an_operator`"

    assert output =~ "could not be parsed"
    refute output =~ "m001"
  end

  defp verdicts(matrix), do: Map.new(matrix["mutants"], &{&1["id"], &1["verdict"]})

  @tag obligation: "covenant.mutate.I17"
  test "--fail-fast gives the verdicts of a full run, partial credit to its kills and no unique kills",
       %{first: full} do
    {output, 0} = mutate("example.counter", ["--fail-fast", "--out", "tmp/mutate-fast.json"])
    fast = read_matrix("tmp/mutate-fast.json")

    assert fast["fail_fast"] == true
    assert verdicts(fast) == verdicts(full)
    assert fast["survivors"] == full["survivors"]
    assert fast["problems"] == []

    killed = Enum.filter(fast["mutants"], &(&1["verdict"] == "killed"))
    assert killed != []
    assert Enum.all?(killed, &(&1["credit"] == "partial"))
    assert Enum.all?(fast["mutants"] -- killed, &(&1["credit"] == "exact"))
    assert fast["summary"]["partial"] == length(killed)

    # what stopped the run is one of the tests that fail against the mutant in a full run
    full_killers = Map.new(full["mutants"], &{&1["id"], &1["killed_by"]})

    for mutant <- killed do
      assert [_ | _] = mutant["killed_by"]
      assert mutant["killed_by"] -- full_killers[mutant["id"]] == []
    end

    assert Enum.all?(fast["obligations"], fn {_, stats} ->
             {stats["killed"], stats["unique"]} == {0, 0}
           end)

    assert Enum.all?(fast["tests"], fn {_, test} ->
             {test["kills"], test["unique_kills"]} == {0, 0} and test["mutation_blind"] in [nil]
           end)

    assert output =~
             "covenant.mutate: --fail-fast: verdicts are exact, kills carry partial credit"

    assert output =~ "  --fail-fast: #{length(killed)} kill(s) carry partial credit"
    assert output =~ "Mutation-blind tests: not judged"
  end

  @tag obligation: "covenant.mutate.I18"
  test "a progress line with the pace and the ETA follows every 25th mutant", %{
    first: matrix,
    output: output
  } do
    total = matrix["summary"]["mutants"]
    assert total > 25

    lines =
      Regex.scan(
        ~r/^progress: (\d+)\/(\d+) mutants \(.*%\), [\d.]+ mutants\/min, ETA .+$/m,
        output
      )

    assert Enum.map(lines, fn [_, done, of] ->
             {String.to_integer(done), String.to_integer(of)}
           end) ==
             for(done <- 25..total//25, done < total, do: {done, total})

    # the line comes right after the 25th mutant's own line
    assert output =~ ~r/\n  m025 [^\n]*\nprogress: 25\/#{total} mutants/
  end

  describe "a mutant that loops" do
    @spin_lib Path.join(@project, "lib/example/spin.ex")
    @spin_dir Path.join(@project, "tmp/spin")

    setup do
      File.mkdir_p!(Path.join(@spin_dir, "tests"))
      File.mkdir_p!(Path.join(@spin_dir, "contracts/example"))

      File.write!(@spin_lib, """
      defmodule Example.Spin do
        @moduledoc false

        # a count drains by twos to zero or one; a mutant that stops it draining may never end
        def drain(n) do
          if n > 1, do: drain(n - 2), else: n
        end
      end
      """)

      File.write!(Path.join(@spin_dir, "contracts/example/spin.obligations.md"), """
      ---
      modules: [Example.Spin]
      ---
      # example.spin

      ## Purpose

      Drains counts: the fixture of the mutants that never end.

      ## Obligations

      ### example.spin.I1 — A count drains to its parity
      - **scope:** `Example.Spin.drain/1`
      - **must:** return 1 for an odd count and 0 for an even one
      - **kind:** functional
      - **status:** active
      """)

      File.write!(Path.join(@spin_dir, "tests/spin_contract_test.exs"), """
      defmodule Example.SpinContractTest do
        use Covenant.Case, component: "example.spin", async: false

        @tag obligation: "example.spin.I1"
        test "one drains to one" do
          Process.sleep(210)
          assert Example.Spin.drain(1) == 1
        end

        @tag obligation: "example.spin.I1"
        test "five drains to one" do
          assert Example.Spin.drain(5) == 1
        end
      end
      """)

      on_exit(fn ->
        File.rm(@spin_lib)
        File.rm_rf(@spin_dir)
      end)

      :ok
    end

    defp spin(extra, out) do
      args = ["--contracts", "tmp/spin/contracts", "--test-path", "tmp/spin/tests", "--out", out]
      {output, status} = mutate("example.spin", args ++ extra)
      {output, status, read_matrix(out)}
    end

    defp spin_mutant(matrix, operator, from) do
      Enum.find(matrix["mutants"], &(&1["operator"] == operator and &1["from"] == from))
    end

    @tag obligation: ["covenant.mutate.I16", "covenant.mutate.I17"]
    test "the timeout is measured from the baseline, --timeout wins, and --fail-fast judges a timeout by the whole suite" do
      # the first test sleeps 210 ms, so the measured timeout is over five times that
      {output, 1, full} = spin([], "tmp/spin/full.json")
      assert full["timeout_ms"] >= 1050
      assert output =~ "per-test timeout #{full["timeout_ms"]} ms"

      one = "Example.SpinContractTest:test one drains to one"
      five = "Example.SpinContractTest:test five drains to one"

      # `n > 1` becomes `!(n > 1)`: drain(1) never ends, drain(5) answers 5
      negated = spin_mutant(full, "condition_negate", "if n > 1")

      assert {negated["verdict"], negated["killed_by"], negated["timeouts"]} ==
               {"killed", [five], [one]}

      # `n - 2` becomes `n + 2`: drain(5) never ends and nothing else fails, so it only times out
      grown = spin_mutant(full, "arithmetic_swap", "-")
      assert {grown["verdict"], grown["killed_by"], grown["timeouts"]} == {"timeout", [], [five]}

      {output, 1, fast} = spin(["--fail-fast", "--timeout", "300"], "tmp/spin/fast.json")
      assert fast["timeout_ms"] == 300
      assert output =~ "per-test timeout 300 ms"
      assert verdicts(fast) == verdicts(full)

      # the run that stopped on a timeout was run again in full: same killers, exact credit
      negated = spin_mutant(fast, "condition_negate", "if n > 1")

      assert {negated["verdict"], negated["killed_by"], negated["credit"]} ==
               {"killed", [five], "exact"}

      assert spin_mutant(fast, "arithmetic_swap", "-")["verdict"] == "timeout"

      # Exact credit lists the whole suite's killers. A transient timeout in
      # the 300 ms run can trigger the full retry even when the earlier run,
      # with a timeout over one second, had no timeout at that site.
      full_by_id = Map.new(full["mutants"], &{&1["id"], &1})
      killed = Enum.filter(fast["mutants"], &(&1["verdict"] == "killed"))

      for mutant <- killed, mutant["credit"] == "exact" do
        assert mutant["killed_by"] == full_by_id[mutant["id"]]["killed_by"]
      end

      for mutant <- killed, mutant["credit"] == "partial" do
        assert mutant["killed_by"] != []

        assert MapSet.subset?(
                 MapSet.new(mutant["killed_by"]),
                 MapSet.new(full_by_id[mutant["id"]]["killed_by"])
               )
      end

      assert Enum.any?(killed, &(&1["credit"] == "partial"))
    end
  end
end
