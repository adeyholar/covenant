defmodule Vm.EchoContractTest do
  use Covenant.Case, component: "vm.echo", async: false

  @tag obligation: "vm.echo.I1"
  test "doubles" do
    assert Vm.Echo.double(3) == 6
  end

  @tag obligation: "vm.echo.I2"
  test "adds returns an integer" do
    assert is_integer(Vm.Echo.add(1))
  end
end
