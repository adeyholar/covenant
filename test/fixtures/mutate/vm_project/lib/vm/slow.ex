defmodule Vm.Slow do
  @moduledoc false
  def add(a, b), do: a + b

  # the tests only try a positive number: `>=` to `>` survives
  def sign(n), do: if(n >= 0, do: 1, else: -1)
end
