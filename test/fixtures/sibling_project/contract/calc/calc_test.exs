defmodule Calc.ContractTest do
  use Covenant.Case, async: true

  # Contract: calc/A1
  test "add sums its arguments" do
    assert Calc.add(2, 3) == 5
    assert Calc.add(-2, 3) == 1
  end

  # Contract: calc/A2
  test "clamp keeps a value that sits between the bounds" do
    assert Calc.clamp(5, 1, 10) == 5
  end

  # Contract: calc/A2
  test "clamp returns the nearer bound outside them" do
    assert Calc.clamp(-3, 1, 10) == 1
    assert Calc.clamp(42, 1, 10) == 10
  end
end
