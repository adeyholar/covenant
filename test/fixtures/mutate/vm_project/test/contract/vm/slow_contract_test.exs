defmodule Vm.SlowContractTest do
  use Covenant.Case, component: "vm.slow", async: false

  # A teardown that is slower than the per-test timeout a run measures from the
  # test's own time (`test.time` leaves `on_exit` out, but ExUnit's timeout does not).
  setup do
    on_exit(fn -> Process.sleep(1_500) end)
  end

  @tag obligation: "vm.slow.I1"
  test "adds, and signs a positive number" do
    assert Vm.Slow.add(1, 2) == 3
    assert Vm.Slow.sign(5) == 1
  end
end
