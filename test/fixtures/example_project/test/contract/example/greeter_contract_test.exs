defmodule Example.GreeterContractTest do
  use Covenant.Case, component: "example.greeter", async: true

  alias Example.Greeter

  @tag obligation: "example.greeter.I1"
  test "greets by name and strangers without one" do
    assert Greeter.greet("Ada") == "Hello, Ada!"
    assert Greeter.greet("") == "Hello, stranger!"
    assert Greeter.greet(nil) == "Hello, stranger!"
  end
end
