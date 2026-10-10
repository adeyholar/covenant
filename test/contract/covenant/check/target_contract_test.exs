defmodule Covenant.TargetContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  alias Covenant.Target

  @tag obligation: "covenant.check.I4"
  test "parses functions, modules and files" do
    assert Target.parse("Example.Greeter.clamp/1") ==
             {:ok, {:function, Example.Greeter, :clamp, 1}}

    assert Target.parse("  Example.Greeter.valid?/2  ") ==
             {:ok, {:function, Example.Greeter, :valid?, 2}}

    assert Target.parse("Example.Greeter") == {:ok, {:module, Example.Greeter}}
    assert Target.parse("lib/example/greeter.ex") == {:ok, {:file, "lib/example/greeter.ex"}}
    assert Target.parse("greeter.ex") == {:ok, {:file, "greeter.ex"}}
    assert {:error, message} = Target.parse("the greeter")
    assert message =~ "cannot read target `the greeter`"
  end

  @tag obligation: "covenant.check.I4"
  test "exists? checks loaded code and the file system" do
    assert Target.exists?({:function, Example.Greeter, :clamp, 1}, ".")
    refute Target.exists?({:function, Example.Greeter, :clamp, 2}, ".")
    refute Target.exists?({:function, Example.Missing, :clamp, 1}, ".")
    assert Target.exists?({:function, Kernel, :def, 2}, ".")
    assert Target.exists?({:module, Covenant.Error}, ".")
    refute Target.exists?({:module, Covenant.Nope}, ".")
    assert Target.exists?({:file, "mix.exs"}, File.cwd!())
    refute Target.exists?({:file, "mix.nope"}, File.cwd!())
  end

  @tag obligation: "covenant.check.I4"
  test "describe renders the parsed target" do
    assert Target.describe({:function, Example.Greeter, :clamp, 1}) == "Example.Greeter.clamp/1"
    assert Target.describe({:module, Example.Greeter}) == "Example.Greeter"
    assert Target.describe({:file, "lib/x.ex"}) == "lib/x.ex"
  end
end
