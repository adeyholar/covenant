defmodule Vm.CompileContractTest do
  use Covenant.Case, component: "vm.compile", async: false

  @tag obligation: "vm.compile.I1"
  test "gives :ok" do
    assert Vm.Compile.x() == :ok
  end
end
