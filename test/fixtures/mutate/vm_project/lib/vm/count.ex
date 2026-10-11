defmodule Vm.Count do
  @moduledoc false
  def next(n), do: n - 1
  def down(0), do: :ok
  def down(n), do: down(next(n))
end
