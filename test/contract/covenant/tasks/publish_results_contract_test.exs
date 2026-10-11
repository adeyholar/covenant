defmodule Covenant.TasksPublishResultsContractTest do
  use Covenant.Case, component: "covenant.tasks", async: false

  alias Covenant.ContractBuilder

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project ContractBuilder.fixture_project()

  @tag obligation: "covenant.tasks.I1"
  test "publishing results never overwrites a file that is not a Covenant results document" do
    reports = Path.join(@project, "tmp/reports-foreign")
    File.rm_rf!(reports)
    File.mkdir_p!(reports)
    foreign = Path.join(reports, "example.json")
    File.write!(foreign, ~s({"mine": true}))
    on_exit(fn -> File.rm_rf!(reports) end)

    env = [
      {"MIX_ENV", "dev"},
      {"COVENANT_RESULTS_DIR", nil},
      {"COVENANT_ROOT", nil},
      {"COVENANT_CONTRACTS_DIR", nil}
    ]

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["covenant.check", "--results-dir", "tmp/reports-foreign"],
        cd: @project,
        env: env,
        stderr_to_stdout: true
      )

    assert File.read!(foreign) == ~s({"mine": true})
    assert status != 0
    assert output =~ "refusing to publish results"
    assert output =~ "example.json"
    refute output =~ "covenant.check: the Contract holds"
    assert output =~ "wrote "
  end
end
