defmodule Covenant.TasksContractTest do
  @moduledoc """
  Runs the mix tasks as subprocesses inside the fixture project, the way a
  user would. Slow on the first run (the fixture compiles its own `_build`).
  """

  use Covenant.Case, component: "covenant.tasks", async: false

  alias Covenant.ContractBuilder

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project ContractBuilder.fixture_project()

  defp mix(args, opts \\ []) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    env = [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}]
    {output, status} = System.cmd(mix, args, cd: @project, env: env, stderr_to_stdout: true)
    if opts[:print], do: IO.puts(output)
    {output, status}
  end

  setup_all do
    File.rm_rf!(Path.join(@project, "_build/covenant"))
    File.rm_rf!(Path.join(@project, "tmp"))
    :ok
  end

  @tag obligation: "covenant.tasks.I1"
  test "mix covenant.check runs the contract suite, prints coverage, writes coverage.json and exits 0" do
    {output, status} = mix(["covenant.check"])
    assert status == 0, output
    assert output =~ "covenant.check: running mix test test/contract"
    assert output =~ ~r/8 tests, 0 failures/
    assert output =~ ~r/example\.counter\s+6\/6\s+100\.0%/
    assert output =~ ~r/example\.greeter\s+1\/1\s+100\.0%/
    assert output =~ ~r/total\s+7\/7\s+100\.0%/
    assert output =~ "the Contract holds"

    coverage = Path.join(@project, "contracts/coverage.json") |> File.read!() |> JSON.decode!()
    assert coverage["totals"] == %{"active" => 7, "covered" => 7, "coverage" => 1.0}

    assert coverage["components"]["example.counter"]["obligations"]["example.counter.I5"][
             "status"
           ] == "retired"

    assert File.exists?(Path.join(@project, "_build/covenant/results/example.json"))
  end

  @tag obligation: "covenant.tasks.I2"
  test "mix covenant.check --no-run on a corrupted copy of the Contract fails with precise messages" do
    {_, 0} = mix(["covenant.check"])

    corrupt = Path.join(@project, "tmp/corrupt-contracts")
    ContractBuilder.copy_fixture_contracts(corrupt)

    intent = Path.join(corrupt, "example/counter.intent.md")

    File.write!(
      intent,
      File.read!(intent)
      |> String.replace(
        "- **must:** stop at zero when `by` exceeds the value, instead of going negative or raising\n",
        ""
      )
    )

    {output, status} = mix(["covenant.check", "--no-run", "--contracts", "tmp/corrupt-contracts"])
    assert status == 1

    assert output =~
             "tmp/corrupt-contracts/example/counter.intent.md:49: obligation `example.counter.I1` is missing `must`"

    assert output =~ "could not be parsed (1 problem(s))"

    ContractBuilder.copy_fixture_contracts(corrupt)
    greeter = Path.join(corrupt, "example/greeter.obligations.md")

    File.write!(
      greeter,
      File.read!(greeter)
      |> String.replace("`Example.Greeter.clamp/1`", "`Example.Greeter.squash/1`")
    )

    {output, status} = mix(["covenant.check", "--no-run", "--contracts", "tmp/corrupt-contracts"])
    assert status == 1

    assert output =~
             "greeter.obligations.md:16: exception `example.greeter.I2` targets Example.Greeter.squash/1, which no longer exists"

    assert output =~ "covenant.check: 1 problem(s) found in the Contract"
    assert output =~ ~r/total\s+7\/7\s+100\.0%/
  end

  @tag obligation: "covenant.tasks.I3"
  test "mix covenant.check fails when a contract test fails" do
    broken = Path.join(@project, "test/contract/example/broken_contract_test.exs")

    File.write!(broken, """
    defmodule Example.BrokenContractTest do
      use Covenant.Case, component: "example.greeter"

      @tag obligation: "example.greeter.I1"
      test "fails on purpose", do: assert Example.Greeter.greet("x") == "nope"
    end
    """)

    on_exit(fn -> File.rm(broken) end)

    {output, status} = mix(["covenant.check"])
    assert status == 1
    assert output =~ "1 failure"
    assert output =~ "test fails on purpose (obligation `example.greeter.I1`) failed"
    assert output =~ "contract suite failed (exit status 2)"
  end

  @tag obligation: "covenant.tasks.I4"
  test "mix covenant.conditions passes on the fixture and lists the checked premises" do
    {output, status} = mix(["covenant.conditions", "--verbose"])
    assert status == 0, output
    assert output =~ "ok Elixir is at least 1.18"
    assert output =~ "ok The contract tooling depends on yaml_elixir"
    assert output =~ "(not machine-checkable)"
    assert output =~ "5 record(s), 6 machine-checkable condition(s), 0 suspect record(s)"
  end

  @tag obligation: "covenant.tasks.I4"
  test "mix covenant.conditions fails on a suspect record" do
    suspect = Path.join(@project, "tmp/suspect-contracts")
    ContractBuilder.copy_fixture_contracts(suspect)
    records = Path.join(suspect, "example/counter.decisions.yml")

    File.write!(
      records,
      File.read!(records)
      |> String.replace(
        "check: { kind: dep, name: yaml_elixir, version: \"~> 2.12\" }",
        "check: { kind: dep, name: ecto }"
      )
    )

    {output, status} = mix(["covenant.conditions", "--contracts", "tmp/suspect-contracts"])
    assert status == 1
    assert output =~ "counter.decisions.yml:20: record `positive-steps` is suspect"
    assert output =~ "dependency `ecto` is not in mix.lock"
    assert output =~ "1 suspect record(s)"
  end

  @tag obligation: "covenant.tasks.I5"
  test "mix covenant.regen writes a pack and refuses an unknown component" do
    {output, status} = mix(["covenant.regen", "example.counter", "--out", "tmp/pack"])
    assert status == 0, output
    assert output =~ "covenant.regen: wrote 9 file(s) to tmp/pack"
    assert File.exists?(Path.join(@project, "tmp/pack/PROMPT.md"))
    assert File.exists?(Path.join(@project, "tmp/pack/stubs/lib/example/counter.ex"))

    assert File.exists?(
             Path.join(@project, "tmp/pack/test/contract/example/counter_contract_test.exs")
           )

    {output, status} = mix(["covenant.regen", "example.nope"])
    assert status == 1
    assert output =~ "unknown component `example.nope`"
  end

  @tag obligation: "covenant.tasks.I6"
  test "mix covenant.check --static reads the tests, runs none and writes only coverage.static.json" do
    coverage = Path.join(@project, "contracts/coverage.json")
    static = Path.join(@project, "contracts/coverage.static.json")
    File.rm(coverage)
    File.rm(static)
    on_exit(fn -> File.rm(static) end)

    {output, status} = mix(["covenant.check", "--static"])
    assert status == 0, output

    assert output =~
             "covenant.check --static: read 2 file(s), 2 contract test module(s), 8 tagged test(s) under test/contract; no test was compiled or run"

    refute output =~ "Running ExUnit"

    assert output =~
             "Static contract coverage (obligations with a tagged test / active obligations)"

    assert output =~ ~r/total\s+7\/7\s+100\.0%/

    assert output =~
             "skipped (need compiled code): 1 exception target(s), 1 module ceiling(s): counter-event-kinds, example.greeter.I2"

    assert output =~ "covenant.check: the Contract holds statically"
    refute File.exists?(coverage)

    assert %{"mode" => "static", "totals" => %{"covered" => 7}} =
             static |> File.read!() |> JSON.decode!()
  end

  @tag obligation: "covenant.tasks.I6"
  test "mix covenant.check --static passes tests that could not compile and fails bad tags precisely" do
    tests = Path.join(@project, "tmp/static-tests")
    File.mkdir_p!(tests)

    File.write!(Path.join(tests, "unbuilt_contract_test.exs"), """
    defmodule Example.UnbuiltContractTest do
      use Covenant.Case, component: "example.counter"

      @moduletag obligation: "example.counter.I1"

      test "calls code that does not exist" do
        assert Example.NotWrittenYet.call!(%{}) == :ok
      end

      @tag obligation: ["example.counter.I2", "example.counter.I3", "example.counter.I4"]
      test "more", do: Example.NotWrittenYet.more()

      @tag obligation: ["example.counter.I6", "example.counter.I7"]
      test "rest", do: Example.NotWrittenYet.rest()
    end

    defmodule Example.UnbuiltGreeterContractTest do
      use Covenant.Case, component: "example.greeter"

      @tag obligation: "example.greeter.I1"
      test "greets", do: Example.NotWrittenYet.greet()
    end
    """)

    {output, status} = mix(["covenant.check", "--static", "--test-path", "tmp/static-tests"])
    assert status == 0, output
    assert output =~ "read 1 file(s), 2 contract test module(s), 4 tagged test(s)"

    File.write!(Path.join(tests, "bad_contract_test.exs"), """
    defmodule Example.BadContractTest do
      use Covenant.Case, component: "example.counter"

      @tag obligation: "example.counter.I99"
      test "unknown", do: :ok

      @tag obligation: "example.counter.I5"
      test "retired", do: :ok

      test "untagged", do: :ok
    end
    """)

    {output, status} =
      mix(["covenant.check", "--static", "--test-path", "tmp/static-tests", "--root", "."])

    assert status == 1

    assert output =~
             "tmp/static-tests/bad_contract_test.exs:5: test unknown is tagged with unknown obligation `example.counter.I99`"

    assert output =~
             "tmp/static-tests/bad_contract_test.exs:8: test retired is tagged with `example.counter.I5`, which is retired"

    assert output =~
             "tmp/static-tests/bad_contract_test.exs:10: test untagged has no obligation tag"

    assert output =~ "covenant.check: 3 problem(s) found in the Contract (static)"
  end
end
