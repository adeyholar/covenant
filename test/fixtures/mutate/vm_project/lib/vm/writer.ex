defmodule Vm.Writer do
  @moduledoc false
  def step(n), do: if(n >= 10, do: :done, else: {:more, n + 1})

  # writes a progress file relative to the working directory on every step
  def drain(n \\ 0) do
    File.write!(Path.join("tmp", "progress"), Integer.to_string(n))

    case step(n) do
      :done -> :ok
      {:more, next} -> drain(next)
    end
  end
end
