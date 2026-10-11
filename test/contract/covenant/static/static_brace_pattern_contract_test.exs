defmodule Covenant.StaticBracePatternContractTest do
  use Covenant.Case, component: "covenant.static", async: false

  alias Covenant.Static

  defmodule BraceProject do
    def project, do: [app: :brace_probe, test_pattern: "*_{test,spec}.exs"]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.static.I7"
  test "a brace test_pattern is an alternation, not literal text", %{tmp_dir: dir} do
    for name <- ~w(a_test.exs b_spec.exs c_other.exs d_test.exs.bak),
        do: File.write!(Path.join(dir, name), "")

    File.write!(Path.join(dir, "{test,spec}.exs"), "")

    Mix.Project.push(BraceProject)
    on_exit(fn -> Mix.Project.pop() end)

    assert dir |> then(&Static.expand([&1])) |> Enum.map(&Path.basename/1) |> Enum.sort() ==
             ["a_test.exs", "b_spec.exs"]
  end
end
