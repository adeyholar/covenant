defmodule Vm.EarlyContractTest do
  use Covenant.Case, component: "vm.early", async: false

  @flag {__MODULE__, :killed_first}

  setup_all do
    :persistent_term.put(@flag, false)
    :ok
  end

  # fails fast under a mutant; the flag is set whatever happens, so that the looping test
  # below never starts before this one has finished, whatever the order of the tests
  @tag obligation: "vm.early.I1"
  test "inc steps up by one" do
    try do
      assert Vm.Early.inc(1) == 2
    after
      :persistent_term.put(@flag, true)
    end
  end

  # never ends under a mutant that makes inc/1 step down, and is not bounded by the
  # per-test timeout
  @tag obligation: "vm.early.I1"
  @tag timeout: :infinity
  test "counting up reaches three" do
    wait = fn wait ->
      if :persistent_term.get(@flag),
        do: :ok,
        else:
          (
            Process.sleep(5)
            wait.(wait)
          )
    end

    wait.(wait)
    loop = fn loop, n -> if n >= 3, do: :ok, else: loop.(loop, Vm.Early.inc(n)) end
    assert loop.(loop, 0) == :ok
  end
end
