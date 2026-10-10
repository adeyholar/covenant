defmodule Shop.CatalogContractTest do
  use Covenant.Case, component: "shop.catalog", async: true

  @tag obligation: "shop.catalog.I1"
  test "an item has a price and an unknown one has none" do
    assert Shop.Catalog.price(:apple) == 3
    assert Shop.Catalog.price(:pear) == nil
  end
end
