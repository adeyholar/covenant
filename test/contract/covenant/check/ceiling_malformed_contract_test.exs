defmodule Covenant.CeilingMalformedContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  alias Covenant.Contract.Ceiling

  @tag :tmp_dir
  @tag obligation: "covenant.check.I5"
  test "a malformed glob pattern is a `cannot be counted` error naming it, never a crash",
       %{tmp_dir: dir} do
    for pattern <- ["{a,b", "lib/{a,b/*.ex"] do
      ceiling = %Ceiling{
        name: "x",
        ceiling: 1,
        counter: {:glob, pattern},
        file: "system/scope.yml",
        line: 1
      }

      assert {:error, message} = Ceiling.count(ceiling, root: dir)
      assert message =~ "glob pattern `#{pattern}` is malformed"
    end
  end
end
