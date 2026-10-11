defmodule Other.ThingContractTest do
  use Covenant.Case, component: "other.thing", async: true

  @tag obligation: "other.thing.I1"
  test "the answer is 42" do
    assert Other.Thing.answer() == 42
  end
end
