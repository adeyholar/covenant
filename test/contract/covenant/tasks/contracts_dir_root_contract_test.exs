defmodule Covenant.TasksContractsDirRootContractTest do
  use Covenant.Case, component: "covenant.tasks", async: false

  alias Covenant.Contract.Ceiling

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
    for key <- [:root, :contracts_dir], do: Application.delete_env(:covenant, key)
    {:ok, project: File.cwd!()}
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "an absolute contracts_dir under docs/ does not move the root; a glob ceiling still counts",
       %{tmp_dir: dir, project: project} do
    contracts = Path.join([Path.expand(dir), "docs", "contracts"])
    File.mkdir_p!(contracts)
    Application.put_env(:covenant, :contracts_dir, contracts)

    assert Covenant.root() == project
    assert Covenant.contracts_dir() == contracts

    ceiling = %Ceiling{name: "x", ceiling: 1, counter: {:glob, "lib/**/*.ex"}, file: "s", line: 1}
    assert {:ok, count} = Ceiling.count(ceiling, root: Covenant.root())
    assert count > 1
  end

  @tag obligation: "covenant.tasks.I9"
  test "a relative contracts_dir that climbs with .. does not move the root above the project",
       %{project: project} do
    for setting <- ["../contracts", "../../shared/contracts", "docs/../../contracts"] do
      Application.put_env(:covenant, :contracts_dir, setting)
      assert Covenant.root() == project
    end

    Application.put_env(:covenant, :contracts_dir, "../contracts")
    assert Path.expand(Covenant.contracts_dir(), project) == Path.expand("../contracts", project)
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "a poncho project whose ../contracts exists keeps its own directory as the root",
       %{tmp_dir: dir} do
    dir = Path.expand(dir)
    project = Path.join(dir, "proj")
    File.mkdir_p!(Path.join(dir, "contracts"))
    File.mkdir_p!(project)
    File.write!(Path.join(project, "mix.exs"), "# poncho project")
    Application.put_env(:covenant, :contracts_dir, "../contracts")

    File.cd!(project, fn ->
      assert Covenant.root() == File.cwd!()
      assert Path.expand(Covenant.contracts_dir()) == Path.join(dir, "contracts")
    end)
  end

  @tag obligation: "covenant.tasks.I9"
  test "the explicit root still outranks the project directory" do
    Application.put_env(:covenant, :root, "/somewhere/else")
    Application.put_env(:covenant, :contracts_dir, "/repo/docs/contracts")
    assert Covenant.root() == "/somewhere/else"
  end
end
