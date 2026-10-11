defmodule Vm.TouchContractTest do
  use Covenant.Case, component: "vm.touch", async: false

  @tag obligation: "vm.touch.I1"
  test "answers ok" do
    assert Vm.Touch.touch() == :ok
  end
end
