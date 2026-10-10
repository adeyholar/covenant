defmodule Shop.CartContractTest do
  use Covenant.Case, component: "shop.cart", async: true

  @tag obligation: "shop.cart.I1"
  test "the total is the sum of the prices" do
    assert Shop.Cart.total([1, 2, 3]) == 6
    assert Shop.Cart.total([]) == 0
  end
end
