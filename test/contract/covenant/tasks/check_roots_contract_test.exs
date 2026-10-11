defmodule Covenant.TasksRootContractTest do
  @moduledoc """
  The project root, the sibling layout switch and the results-directory edges of
  `mix covenant.check`: unit tests of `Covenant.root/0` and friends, and subprocess runs in the
  example fixture and in the two-app umbrella fixture.
  """

  use Covenant.Case, component: "covenant.tasks", async: false

  alias Covenant.ContractBuilder

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project ContractBuilder.fixture_project()
  @umbrella Path.expand("../../../fixtures/umbrella_project", __DIR__)

  defp mix(args, opts \\ []) do
    mix = System.find_executable("mix") || raise "mix not on PATH"

    env =
      [
        {"MIX_ENV", "dev"},
        {"COVENANT_RESULTS_DIR", nil},
        {"COVENANT_ROOT", nil},
        {"COVENANT_CONTRACTS_DIR", nil}
      ]

    System.cmd(mix, args, cd: opts[:cd] || @project, env: env, stderr_to_stdout: true)
  end

  setup do
    env = for k <- ~w(COVENANT_ROOT COVENANT_CONTRACTS_DIR), do: {k, System.get_env(k)}
    app = Application.get_all_env(:covenant)

    on_exit(fn ->
      for {k, v} <- env, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))

      for {key, _} <- Application.get_all_env(:covenant),
          do: Application.delete_env(:covenant, key)

      for {key, value} <- app, do: Application.put_env(:covenant, key, value)
    end)

    for {k, _} <- env, do: System.delete_env(k)
    for key <- [:root, :contracts_dir, :sibling_dir], do: Application.delete_env(:covenant, key)
    :ok
  end

  # -- the root -------------------------------------------------------------------

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "a Mix project nested in another repository is its own root, never the parent's",
       %{tmp_dir: dir} do
    dir = Path.expand(dir)
    child = Path.join(dir, "child")
    File.mkdir_p!(Path.join(dir, "contracts"))
    File.mkdir_p!(Path.join(child, "test/contract"))
    File.write!(Path.join(dir, "mix.exs"), "# parent")
    File.write!(Path.join(child, "mix.exs"), "# child")

    assert File.cd!(child, fn -> Covenant.root() end) == child
    assert File.cd!(Path.join(child, "test/contract"), fn -> Covenant.root() end) == child
    assert File.cd!(dir, fn -> Covenant.root() end) == dir
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "an umbrella app's root is the umbrella root, and a nested contracts_dir keeps the root",
       %{tmp_dir: dir} do
    dir = Path.expand(dir)
    File.mkdir_p!(Path.join(dir, "docs/contracts"))
    File.mkdir_p!(Path.join(dir, "apps/shop"))

    File.write!(
      Path.join(dir, "mix.exs"),
      "defmodule U do\n  def project, do: [apps_path: \"apps\"]\nend"
    )

    File.write!(Path.join(dir, "apps/shop/mix.exs"), "# shop")

    assert File.cd!(Path.join(dir, "apps/shop"), fn -> Covenant.root() end) == dir

    Application.put_env(:covenant, :contracts_dir, "docs/contracts")
    assert File.cd!(dir, fn -> Covenant.root() end) == dir
  end

  @tag obligation: "covenant.tasks.I9"
  test "COVENANT_CONTRACTS_DIR outranks the configured contracts_dir" do
    Application.put_env(:covenant, :contracts_dir, "configured")
    System.put_env("COVENANT_CONTRACTS_DIR", "/from/env")
    assert Covenant.contracts_dir() == "/from/env"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "sibling_dir: false (or nil) turns the sibling layout off", %{tmp_dir: dir} do
    assert Path.basename(Covenant.sibling_dir()) == "contract"

    for off <- [false, nil] do
      Application.put_env(:covenant, :sibling_dir, off)
      assert Covenant.sibling_dir() == nil
      assert Covenant.root() |> is_binary()
      assert {:ok, _} = Covenant.load(ContractBuilder.demo_contracts(dir))
    end
  end

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.check --contracts DIR keeps the root: a glob ceiling is counted from the project" do
    docs = Path.join(@project, "tmp/docs/contracts")
    File.rm_rf!(Path.dirname(docs))
    ContractBuilder.copy_fixture_contracts(docs)
    on_exit(fn -> File.rm_rf!(Path.join(@project, "tmp/docs")) end)
    File.mkdir_p!(Path.join(docs, "system"))

    File.write!(Path.join(docs, "system/scope.yml"), """
    - name: lib-files
      ceiling: 0
      counter: { kind: glob, pattern: "lib/**/*.ex" }
      why: Only the project root can count these.
    """)

    {output, status} = mix(["covenant.check", "--static", "--contracts", "tmp/docs/contracts"])
    assert status == 1, output
    assert output =~ ~r/scope ceiling `lib-files` exceeded: [1-9]\d* > 0/
  end

  # -- the umbrella ---------------------------------------------------------------

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.check run from one umbrella app runs every app's tests in that app's own VM" do
    {output, status} = mix(["covenant.check"], cd: Path.join(@umbrella, "apps/shop"))
    refute output =~ "UndefinedFunctionError", output
    assert status == 0, output
    assert output =~ ~r/total\s+3\/3\s+100\.0%/
    assert output =~ "covenant.check: the Contract holds"

    {output, status} = mix(["covenant.check", "--no-run"], cd: Path.join(@umbrella, "apps/other"))
    assert status == 0, output
    assert output =~ ~r/total\s+3\/3\s+100\.0%/
  end

  # -- the results directory -----------------------------------------------------

  @tag obligation: "covenant.tasks.I1"
  test "--results-dir naming a file is a clear error, not a File.Error" do
    file = Path.join(@project, "tmp/results-is-a-file")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "x")
    on_exit(fn -> File.rm(file) end)

    for args <- [["--no-run"], []] do
      {output, status} = mix(["covenant.check", "--results-dir", "tmp/results-is-a-file" | args])
      assert status == 1, output
      assert output =~ "results directory tmp/results-is-a-file is a file, not a directory"
      refute output =~ "File.Error"
    end
  end

  @tag obligation: "covenant.tasks.I1"
  test "a --test-path that matches nothing runs nothing and keeps the last results" do
    dir = Path.join(@project, "tmp/results-keep")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    kept =
      Covenant.Results.write(dir, "example", [
        %Covenant.Results.Test{
          module: "M",
          name: "t",
          obligations: ["example.counter.I1"],
          state: :passed
        }
      ])

    {output, _status} =
      mix(["covenant.check", "--test-path", "no/such/path", "--results-dir", "tmp/results-keep"])

    assert output =~ "no contract test paths found"
    assert File.exists?(kept)
  end

  @tag obligation: "covenant.tasks.I1"
  test "--no-run skips JSON files that are not Covenant results" do
    {_, 0} = mix(["covenant.check"])
    dir = Path.join(@project, "tmp/results-foreign")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.cp!(
      Path.join(@project, "_build/covenant/results/example.json"),
      Path.join(dir, "example.json")
    )

    File.write!(Path.join(dir, "package.json"), ~s({"name": "someone else's"}))

    {output, status} = mix(["covenant.check", "--no-run", "--results-dir", "tmp/results-foreign"])
    assert status == 0, output
    assert output =~ "the Contract holds"
  end
end
