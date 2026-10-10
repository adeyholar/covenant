defmodule Shop.Cart do
  @moduledoc "The cart of the umbrella fixture (`shop.cart`)."

  @doc "The sum of the prices."
  @spec total([integer()]) :: integer()
  def total(prices), do: Enum.sum(prices)
end
