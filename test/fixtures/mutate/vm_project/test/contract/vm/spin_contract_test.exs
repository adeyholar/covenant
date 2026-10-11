defmodule Vm.SpinContractTest do
  use Covenant.Case, component: "vm.spin", async: false

  # not bounded by ExUnit's per-test timeout
  setup_all do
    Vm.Spin.drain()
    :ok
  end

  @tag obligation: "vm.spin.I1"
  test "steps up to ten, then is done" do
    assert Vm.Spin.step(3) == {:more, 4}
    assert Vm.Spin.step(10) == :done
  end
end
