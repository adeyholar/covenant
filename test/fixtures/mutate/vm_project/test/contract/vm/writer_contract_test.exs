defmodule Vm.WriterContractTest do
  use Covenant.Case, component: "vm.writer", async: false

  setup_all do
    Vm.Writer.drain()
    :ok
  end

  @tag obligation: "vm.writer.I1"
  test "steps up to ten, then is done" do
    assert Vm.Writer.step(3) == {:more, 4}
    assert Vm.Writer.step(10) == :done
  end
end
