defmodule Covenant.PrimitiveSetextContractTest do
  use Covenant.Case, component: "covenant.primitive", async: true

  alias Covenant.Parser.Primitive

  defp ids(dir, readme) do
    File.mkdir_p!(Path.join(dir, "calc"))
    File.write!(Path.join(dir, "calc/README.md"), readme)
    {:ok, [component]} = Primitive.parse_dir(dir)
    Enum.map(component.obligations, & &1.id)
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I1"
  test "a `---` after an obligation list item is a thematic break, never a Setext heading",
       %{tmp_dir: dir} do
    readme = """
    # calc

    Small sums.

    ## Obligations

    - **A1** must reject zero
    ---
    - **A2** must add
    continued here
    ---
    - **A3** last
    ===
    """

    assert ids(dir, readme) == ["calc/A1", "calc/A2", "calc/A3"]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I1"
  test "a plain paragraph above `---` is still a Setext heading", %{tmp_dir: dir} do
    readme = "# calc\n\nSmall sums.\n\nOther\n---\n\n## Obligations\n\n- **A1** adds\n"
    assert ids(dir, readme) == ["calc/A1"]
  end
end

defmodule Covenant.PrimitiveModuleUnitContractTest do
  use Covenant.Case, component: "covenant.primitive", async: true

  alias Covenant.Parser.Primitive

  @tag obligation: "covenant.primitive.I5"
  test "a mutation outside any function is declared against the bare module" do
    text = """
    # calc

    ## Equivalent

    ```equivalent
    Calc: "hello" -> ""
    Calc.Inner: 1 -> 2 #2
    Calc.add/2: a -> b
    ```

    ## Whatever

    ```unpromised
    Calc: *
    ```
    """

    assert {:ok, [a, b, c, d]} = Primitive.declarations(text, "mutants.md")
    assert {a.unit, a.from, a.to, a.occurrence} == {"Calc", "\"hello\"", "\"\"", nil}
    assert {b.unit, b.from, b.to, b.occurrence} == {"Calc.Inner", "1", "2", 2}
    assert c.unit == "Calc.add/2"
    assert d.unit == "Calc" and d.change == nil
  end
end
