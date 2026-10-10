defmodule Covenant.CaseContractTest do
  use Covenant.Case, component: "covenant.case", async: true

  alias Covenant.ContractBuilder

  @contracts ContractBuilder.fixture_contracts()
  @path "test/contract/example/fake_contract_test.exs"

  # Compiles a contract test module from source without registering it with
  # the running ExUnit server (register: false), returning the module.
  defp compile(name, body, opts \\ "") do
    source = """
    defmodule #{name} do
      use Covenant.Case, component: "example.counter", contracts: #{inspect(@contracts)}, register: false#{opts}
    #{body}
    end
    """

    [{module, _} | _] = Code.compile_string(source, @path)
    module
  end

  defp compile_error(name, body, opts \\ "") do
    assert_raise CompileError, fn -> compile(name, body, opts) end
  catch
    :error, %CompileError{} = error -> error
  end

  @tag obligation: ["covenant.case.I1", "covenant.case.I5"]
  test "a module with valid tags compiles, carries the module tags and accepts a list of obligations" do
    module =
      compile(Covenant.CaseTest.Valid, """
        @tag obligation: "example.counter.I1"
        test "one", do: :ok

        @tag obligation: ["example.counter.I2", "example.counter.I3"]
        test "two", do: :ok
      """)

    %ExUnit.TestModule{tests: tests, tags: tags} = module.__ex_unit__()
    assert tags.contract == true
    assert tags.covenant_component == "example.counter"

    assert Enum.map(tests, & &1.tags.obligation) == [
             "example.counter.I1",
             ["example.counter.I2", "example.counter.I3"]
           ]

    assert Enum.all?(tests, &(&1.tags.covenant_component == "example.counter"))
  end

  @tag obligation: ["covenant.case.I1", "covenant.case.I3"]
  test "an unknown obligation is a compile error at the test's line" do
    error =
      compile_error(Covenant.CaseTest.Unknown, """
        @tag obligation: "example.counter.I1"
        test "fine", do: :ok

        @tag obligation: "example.counter.I99"
        test "broken", do: :ok
      """)

    assert error.file == @path
    assert error.line == 7

    assert error.description =~
             "test broken is tagged with unknown obligation `example.counter.I99`"

    assert error.description =~
             "`example.counter` declares: example.counter.I1, example.counter.I2"
  end

  @tag obligation: ["covenant.case.I1", "covenant.case.I3"]
  test "a retired obligation is a compile error that points at the block" do
    error =
      compile_error(Covenant.CaseTest.Retired, """
        @tag obligation: "example.counter.I5"
        test "retired", do: :ok
      """)

    assert error.line == 4
    assert error.description =~ "`example.counter.I5`, which is retired"
    assert error.description =~ "counter.intent.md:78"
  end

  @tag obligation: ["covenant.case.I2", "covenant.case.I3"]
  test "an untagged test is a compile error" do
    error =
      compile_error(Covenant.CaseTest.Untagged, """
        test "plain", do: :ok
      """)

    assert error.line == 3
    assert error.description =~ "test plain has no obligation tag"
    assert error.description =~ ~s(@tag obligation: "example.counter.I<n>")
  end

  @tag obligation: ["covenant.case.I1", "covenant.case.I3"]
  test "an obligation of another component is a compile error" do
    error =
      compile_error(Covenant.CaseTest.Other, """
        @tag obligation: "example.greeter.I1"
        test "elsewhere", do: :ok
      """)

    assert error.line == 4

    assert error.description =~
             "`example.greeter.I1`, which belongs to component `example.greeter`"
  end

  @tag obligation: "covenant.case.I1"
  test "a tag that is not a string or list of strings is a compile error" do
    error =
      compile_error(Covenant.CaseTest.BadTag, """
        @tag obligation: :i1
        test "atom", do: :ok
      """)

    assert error.description =~ "has an invalid obligation tag :i1"
  end

  @tag obligation: "covenant.case.I4"
  test "an unknown component is a compile error listing the known ones" do
    source = """
    defmodule Covenant.CaseTest.NoComponent do
      use Covenant.Case, component: "example.nope", contracts: #{inspect(@contracts)}, register: false
    end
    """

    error = assert_raise CompileError, fn -> Code.compile_string(source, @path) end
    assert error.description =~ "unknown component `example.nope`"
    assert error.description =~ "example.counter, example.greeter, system"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.case.I4"
  test "a Contract that does not parse is a compile error listing its problems", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/widget.intent.md" =>
        String.replace(ContractBuilder.heavy_intent(), "- **must:** store the size\n", "")
    })

    source = """
    defmodule Covenant.CaseTest.BrokenContract do
      use Covenant.Case, component: "demo.widget", contracts: #{inspect(dir)}, register: false
    end
    """

    error = assert_raise CompileError, fn -> Code.compile_string(source, @path) end
    assert error.description =~ "the Contract has 1 problem(s)"
    assert error.description =~ "obligation `demo.widget.I1` is missing `must`"
  end

  @tag obligation: "covenant.case.I4"
  test "component: is required" do
    assert_raise ArgumentError, ~r/requires component:/, fn ->
      Code.compile_string(
        "defmodule Covenant.CaseTest.NoOpt do\n  use Covenant.Case, register: false\nend\n",
        @path
      )
    end
  end

  @tag obligation: ["covenant.case.I2", "covenant.case.I3"]
  test "describe blocks and setup are fine; every test inside still needs a tag" do
    error =
      compile_error(Covenant.CaseTest.Describe, """
        setup do
          :ok
        end

        describe "group" do
          @tag obligation: "example.counter.I1"
          test "tagged", do: :ok

          test "untagged", do: :ok
        end
      """)

    assert error.line == 11
    assert error.description =~ "test group untagged has no obligation tag"
  end
end
