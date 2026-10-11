defmodule Vm.HangContractTest do
  use Covenant.Case, component: "vm.hang", async: false

  # loops, outside ExUnit's per-test timeout, once a mutant has left its state behind
  setup_all do
    if :persistent_term.get({Vm.Hang, :state}, nil) == :set, do: Process.sleep(:infinity)
    :ok
  end

  @tag obligation: "vm.hang.I1"
  test "marks without a result" do
    assert Vm.Hang.mark(true) == :ok
  end
end
