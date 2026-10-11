defmodule Covenant.StaticWrapperContractTest do
  use Covenant.Case, component: "covenant.static", async: false

  alias Covenant.{Error, Static}

  @wrapped """
  defmodule Demo.WrappedTest do
    use Demo.ContractCase, component: "demo.widget"

    @tag obligation: "demo.widget.I1"
    test "holds", do: :ok
  end
  """

  defp with_wrappers(wrappers) do
    previous = Application.fetch_env(:covenant, :case_modules)
    Application.put_env(:covenant, :case_modules, wrappers)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:covenant, :case_modules, value)
        :error -> Application.delete_env(:covenant, :case_modules)
      end
    end)
  end

  @tag obligation: "covenant.static.I2"
  test "an unlisted wrapper is a problem naming the module and the literal form static mode reads" do
    assert %{modules: [], tests: [], problems: [problem]} =
             Static.scan_source(@wrapped, "test/contract/wrapped_test.exs")

    message = Error.format(problem)
    assert message =~ "test/contract/wrapped_test.exs:1"
    assert message =~ "Demo.WrappedTest"
    assert message =~ "static mode reads only"
    assert message =~ "use Covenant.Case"
    assert message =~ "case_modules"
  end

  @tag obligation: "covenant.static.I2"
  test "a wrapper listed in case_modules is read like use Covenant.Case" do
    with_wrappers([Demo.ContractCase])

    assert %{
             modules: [%{module: "Demo.WrappedTest", component: "demo.widget"}],
             tests: [%{obligations: ["demo.widget.I1"]}],
             problems: []
           } = Static.scan_source(@wrapped, "test/contract/wrapped_test.exs")
  end

  @tag obligation: "covenant.static.I2"
  test "a module without tags and without a readable use stays silent" do
    source = "defmodule Demo.HelperTest do\n  use ExUnit.Case\n  test \"x\", do: :ok\nend\n"
    assert %{modules: [], tests: [], problems: []} = Static.scan_source(source, "h_test.exs")
  end

  @tag :tmp_dir
  @tag obligation: "covenant.static.I7"
  test "expand follows the project's test_pattern", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "t/sub"))

    for f <- ["a_check.exs", "sub/b_check.exs", "c_test.exs"],
        do: File.write!(Path.join([dir, "t", f]), "")

    assert Enum.map(Static.expand([Path.join(dir, "t")]), &Path.relative_to(&1, dir)) ==
             ["t/c_test.exs"]

    Mix.Project.in_project(:pattern_demo, dir, [test_pattern: "*_check.exs"], fn _ ->
      assert Enum.map(Static.expand([Path.join(dir, "t")]), &Path.relative_to(&1, dir)) ==
               ["t/a_check.exs", "t/sub/b_check.exs"]

      assert Enum.map(Static.expand([Path.join(dir, "t/*.exs")]), &Path.relative_to(&1, dir)) ==
               ["t/a_check.exs"]
    end)
  end
end
