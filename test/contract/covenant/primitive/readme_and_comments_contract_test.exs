defmodule Covenant.ReadmeAndCommentsContractTest do
  use Covenant.Case, component: "covenant.primitive", async: true

  alias Covenant.Covers
  alias Covenant.Parser.Primitive

  @calc """
  # calc

  Small sums, stored in **S3** buckets, on **EC2** and encoded as **UTF8**.

  ## Obligations

  - **A1** Add returns the sum of its arguments.
  """

  defp write!(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  defp compile_in(dir, relative, name, tests) do
    file = Path.join(dir, relative)
    write!(Path.join([dir, "contract", "calc", "README.md"]), @calc)

    write!(file, """
    defmodule #{name} do
      use Covenant.Case, contracts: #{inspect(Path.join(dir, "contracts"))}, sibling: #{inspect(Path.join(dir, "contract"))}, register: false
    #{tests}
    end
    """)

    [{module, _} | _] = Code.compile_file(file)
    module
  end

  defp compile_error_in(dir, relative, name, tests) do
    assert_raise CompileError, fn -> compile_in(dir, relative, name, tests) end
  catch
    :error, %CompileError{} = error -> error
  end

  @tag obligation: "covenant.primitive.I1"
  test "bold words in prose are prose; only a list item opening with a bold id is a candidate" do
    assert {:ok, calc} = Primitive.parse_readme(@calc, "README.md", "calc")
    assert Enum.map(calc.obligations, & &1.id) == ["calc/A1"]

    bad = @calc <> "\n- **S3** stored here\n- **A2:** broken\n"
    assert {:error, [error]} = Primitive.parse_readme(bad, "README.md", "calc")
    assert error.message =~ "`- **A2:** broken` looks like an obligation"
  end

  @tag obligation: "covenant.primitive.I2"
  test "a covers function reference is satisfied by a public macro and creates no atom" do
    assert Covers.exists?({:function, "Covenant.Case", "__using__", 1}, [])
    assert Covers.exists?({:function, "Covenant.Error", "format", 1}, [])
    refute Covers.exists?({:function, "Covenant.Error", "nope", 1}, [])

    name = "Covenant.NoSuchModule#{System.unique_integer([:positive])}"
    refute Covers.exists?({:function, name, "f", 1}, [])
    refute Covers.exists?({:module, name}, [])
    refute Covers.exists?({:tree, name}, [name])

    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
  end

  @tag obligation: "covenant.primitive.I4"
  test "ids on a Contract comment are split on commas only" do
    lines = ["# Contract: calc/A1, calc/A2 and some prose ,  calc/A3 ", "test \"x\" do"]
    assert Primitive.comment_ids(lines, 2) == ["calc/A1", "calc/A2 and some prose", "calc/A3"]
    assert Primitive.claimed_ids(lines, 2) == ["calc/A1", "calc/A3"]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "trailing prose on a Contract comment is an unknown obligation, not bogus ids", %{
    tmp_dir: dir
  } do
    error =
      compile_error_in(dir, "contract/calc/a_test.exs", Covenant.RoundFour.Prose, """
        # Contract: calc/A1 adds numbers
        test "one", do: :ok
      """)

    assert error.description =~ "unknown obligation `calc/A1 adds numbers`"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "a Contract comment not directly above a test is a compile error at its line", %{
    tmp_dir: dir
  } do
    above_setup =
      compile_error_in(dir, "contract/calc/b_test.exs", Covenant.RoundFour.Setup, """
        # Contract: calc/A1
        setup do
          :ok
        end

        # Contract: calc/A1
        test "one", do: :ok
      """)

    assert above_setup.line == 3
    assert above_setup.description =~ "not directly above a test"

    above_defp =
      compile_error_in(dir, "contract/calc/c_test.exs", Covenant.RoundFour.Defp, """
        # Contract: calc/A1
        test "one", do: :ok

        # Contract: calc/A1
        defp helper, do: :ok
      """)

    assert above_defp.line == 6
  end
end
