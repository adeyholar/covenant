defmodule Vm.PointContractTest do
  use Covenant.Case, component: "vm.point", async: false

  @tag obligation: "vm.point.I1"
  test "starts at the origin" do
    assert %Vm.Point{} == %Vm.Point{x: 0, y: 0}
  end
end
