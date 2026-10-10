defmodule Example.Greeter do
  @moduledoc "Test support: the fixture's greeter, so exception targets resolve inside Covenant's own suite."

  @doc "Clamps a count at zero."
  @spec clamp(integer()) :: non_neg_integer()
  def clamp(n) when n < 0, do: 0
  def clamp(n), do: n
end
