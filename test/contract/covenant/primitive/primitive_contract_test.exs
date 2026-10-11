defmodule Covenant.PrimitiveContractTest do
  use Covenant.Case, component: "covenant.primitive", async: false

  alias Covenant.Contract
  alias Covenant.Contract.{Component, Obligation}
  alias Covenant.Covers
  alias Covenant.Mutate.{Mutant, Survivors}
  alias Covenant.Parser.Primitive

  @calc """
  # calc

  Small sums.

  ## Obligations

  - **A1** Add returns the sum of its arguments.
  - **A2** Clamp returns n when it sits between lo and hi.

  ```covers
  Calc
  ```
  """

  defp write!(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  defp sibling(dir, primitives) do
    root = Path.join(dir, "contract")
    for {name, text} <- primitives, do: write!(Path.join([root, name, "README.md"]), text)
    root
  end

  defp messages({:error, errors}),
    do: Enum.map(errors, &"#{Path.basename(&1.file)}:#{&1.line}: #{&1.message}")

  # -- I1 -----------------------------------------------------------------------

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I1"
  test "a primitive is a subdirectory with a README, and its obligations are its `- **A1**` lines",
       %{
         tmp_dir: dir
       } do
    root = sibling(dir, %{"calc" => @calc})
    write!(Path.join([root, "_helpers", "README.md"]), "# skipped\n\n- **A1** never read\n")
    write!(Path.join([root, ".hidden", "README.md"]), "# skipped\n")
    write!(Path.join([root, "support", "helper.exs"]), "# no README: helpers\n")

    {:ok, [%Component{} = calc]} = Primitive.parse_dir(root)

    assert %Component{id: "calc", name: "calc", app: "contract", form: :primitive} = calc
    assert calc.purpose == "Small sums."

    assert [
             %Obligation{
               id: "calc/A1",
               title: "Add returns the sum of its arguments.",
               component_id: "calc",
               kind: :functional,
               status: :active,
               line: 7
             },
             %Obligation{id: "calc/A2", line: 8}
           ] = calc.obligations

    assert Enum.all?(calc.obligations, &Obligation.testable?/1)
    assert Obligation.component_of("calc/A2") == "calc"
    assert Obligation.valid_id?("calc/A12")
    refute Obligation.valid_id?("calc/a1")
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I1"
  test "an obligation line inside a fence, a repeated id and a bad directory name are refused", %{
    tmp_dir: dir
  } do
    fenced = @calc <> "\n```markdown\n- **A3** an example, not an obligation\n```\n"
    {:ok, calc} = Primitive.parse_readme(fenced, "README.md", "calc")
    assert Enum.map(calc.obligations, & &1.id) == ["calc/A1", "calc/A2"]

    twice = @calc <> "\n- **A1** again\n"

    assert messages(Primitive.parse_readme(twice, "README.md", "calc")) == [
             "README.md:14: obligation `calc/A1` is declared twice (also at line 7)"
           ]

    root = sibling(dir, %{"BadName" => @calc})
    assert {:error, [error]} = Primitive.parse_dir(root)
    assert error.message =~ "primitive directory `BadName` must be snake_case"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I1"
  test "a Contract loads from the sibling directory alone, the contracts directory alone, or both",
       %{
         tmp_dir: dir
       } do
    root = sibling(dir, %{"calc" => @calc})
    contracts = Path.join(dir, "contracts")

    {:ok, only_sibling} = Contract.load(contracts, sibling: root)
    assert Contract.component_ids(only_sibling) == ["calc"]
    assert %Obligation{id: "calc/A1"} = Contract.obligation(only_sibling, "calc/A1")

    write!(Path.join(contracts, "billing/invoices.obligations.md"), """
    # billing.invoices

    ## Purpose

    Invoices.

    ### billing.invoices.I1 — Totals add up
    - **scope:** `Billing.total/1`
    - **must:** sum the lines
    - **kind:** functional
    - **status:** active
    """)

    {:ok, both} = Contract.load(contracts, sibling: root)
    assert Contract.component_ids(both) == ["billing.invoices", "calc"]

    {:ok, classic} = Contract.load(contracts)
    assert Contract.component_ids(classic) == ["billing.invoices"]

    assert {:error, [%{message: "contracts directory not found"}]} =
             Contract.load(Path.join(dir, "none"), sibling: Path.join(dir, "nothing"))
  end

  @tag obligation: "covenant.primitive.I1"
  test "a line holding a bold id that isn't `- **A1** text` is an error, never skipped" do
    bad =
      @calc <>
        """

        * **A3** a star bullet
        -  **A4** two spaces
        - **A5:** a colon inside
        - **A6**: a colon after
          - **A7** indented
        1. **A8** numbered
        - **a9** lowercase
        - **A10**
        """

    {:error, errors} = Primitive.parse_readme(bad, "README.md", "calc")
    assert Enum.map(errors, & &1.line) == Enum.to_list(14..21)

    assert Enum.all?(
             errors,
             &(&1.message =~
                 "looks like an obligation but is not one: write it as `- **A1** text`")
           )

    assert hd(errors).message =~ "`* **A3** a star bullet`"
  end

  @tag obligation: "covenant.primitive.I1"
  test "a fence that is never closed is an error in a README and in mutants.md" do
    unclosed = @calc <> "\n```covers\nCalc.add/2\n"

    assert messages(Primitive.parse_readme(unclosed, "README.md", "calc")) == [
             "README.md:14: the fence opened here with ``` is never closed"
           ]

    assert messages(
             Primitive.declarations(
               "## Kept\n\n~~~equivalent\nCalc.add/2: + -> -\n",
               "mutants.md"
             )
           ) == ["mutants.md:3: the fence opened here with ~~~ is never closed"]
  end

  # -- I2 -----------------------------------------------------------------------

  @tag obligation: "covenant.primitive.I2"
  test "a covers line is a module, a tree or a function, and nothing else" do
    assert Covers.parse("MyApp.Calc") == {:ok, {:module, "MyApp.Calc"}}
    assert Covers.parse("  MyApp.Calc.*  ") == {:ok, {:tree, "MyApp.Calc"}}

    assert Covers.parse("MyApp.Calc.add/2 # the sum") ==
             {:ok, {:function, "MyApp.Calc", "add", 2}}

    assert Covers.parse("MyApp.Calc.valid?/1") == {:ok, {:function, "MyApp.Calc", "valid?", 1}}
    assert Covers.parse("   # a comment") == :blank
    assert Covers.parse("") == :blank

    for bad <- ["my_app/calc", "MyApp.Calc.add", "MyApp.calc", "MyApp.Calc.add/x"] do
      assert {:error, message} = Covers.parse(bad)
      assert message =~ "is not a module (`MyApp.Calc`), a tree (`MyApp.Calc.*`) or a function"
    end

    readme = String.replace(@calc, "Calc\n```", "Calc\nCalc.*\nCalc.add/2\n\n```")
    {:ok, calc} = Primitive.parse_readme(readme, "README.md", "calc")

    assert Enum.map(calc.covers, &{&1.text, &1.line}) == [
             {"Calc", 11},
             {"Calc.*", 12},
             {"Calc.add/2", 13}
           ]

    broken = String.replace(@calc, "Calc\n```", "calc things\n```")

    assert messages(Primitive.parse_readme(broken, "README.md", "calc")) == [
             "README.md:11: covers line `calc things` is not a module (`MyApp.Calc`), a tree (`MyApp.Calc.*`) or a function (`MyApp.Calc.add/2`)"
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I2"
  test "covers blocks count only in README.md, and declaration blocks only in mutants.md", %{
    tmp_dir: dir
  } do
    misplaced = @calc <> "\n## Kept\n\n```equivalent\nCalc.add/2: + -> -\n```\n"

    assert messages(Primitive.parse_readme(misplaced, "README.md", "calc")) == [
             "README.md:16: an equivalent block belongs in mutants.md"
           ]

    root = sibling(dir, %{"calc" => @calc})
    write!(Path.join([root, "calc", "mutants.md"]), "# m\n\n## Why\n\n```covers\nCalc\n```\n")

    write!(
      Path.join([root, "calc", "notes.md"]),
      "# n\n\n## Why\n\n~~~~unpromised\nCalc.add/2: *\n~~~~\n"
    )

    assert messages(Primitive.parse_dir(root)) == [
             "mutants.md:5: a covers block belongs in README.md",
             "notes.md:5: an unpromised block belongs in mutants.md"
           ]

    # A fence closes only on the same character, at least as many times.
    fences =
      String.replace(
        @calc,
        "```covers\nCalc\n```",
        "~~~covers\nCalc\nCalc.add/2\n~~~~\n\n````markdown\n```\n- **A3** shown, not declared\n```\n````"
      )

    {:ok, calc} = Primitive.parse_readme(fences, "README.md", "calc")
    assert Enum.map(calc.covers, & &1.text) == ["Calc", "Calc.add/2"]
    assert Enum.map(calc.obligations, & &1.id) == ["calc/A1", "calc/A2"]
  end

  # -- I3 -----------------------------------------------------------------------

  defp covers(lines) do
    Enum.map(lines, fn line ->
      {:ok, ref} = Covers.parse(line)
      %Covers{ref: ref, text: line, file: "README.md", line: 1}
    end)
  end

  @tag obligation: "covenant.primitive.I3"
  test "the most specific reference owns the code" do
    primitives = %{
      "app" => covers(["MyApp.*"]),
      "calc" => covers(["MyApp.Calc.*"]),
      "core" => covers(["MyApp.Calc"]),
      "add" => covers(["MyApp.Calc.add/2"])
    }

    assert Covers.owners(primitives, "MyApp.Calc", "add/2") == ["add"]
    assert Covers.owners(primitives, "MyApp.Calc", "sub/2") == ["core"]
    assert Covers.owners(primitives, "MyApp.Calc", nil) == ["core"]
    assert Covers.owners(primitives, "MyApp.Calc.Round", "up/1") == ["calc"]
    assert Covers.owners(primitives, "MyApp.Billing", "total/1") == ["app"]
    assert Covers.owners(primitives, "MyApp", "start/2") == ["app"]
    assert Covers.owners(primitives, "Other", "x/0") == []
    assert Covers.owners(primitives, "MyApp.Calculator", "x/0") == ["app"]

    tied = %{"a" => covers(["MyApp.Calc"]), "b" => covers(["MyApp.Calc"])}
    assert Covers.owners(tied, "MyApp.Calc", "add/2") == ["a", "b"]

    function_only = %{"add" => covers(["MyApp.Calc.add/2"])}
    assert Covers.owners(function_only, "MyApp.Calc", nil) == []

    modules = ["MyApp", "MyApp.Calc", "MyApp.Calc.Round", "MyApp.Calculator"]
    assert Covers.expand("MyApp.Calc.*", modules) == ["MyApp.Calc", "MyApp.Calc.Round"]
    assert Covers.expand("MyApp.Calc", modules) == ["MyApp.Calc"]

    assert Covers.module_names(covers(["MyApp.Calc.*", "MyApp.Calc.add/2", "MyApp.Billing"])) ==
             ["MyApp.Billing", "MyApp.Calc", "MyApp.Calc.*"]
  end

  # -- I4 -----------------------------------------------------------------------

  @tag obligation: "covenant.primitive.I4"
  test "the ids come from the comment and attribute lines directly above a test" do
    lines =
      String.split(
        """
        defmodule X do
          # Contract: calc/A1

          # an ordinary comment
          # Contract: calc/A2, calc/A3
          #Contract: calc/A4
          @tag :slow
          test "x" do
          end
        end
        """,
        "\n"
      )

    assert Primitive.comment_ids(lines, 8) == ["calc/A2", "calc/A3", "calc/A4"]
    assert Primitive.comment_ids(lines, 4) == []
    assert Primitive.comment_ids(lines, 1) == []

    assert Primitive.primitive_of("/p/contract/calc/calc_test.exs", "/p/contract") == "calc"
    assert Primitive.primitive_of("/p/contract/calc/deep/x_test.exs", "/p/contract") == "calc"
    assert Primitive.primitive_of("/p/contract/test_helper.exs", "/p/contract") == nil
    assert Primitive.primitive_of("/p/test/contract/calc/x_test.exs", "/p/contract") == nil
  end

  defp compile_in(dir, relative, body, opts \\ "") do
    file = Path.join(dir, relative)
    contracts = Path.join(dir, "contracts")
    sibling = Path.join(dir, "contract")

    source = """
    defmodule #{body[:name]} do
      use Covenant.Case, contracts: #{inspect(contracts)}, sibling: #{inspect(sibling)}, register: false#{opts}
    #{body[:tests]}
    end
    """

    write!(file, source)
    [{module, _} | _] = Code.compile_file(file)
    module
  end

  defp compile_error_in(dir, relative, body, opts \\ "") do
    assert_raise CompileError, fn -> compile_in(dir, relative, body, opts) end
  catch
    :error, %CompileError{} = error -> error
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "Covenant.Case turns the comments into the test's obligation tag, merged with @tag", %{
    tmp_dir: dir
  } do
    sibling(dir, %{"calc" => @calc})

    module =
      compile_in(dir, "contract/calc/calc_test.exs",
        name: Covenant.PrimitiveTest.Commented,
        tests: """
          # Contract: calc/A1
          test "one", do: :ok

          # Contract: calc/A1, calc/A2
          test "two", do: :ok

          # Contract: calc/A1
          @tag obligation: "calc/A2"
          test "three", do: :ok

          @tag obligation: "calc/A2"
          test "four", do: :ok
        """
      )

    %ExUnit.TestModule{tests: tests, tags: tags} = module.__ex_unit__()
    assert tags.covenant_component == "calc"

    assert Enum.map(tests, &{&1.name, &1.tags.obligation}) == [
             {:"test one", ["calc/A1"]},
             {:"test two", ["calc/A1", "calc/A2"]},
             {:"test three", ["calc/A1", "calc/A2"]},
             {:"test four", ["calc/A2"]}
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "a test that names nothing, an unknown id or another primitive's id is a compile error", %{
    tmp_dir: dir
  } do
    sibling(dir, %{"calc" => @calc, "round" => String.replace(@calc, "# calc", "# round")})
    file = "contract/calc/calc_test.exs"

    error =
      compile_error_in(dir, file,
        name: Covenant.PrimitiveTest.Nothing,
        tests: """
          # Contract: calc/A1
          test "fine", do: :ok

          test "silent", do: :ok
        """
      )

    assert error.line == 6

    assert error.description =~
             "test silent names no obligation; put `# Contract: calc/<id>` on the line above it"

    error =
      compile_error_in(dir, file,
        name: Covenant.PrimitiveTest.Unknown,
        tests: """
          # Contract: calc/A9
          test "typo", do: :ok
        """
      )

    assert error.description =~
             "test typo is tagged with unknown obligation `calc/A9`; `calc` declares: calc/A1, calc/A2"

    error =
      compile_error_in(dir, file,
        name: Covenant.PrimitiveTest.Foreign,
        tests: """
          # Contract: round/A1
          test "elsewhere", do: :ok
        """
      )

    assert error.description =~ "`round/A1`, which belongs to component `round`"

    assert_raise ArgumentError,
                 ~r/names component "round", but the file sits in the sibling layout's `calc` primitive/,
                 fn ->
                   compile_in(
                     dir,
                     file,
                     [name: Covenant.PrimitiveTest.Mismatch, tests: ""],
                     ", component: \"round\""
                   )
                 end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "outside the sibling layout a Contract comment, and a module testing a primitive, are compile errors",
       %{tmp_dir: dir} do
    sibling(dir, %{"calc" => @calc})

    write!(Path.join(dir, "contracts/billing/invoices.obligations.md"), """
    # billing.invoices

    ## Purpose

    Invoices.

    ### billing.invoices.I1 — Totals add up
    - **scope:** `Billing.total/1`
    - **must:** sum the lines
    - **kind:** functional
    - **status:** active
    """)

    error =
      compile_error_in(
        dir,
        "test/contract/billing/invoices_contract_test.exs",
        [
          name: Covenant.PrimitiveTest.Commented.Classic,
          tests: """
            # Contract: calc/A1
            @tag obligation: "billing.invoices.I1"
            test "astray", do: :ok
          """
        ],
        ", component: \"billing.invoices\""
      )

    assert error.description =~
             "test astray has a `# Contract:` comment, which only Contract tests in the sibling layout"

    error =
      compile_error_in(
        dir,
        "test/contract/calc_test.exs",
        [
          name: Covenant.PrimitiveTest.Outside,
          tests: """
            @tag obligation: "calc/A1"
            test "astray", do: :ok
          """
        ],
        ", component: \"calc\""
      )

    assert error.description =~
             "Covenant.PrimitiveTest.Outside tests the primitive `calc`, whose Contract tests live beside its README"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I4"
  test "outside the sibling layout a prose `# Contract:` comment is only a comment", %{
    tmp_dir: dir
  } do
    sibling(dir, %{"calc" => @calc})

    write!(Path.join(dir, "contracts/billing/invoices.obligations.md"), """
    # billing.invoices

    ## Purpose

    Invoices.

    ### billing.invoices.I1 — Totals add up
    - **scope:** `Billing.total/1`
    - **must:** sum the lines
    - **kind:** functional
    - **status:** active
    """)

    tests = """
      # Contract: never negative
      @tag obligation: "billing.invoices.I1"
      test "prose", do: :ok
    """

    module =
      compile_in(
        dir,
        "test/contract/billing/prose_contract_test.exs",
        [name: Covenant.PrimitiveTest.Prose, tests: tests],
        ", component: \"billing.invoices\""
      )

    assert [%{tags: %{obligation: "billing.invoices.I1"}}] = module.__ex_unit__().tests

    file = Path.join(dir, "test/contract/billing/prose_contract_test.exs")
    scan = Covenant.Static.scan([file], sibling: Path.join(dir, "contract"))
    assert scan.problems == []
    assert Covenant.Check.strays([file], Path.join(dir, "contract")) == []

    claimed = write!(Path.join(dir, "test/claim_test.exs"), "# Contract: calc/A1\n")
    assert [%{line: 1}] = Covenant.Check.strays([claimed], Path.join(dir, "contract"))
  end

  # -- I5 -----------------------------------------------------------------------

  defp mutant(attrs) do
    struct!(
      %Mutant{
        file: "lib/calc.ex",
        line: 1,
        column: 1,
        operator: :comparison_swap,
        from: "<",
        to: "<=",
        index: 1
      },
      attrs
    )
  end

  @tag obligation: "covenant.primitive.I5"
  test "mutants.md declarations carry the heading and prose above them as their reason" do
    text = """
    # Mutants the calc Contract leaves alone

    ## At a bound, the bound is n

    When `n` equals `lo`, `<` and `<=`
    agree.

    ```equivalent
    Calc.clamp/3: < -> <=
    Calc.clamp/3: `>` → `>=`
    ```

    ## The step is open

    ```unpromised
    Calc.step/1: *
    Calc.parse/1: case _ -> -> (removed)
    ```
    """

    {:ok, [lt, gt, step, parse]} = Primitive.declarations(text, "mutants.md")

    assert %{unit: "Calc.clamp/3", from: "<", to: "<=", sort: "equivalent", line: 9} = lt
    assert lt.reason == "At a bound, the bound is n: When `n` equals `lo`, `<` and `<=` agree."
    assert %{from: ">", to: ">=", sort: "equivalent"} = gt

    assert %{
             unit: "Calc.step/1",
             from: nil,
             to: nil,
             sort: "unpromised",
             reason: "The step is open"
           } = step

    assert %{from: "case _ ->", to: "(removed)"} = parse

    clamp = mutant(module: "Calc", function: "clamp/3")
    assert Survivors.matches?(lt, clamp)
    refute Survivors.matches?(gt, clamp)
    refute Survivors.matches?(lt, %{clamp | function: "add/2"})

    assert Survivors.matches?(
             step,
             mutant(module: "Calc", function: "step/1", from: "1", to: "2")
           )

    refute Survivors.matches?(step, mutant(module: "Calc", function: "step/2"))

    assert Survivors.template(clamp, format: :md) == "Calc.clamp/3: < -> <="
    assert "unpromised" in Survivors.sorts()
  end

  @tag obligation: "covenant.primitive.I5"
  test "a block without a heading, an equivalent wildcard, a bad line and a repeat are errors" do
    text = """
    ```unpromised
    Calc.add/2: *
    ```

    ## Kept

    ```equivalent
    Calc.add/2: *
    Calc.add/2 + -> -
    Calc.add/2: + -> -
    Calc.add/2: `+` -> `-`
    ```
    """

    assert messages(Primitive.declarations(text, "mutants.md")) == [
             "mutants.md:1: the unpromised block has no heading above it to give its reason",
             "mutants.md:8: a wildcard can't be equivalent: equivalence is per mutant, so list them, or declare the unit unpromised",
             "mutants.md:9: `Calc.add/2 + -> -` is not `Module.function/arity: from -> to`",
             "mutants.md:11: declares what line 10 already declares"
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I5"
  test "a primitive's survivors file is the mutants.md beside its README", %{tmp_dir: dir} do
    root = sibling(dir, %{"calc" => @calc})
    {:ok, [calc]} = Primitive.parse_dir(root)

    path = Survivors.path("contracts", calc)
    assert path == Path.join([root, "calc", "mutants.md"])
    assert Survivors.load(path) == {:ok, []}

    write!(path, "## Kept\n\n```equivalent\nCalc.add/2: + -> -\n```\n")
    assert {:ok, [%{unit: "Calc.add/2", sort: "equivalent"}]} = Survivors.load(path)
  end

  @tag obligation: "covenant.primitive.I5"
  test "a declared change may hold arrows of its own, and `#k` names one of several" do
    text = """
    ## Kept

    ```unpromised
    Calc.map/2: f -> fn x -> x end
    Calc.add/2: `+` → `-` #2
    ```
    """

    {:ok, [fun, nth]} = Primitive.declarations(text, "mutants.md")

    assert %{unit: "Calc.map/2", change: "f -> fn x -> x end", occurrence: nil} = fun
    assert Primitive.change?(fun.change, "f", "fn x -> x end")

    assert Survivors.matches?(
             fun,
             mutant(module: "Calc", function: "map/2", from: "f", to: "fn x -> x end")
           )

    refute Survivors.matches?(fun, mutant(module: "Calc", function: "map/2", from: "f", to: "g"))

    assert %{change: "`+` → `-`", occurrence: 2, from: "+", to: "-"} = nth
    assert Primitive.change?(nth.change, "+", "-")

    assert messages(
             Primitive.declarations("## K\n\n```unpromised\nCalc.add/2: + #1\n```\n", "m.md")
           ) ==
             ["m.md:4: `Calc.add/2: + #1` is not `Unit: from -> to`"]
  end

  # -- I7 -----------------------------------------------------------------------

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I7"
  test "a pack lays a primitive out from the sibling layout's parent, and never replaces the project",
       %{tmp_dir: dir} do
    root = sibling(dir, %{"calc" => @calc})
    write!(Path.join([root, "calc", "calc_test.exs"]), "# the calc Contract tests\n")
    {:ok, contract} = Contract.load(Path.join(dir, "contracts"), sibling: root)

    elsewhere = Path.join(dir, "elsewhere")
    pack = Path.join(dir, "pack")

    {:ok, %{files: files}} =
      Covenant.Regen.write_pack(contract, "calc",
        out: pack,
        root: elsewhere,
        test_paths: []
      )

    relative = Enum.map(files, &Path.relative_to(&1, pack))
    assert "contract/calc/README.md" in relative
    assert "contract/calc/calc_test.exs" in relative
    assert File.read!(Path.join(pack, "PROMPT.md")) =~ "`contract/calc/README.md`"

    assert {:error, "refusing to write the pack to " <> _} =
             Covenant.Regen.write_pack(contract, "calc", out: dir, root: dir, test_paths: [])

    assert File.exists?(Path.join([root, "calc", "README.md"]))
  end

  # -- I8 -----------------------------------------------------------------------

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I8"
  test "the root is the nearest directory holding either layout, and a sibling needs a primitive",
       %{
         tmp_dir: dir
       } do
    project = Path.join(dir, "outer/inner")
    sibling(project, %{"calc" => @calc})
    File.mkdir_p!(Path.join(dir, "outer/contracts"))
    File.mkdir_p!(Path.join(project, "test/contract/calc"))

    previous = System.get_env("COVENANT_ROOT")
    System.delete_env("COVENANT_ROOT")
    on_exit(fn -> if previous, do: System.put_env("COVENANT_ROOT", previous) end)

    for cwd <- [project, Path.join(project, "contract/calc"), Path.join(project, "test")] do
      assert File.cd!(cwd, fn -> Covenant.root() end) == project
      assert File.cd!(cwd, fn -> Covenant.sibling_dir() end) == Path.join(project, "contract")
    end

    # test/contract has no primitive in it, so from the outer project it is never a sibling.
    assert File.cd!(Path.join(dir, "outer"), fn -> Covenant.root() end) == Path.join(dir, "outer")
  end
end
