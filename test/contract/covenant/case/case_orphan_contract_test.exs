defmodule Covenant.CaseOrphanContractTest do
  use Covenant.Case, component: "covenant.primitive", async: true

  @calc """
  # calc

  Small sums.

  ## Obligations

  - **A1** Add returns the sum of its arguments.
  """

  defp compile(dir, relative, source) do
    file = Path.join(dir, relative)
    File.mkdir_p!(Path.join([dir, "contract", "calc"]))
    File.write!(Path.join([dir, "contract", "calc", "README.md"]), @calc)
    File.write!(file, source)
    Code.compile_file(file)
  end

  defp use_line(dir),
    do:
      "use Covenant.Case, contracts: #{inspect(Path.join(dir, "contracts"))}, " <>
        "sibling: #{inspect(Path.join(dir, "contract"))}, register: false"

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "the orphan comment check is scoped to its own module, and a second module's attached comments pass",
       %{tmp_dir: dir} do
    source = """
    defmodule Covenant.CaseOrphan.One do
      #{use_line(dir)}

      # Contract: calc/A1
      test "one", do: :ok
    end

    defmodule Covenant.CaseOrphan.Two do
      #{use_line(dir)}

      # Contract: calc/A1
      test "two", do: :ok
    end
    """

    assert [{_, _}, {_, _}] = compile(dir, "contract/calc/two_modules_test.exs", source)

    orphan =
      source
      |> String.replace(~s(test "two", do: :ok), ~s(defp two, do: :ok))
      |> String.replace("CaseOrphan.", "CaseOrphan.Orphan")

    assert_raise CompileError, ~r/not directly above a test/, fn ->
      compile(dir, "contract/calc/two_orphan_test.exs", orphan)
    end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "a `# Contract:` line inside a heredoc or a string is not a comment", %{tmp_dir: dir} do
    source = ~s'''
    defmodule Covenant.CaseOrphan.Heredoc do
      #{use_line(dir)}

      @sample """
      # Contract: calc/A1
      """

      # Contract: calc/A1
      test "one", do: assert(@sample =~ "Contract")
    end
    '''

    assert [{_, _}] = compile(dir, "contract/calc/heredoc_test.exs", source)
  end
end
