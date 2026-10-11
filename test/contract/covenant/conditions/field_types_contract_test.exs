defmodule Covenant.ConditionsFieldTypesContractTest do
  use Covenant.Case, component: "covenant.conditions", async: true

  alias Covenant.Conditions
  alias Covenant.Conditions.Context
  alias Covenant.Contract.Condition

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "present.txt"), "")

    {:ok,
     ctx: %Context{
       root: dir,
       lock: %{"ecto" => "3.12.0"},
       env: %{},
       elixir_version: "1.19.6",
       otp_version: "28.5"
     }}
  end

  defp premise(check), do: %Condition{text: "premise", check: check}

  @tag obligation: "covenant.conditions.I1"
  test "a map or list in name, version or path is suspect with a message, never a crash", %{
    ctx: ctx
  } do
    for check <- [
          %{"kind" => "dep", "name" => "ecto", "version" => %{"gte" => "3.0.0"}},
          %{"kind" => "dep", "name" => %{"a" => 1}},
          %{"kind" => "env", "name" => ["A", "B"]},
          %{"kind" => "otp", "version" => %{"gte" => "27"}},
          %{"kind" => "elixir", "version" => %{"gte" => "1.15"}},
          %{"kind" => "file", "path" => %{"a" => "b"}}
        ] do
      assert {:suspect, message} = Conditions.evaluate(premise(check), ctx)
      assert message =~ "must be a single value"
    end
  end

  @tag obligation: "covenant.conditions.I8"
  test "an absolute file path inside the root is checked where it is", %{ctx: ctx, tmp_dir: dir} do
    check = fn path -> premise(%{"kind" => "file", "path" => path}) end

    assert {:ok, _} = Conditions.evaluate(check.(Path.join(dir, "present.txt")), ctx)
    assert {:suspect, message} = Conditions.evaluate(check.(Path.join(dir, "absent.txt")), ctx)
    assert message =~ "does not exist"
    assert {:ok, _} = Conditions.evaluate(check.("present.txt"), ctx)
  end
end
