defmodule Vm.Echo do
  @moduledoc false

  # a process that runs this module's code: purging the module kills it
  def loop(n) do
    receive do
      {:add, from, k} ->
        send(from, {:sum, n + k})
        loop(n + k)
    end
  end

  def add(k) do
    send(__MODULE__, {:add, self(), k})

    receive do
      {:sum, s} -> s
    after
      1000 -> :timeout
    end
  end

  def double(x), do: x * 2
end
