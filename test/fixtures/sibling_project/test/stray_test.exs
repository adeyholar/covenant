defmodule StrayTest do
  use ExUnit.Case

  # Contract: calc/A1
  test "an implementation test that claims an obligation" do
    assert Calc.add(1, 1) == 2
  end
end
