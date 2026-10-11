defmodule Covenant.StaticGeneratedContractTest do
  use Covenant.Case, component: "covenant.tasks", async: false

  alias Covenant.ContractBuilder

  @project ContractBuilder.fixture_project()

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I6"
  test "--static lists generated tests as skipped, uncredited, without failing", %{tmp_dir: dir} do
    contracts = ContractBuilder.copy_fixture_contracts(Path.join(dir, "contracts"))
    tests = Path.join(dir, "tests")
    File.cp_r!(Path.join(@project, "test/contract"), tests)

    File.write!(Path.join(tests, "generated_test.exs"), """
    defmodule GeneratedContractTest do
      use Covenant.Case, component: "example.greeter"

      for n <- [1, 2] do
        @tag obligation: "example.greeter.I1"
        test "generated \#{n}", do: :ok
      end
    end
    """)

    mix = System.find_executable("mix")

    {output, status} =
      System.cmd(
        mix,
        [
          "covenant.check",
          "--static",
          "--contracts",
          contracts,
          "--test-path",
          tests,
          "--root",
          dir
        ],
        cd: @project,
        env: [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert output =~ ~r/skipped \(need compiled code\):[^
]*, 1 generated test\(s\): [^
]*generated_test\.exs:6 test "generated/

    refute output =~ "defined inside"
  end
end
