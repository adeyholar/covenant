defmodule Calc do
  @moduledoc "Small sums: the sibling-layout fixture of Covenant's own test suite."

  @doc "The sum of `a` and `b`."
  @spec add(number(), number()) :: number()
  def add(a, b), do: a + b

  @doc "`n` when it sits between `lo` and `hi`, the nearer bound otherwise."
  @spec clamp(number(), number(), number()) :: number()
  def clamp(n, lo, hi) do
    cond do
      n < lo -> lo
      n > hi -> hi
      true -> n
    end
  end
end
