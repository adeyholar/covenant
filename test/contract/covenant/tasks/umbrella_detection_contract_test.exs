defmodule Covenant.TasksUmbrellaDetectionContractTest do
  @moduledoc "How a mix.exs's `apps_path:` is read: one parser behind `root/0` and `umbrella?/1`."

  use Covenant.Case, component: "covenant.tasks", async: false

  setup do
    env = Application.get_all_env(:covenant)
    on_exit(fn -> for {k, v} <- env, do: Application.put_env(:covenant, k, v) end)
    for k <- [:root, :contracts_dir], do: Application.delete_env(:covenant, k)
    prev = System.get_env("COVENANT_ROOT")
    System.delete_env("COVENANT_ROOT")
    on_exit(fn -> if prev, do: System.put_env("COVENANT_ROOT", prev) end)
    :ok
  end

  # Writes an umbrella whose root mix.exs holds `body`, and returns {root, app dir}.
  defp umbrella(dir, body, apps \\ "apps") do
    dir = Path.expand(dir)
    app = Path.join([dir, apps, "shop"])
    File.mkdir_p!(app)
    File.write!(Path.join(dir, "mix.exs"), "defmodule U do\n#{body}\nend\n")
    File.write!(Path.join(app, "mix.exs"), "# shop")
    {dir, app}
  end

  defp root_from(app), do: File.cd!(app, fn -> Covenant.root() end)

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "apps_path is read as a double-quoted, single-quoted or ~c string", %{tmp_dir: tmp} do
    for {literal, n} <- Enum.with_index([~S("apps"), ~S('apps'), ~S(~c"apps")]) do
      dir = Path.join(tmp, "u#{n}")
      {root, app} = umbrella(dir, "  def project, do: [apps_path: #{literal}]")
      assert root_from(app) == root, literal
      assert Covenant.umbrella?(root), literal
    end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "a literal apps_path naming another directory is not this app's umbrella", %{tmp_dir: tmp} do
    {root, app} = umbrella(tmp, ~S(  def project, do: [apps_path: "services"]))
    assert root_from(app) == app
    assert Covenant.umbrella?(root)
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "a computed apps_path counts only for a directory named apps", %{tmp_dir: tmp} do
    body = "  @apps \"apps\"\n  def project, do: [apps_path: @apps]"
    {root, app} = umbrella(Path.join(tmp, "a"), body)
    assert root_from(app) == root
    assert Covenant.umbrella?(root)

    {root, app} = umbrella(Path.join(tmp, "b"), body, "services")
    assert root_from(app) == app
    assert Covenant.umbrella?(root)
  end

  @tag :tmp_dir
  @tag obligation: "covenant.tasks.I9"
  test "a commented-out apps_path declares nothing", %{tmp_dir: tmp} do
    body = ~S(  # apps_path: "apps"
  def project, do: [app: :u]  # was apps_path: "apps")
    {root, app} = umbrella(tmp, body)
    refute Covenant.umbrella?(root)
    assert root_from(app) == app
  end
end
