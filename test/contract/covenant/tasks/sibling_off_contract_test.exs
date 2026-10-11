defmodule Covenant.TasksSiblingOffContractTest do
  @moduledoc """
  `config :covenant, sibling_dir: false` in a real project: the suite compiles and
  `mix covenant.check`, `covenant.conditions` and `covenant.regen` run.
  """

  use Covenant.Case, component: "covenant.tasks", async: false

  alias Covenant.ContractBuilder

  @moduletag :e2e
  @moduletag timeout: 600_000

  @project ContractBuilder.fixture_project()
  @repo Path.expand("../../../..", __DIR__)

  defp mix(args, dir) do
    mix = System.find_executable("mix") || raise "mix not on PATH"

    env = [
      {"MIX_ENV", "dev"},
      {"COVENANT_RESULTS_DIR", nil},
      {"COVENANT_ROOT", nil},
      {"COVENANT_CONTRACTS_DIR", nil}
    ]

    System.cmd(mix, args, cd: dir, env: env, stderr_to_stdout: true)
  end

  defp copy_project(dir) do
    for sub <- ~w(lib contracts test),
        do: File.cp_r!(Path.join(@project, sub), Path.join(dir, sub))

    File.cp!(Path.join(@project, "mix.lock"), Path.join(dir, "mix.lock"))

    mix_exs =
      @project
      |> Path.join("mix.exs")
      |> File.read!()
      |> String.replace(~s("../../../deps"), inspect(Path.join(@repo, "deps")))
      |> String.replace(~s(path: "../../.."), "path: #{inspect(@repo)}")

    File.write!(Path.join(dir, "mix.exs"), mix_exs)
    File.mkdir_p!(Path.join(dir, "config"))

    File.write!(
      Path.join(dir, "config/config.exs"),
      "import Config\nconfig :covenant, sibling_dir: false\n"
    )

    dir
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "sibling_dir: false in a project's config: check, conditions and regen all run",
       %{tmp_dir: dir} do
    dir = copy_project(Path.expand(dir))

    {output, status} = mix(["covenant.check"], dir)
    assert status == 0, output
    assert output =~ "the Contract holds"

    {output, status} = mix(["covenant.check", "--no-run", "--static"], dir)
    assert status == 0, output

    {output, status} = mix(["covenant.conditions"], dir)
    refute output =~ "FunctionClauseError", output
    refute output =~ "ArgumentError", output
    assert status in [0, 1], output

    {output, status} =
      mix(["covenant.regen", "example.counter", "--out", Path.join(dir, "out")], dir)

    refute output =~ "FunctionClauseError", output
    assert status == 0, output
  end
end
