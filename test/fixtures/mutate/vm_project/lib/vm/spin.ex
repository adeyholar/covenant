defmodule Vm.Spin do
  @moduledoc false

  def step(n), do: if(n >= 10, do: :done, else: {:more, n + 1})

  # a mutant that stops step/1 from reaching :done never returns
  def drain(n \\ 0) do
    case step(n) do
      :done -> :ok
      {:more, next} -> drain(next)
    end
  end
end
