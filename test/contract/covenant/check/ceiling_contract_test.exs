defmodule Covenant.CeilingContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  alias Covenant.ContractBuilder
  alias Covenant.Contract.Ceiling

  @path "system/scope.yml"

  @tag :tmp_dir
  @tag obligation: "covenant.check.I5"
  test "counts files matching a glob under the root", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{"lib/a.ex" => "", "lib/sub/b.ex" => "", "lib/c.exs" => ""})

    ceiling = %Ceiling{
      name: "x",
      ceiling: 1,
      counter: {:glob, "lib/**/*.ex"},
      file: @path,
      line: 1
    }

    assert Ceiling.count(ceiling, root: dir) == {:ok, 2}
  end

  @tag obligation: "covenant.check.I5"
  test "calls a module counter and reports an unusable one" do
    ok = %Ceiling{
      name: "x",
      ceiling: 1,
      counter: {:module, Example.Scope, :event_kinds},
      file: @path,
      line: 1
    }

    assert Ceiling.count(ok, []) == {:ok, 3}

    missing = %Ceiling{ok | counter: {:module, Example.Nope, :count}}
    assert {:error, "counter module Example.Nope is not loaded"} = Ceiling.count(missing, [])

    not_exported = %Ceiling{ok | counter: {:module, Example.Scope, :nope}}

    assert {:error, "counter Example.Scope.nope/0 is not exported"} =
             Ceiling.count(not_exported, [])

    bad_return = %Ceiling{ok | counter: {:module, Example.Scope, :not_a_count}}

    assert {:error, "counter Example.Scope.not_a_count/0 returned :nope"} =
             Ceiling.count(bad_return, [])
  end
end
