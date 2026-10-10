defmodule Covenant.JSONContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  @tag obligation: "covenant.check.I8"
  test "pretty-prints with sorted keys, deterministic across map orders" do
    a = %{"b" => [1, 2], "a" => %{"z" => nil, "y" => true}, "c" => "s"}
    b = %{"c" => "s", "a" => %{"y" => true, "z" => nil}, "b" => [1, 2]}

    assert IO.iodata_to_binary(Covenant.JSON.pretty(a)) ==
             IO.iodata_to_binary(Covenant.JSON.pretty(b))

    assert IO.iodata_to_binary(Covenant.JSON.pretty(a)) == """
           {
             "a": {
               "y": true,
               "z": null
             },
             "b": [
               1,
               2
             ],
             "c": "s"
           }\
           """
  end

  @tag obligation: "covenant.check.I8"
  test "empty containers, atoms and floats" do
    assert IO.iodata_to_binary(Covenant.JSON.pretty(%{list: [], map: %{}, ratio: 0.5, atom: :x})) ==
             "{\n  \"atom\": \"x\",\n  \"list\": [],\n  \"map\": {},\n  \"ratio\": 0.5\n}"
  end

  @tag obligation: "covenant.check.I8"
  test "round-trips through JSON.decode" do
    term = %{"components" => %{"a.b" => %{"coverage" => 1.0, "tests" => ["t"]}}}
    assert term |> Covenant.JSON.pretty() |> IO.iodata_to_binary() |> JSON.decode!() == term
  end
end
