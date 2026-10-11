defmodule Vm.Early do
  @moduledoc false
  # a mutant that breaks inc/1 fails the first test, and loops in the second
  def inc(n), do: n + 1
end
