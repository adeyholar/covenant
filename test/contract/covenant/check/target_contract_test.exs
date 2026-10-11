defmodule Covenant.TargetContractTest do
  use Covenant.Case, component: "covenant.check", async: true

  alias Covenant.Target

  @tag obligation: "covenant.check.I4"
  test "parses functions, modules and files" do
    assert Target.parse("Example.Greeter.clamp/1") ==
             {:ok, {:function, Example.Greeter, "clamp", 1}}

    assert Target.parse("  Example.Greeter.valid?/2  ") ==
             {:ok, {:function, Example.Greeter, "valid?", 2}}

    assert Target.parse("Example.Greeter") == {:ok, {:module, Example.Greeter}}
    assert Target.parse("lib/example/greeter.ex") == {:ok, {:file, "lib/example/greeter.ex"}}
    assert Target.parse("greeter.ex") == {:ok, {:file, "greeter.ex"}}
    assert {:error, message} = Target.parse("the greeter")
    assert message =~ "cannot read target `the greeter`"
  end

  @tag obligation: "covenant.check.I4"
  test "exists? checks loaded code and the file system" do
    assert Target.exists?({:function, Example.Greeter, "clamp", 1}, ".")
    refute Target.exists?({:function, Example.Greeter, "clamp", 2}, ".")
    refute Target.exists?({:function, Example.Missing, "clamp", 1}, ".")
    assert Target.exists?({:function, Kernel, "def", 2}, ".")
    assert Target.exists?({:module, Covenant.Error}, ".")
    refute Target.exists?({:module, Covenant.Nope}, ".")
    assert Target.exists?({:file, "mix.exs"}, File.cwd!())
    refute Target.exists?({:file, "mix.nope"}, File.cwd!())
  end

  @tag obligation: "covenant.check.I4"
  test "a file target that leaves the project root is an error, never resolved" do
    for path <- ["../elsewhere/lib/thing.ex", "lib/../../thing.ex", "/etc/hosts", "~/x.ex"] do
      assert {:error, message} = Target.parse(path)
      assert message =~ "outside the project root"
    end

    assert {:ok, {:file, "lib/../mix.exs"}} = Target.parse("lib/../mix.exs")
    refute Target.exists?({:file, "../covenant"}, File.cwd!())
    refute Target.exists?({:file, Path.expand("mix.exs")}, Path.join(File.cwd!(), "lib"))
  end

  @tag obligation: "covenant.check.I4"
  test "target names never become atoms; an unknown module is not a crash" do
    n = System.unique_integer([:positive])
    module = "Covenant.Atomless#{n}"
    fun = "atomless_fun_#{n}"

    assert {:ok, {:function, name, ^fun, 1} = parsed} = Target.parse("#{module}.#{fun}/1")
    assert Target.describe(parsed) == "#{module}.#{fun}/1"
    refute Target.exists?(parsed, ".")
    assert {:ok, {:module, name2} = mod} = Target.parse(module)
    refute Target.exists?(mod, ".")
    assert name == module and name2 == module

    {:ok, {:function, Example.Greeter, ^fun, 1} = known} =
      Target.parse("Example.Greeter.#{fun}/1")

    refute Target.exists?(known, ".")
    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> module) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(fun) end
  end

  @tag obligation: "covenant.check.I4"
  test "describe renders the parsed target" do
    assert Target.describe({:function, Example.Greeter, "clamp", 1}) == "Example.Greeter.clamp/1"
    assert Target.describe({:module, Example.Greeter}) == "Example.Greeter"
    assert Target.describe({:file, "lib/x.ex"}) == "lib/x.ex"
  end
end
