defmodule Shop.Catalog do
  @moduledoc "The catalog of the umbrella fixture (`shop.catalog`)."

  @doc "The price of an item, nil for an unknown one."
  @spec price(atom()) :: integer() | nil
  def price(:apple), do: 3
  def price(_), do: nil
end
