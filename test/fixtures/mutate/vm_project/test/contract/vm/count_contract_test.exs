defmodule Vm.CountContractTest do
  use Covenant.Case, component: "vm.count", async: false

  @tag obligation: "vm.count.I1"
  test "next steps down by one" do
    assert Vm.Count.next(3) == 2
  end

  for i <- 1..8 do
    @tag obligation: "vm.count.I1"
    test "down terminates #{i}" do
      assert Vm.Count.down(3) == :ok
    end
  end
end
