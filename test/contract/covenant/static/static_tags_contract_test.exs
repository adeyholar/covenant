defmodule Covenant.StaticTagsContractTest do
  use Covenant.Case, component: "covenant.static", async: true

  alias Covenant.{Error, Static}

  defp scan(source), do: Static.scan_source(source, "x_test.exs")

  defp module_source(body) do
    """
    defmodule Demo.TagsContractTest do
      use Covenant.Case, component: "demo.widget"

    #{body}
    end
    """
  end

  defp tags(source),
    do: source |> scan() |> Map.fetch!(:tests) |> Enum.map(&{&1.name, &1.obligations})

  defp messages(source),
    do: source |> scan() |> Map.fetch!(:problems) |> Enum.map(&Error.format/1)

  @tag obligation: "covenant.static.I1"
  test "two obligation keys in one @tag: the last wins, as in ExUnit" do
    source =
      module_source("""
        @tag obligation: "demo.widget.I1", obligation: "demo.widget.I2"
        test "t", do: :ok
      """)

    assert tags(source) == [{"test t", ["demo.widget.I2"]}]
  end

  @tag obligation: "covenant.static.I1"
  test "a later @tag :obligation overrides an earlier string tag with `true`, which is a problem" do
    source =
      module_source("""
        @tag obligation: "demo.widget.I1"
        @tag :obligation
        test "t", do: :ok
      """)

    assert tags(source) == []

    assert Enum.any?(messages(source), &(&1 =~ "obligation: true is not a literal string"))
  end

  @tag obligation: "covenant.static.I3"
  test "two obligation keys in one @tag are a problem (the first is silently lost)" do
    source =
      module_source("""
        @tag obligation: "demo.widget.I1", obligation: "demo.widget.I2"
        test "t", do: :ok
      """)

    assert Enum.any?(messages(source), &(&1 =~ "a second `@tag obligation:` replaces the first"))
  end

  @tag obligation: "covenant.static.I3"
  test "tests inside for, Enum.each, if, unless, case and cond are not credited but reported" do
    source =
      module_source("""
        for n <- [1, 2] do
          @tag obligation: "demo.widget.I1"
          test "in for \#{n}", do: :ok
        end

        Enum.each([1], fn n ->
          @tag obligation: "demo.widget.I1"
          test "in each \#{n}", do: :ok
        end)

        if true do
          test "in if", do: :ok
        end

        unless false do
          test "in unless", do: :ok
        end

        case 1 do
          1 -> test("in case", do: :ok)
        end

        cond do
          true -> test("in cond", do: :ok)
        end
      """)

    assert tags(source) == []

    problems = messages(source)
    assert length(problems) == 6

    for construct <- ["for", "Enum.each", "if", "unless", "case", "cond"] do
      assert Enum.any?(problems, &(&1 =~ "inside `#{construct}`" and &1 =~ "compiled code"))
    end
  end

  @tag obligation: "covenant.static.I3"
  test "a literal test name inside for is not reported as a duplicate" do
    source =
      module_source("""
        for i <- [1] do
          test "fixed", do: assert(i)
        end
      """)

    problems = messages(source)
    assert [only] = problems
    refute only =~ "duplicate"
    assert only =~ "zero or many"
  end

  @tag obligation: "covenant.static.I1"
  test "a @tag before a for does not leak onto the next test" do
    source =
      module_source("""
        @tag obligation: "demo.widget.I1"
        for n <- [1, 2] do
          test "gen \#{n}", do: :ok
        end

        @tag obligation: "demo.widget.I2"
        test "after", do: :ok
      """)

    assert tags(source) == [{"test after", ["demo.widget.I2"]}]
  end

  @tag obligation: "covenant.static.I3"
  test "@describetag outside a describe is an error, inside is fine" do
    source =
      module_source("""
        @describetag :slow

        describe "g" do
          @describetag obligation: "demo.widget.I1"
          test "t", do: :ok
        end
      """)

    assert [problem] = messages(source)
    assert problem =~ "x_test.exs:4: @describetag outside a describe block"
    assert tags(source) == [{"test g t", ["demo.widget.I1"]}]
  end
end
