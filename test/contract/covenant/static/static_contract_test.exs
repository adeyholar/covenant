defmodule Covenant.StaticContractTest do
  use Covenant.Case, component: "covenant.static", async: false

  alias Covenant.{Contract, ContractBuilder, Error, Static}
  alias Covenant.Results.Test

  defp scan(source), do: Static.scan_source(source, "test/contract/x_contract_test.exs")

  defp tags(source),
    do: source |> scan() |> Map.fetch!(:tests) |> Enum.map(&{&1.name, &1.obligations})

  defp messages(problems), do: Enum.map(problems, &Error.format/1)

  @tag obligation: "covenant.static.I1"
  test "reads string and list tags, @moduletag and @describetag, in ExUnit's precedence" do
    source = """
    defmodule Demo.WidgetContractTest do
      use Covenant.Case, component: "demo.widget", async: true

      @moduletag obligation: "demo.widget.I1"
      @moduletag :slow

      test "inherits the module tag" do
        assert true
      end

      @tag :tmp_dir
      @tag obligation: ["demo.widget.I2", "demo.widget.I3"]
      test "a list on @tag wins over @moduletag", %{tmp_dir: _} do
        assert true
      end

      describe "sizes" do
        @describetag obligation: "demo.widget.I4"

        test "inherits the describe tag", do: assert(true)

        @tag obligation: "demo.widget.I5"
        property "a property is a test too" do
          assert true
        end
      end

      for size <- [1, 2] do
        @tag obligation: "demo.widget.I6"
        test "size \#{size} inside a comprehension" do
          assert unquote(size) > 0
        end
      end

      test "the module tag again after describe" do
        assert true
      end
    end
    """

    assert tags(source) == [
             {"test inherits the module tag", ["demo.widget.I1"]},
             {"test a list on @tag wins over @moduletag", ["demo.widget.I2", "demo.widget.I3"]},
             {"test sizes inherits the describe tag", ["demo.widget.I4"]},
             {"property sizes a property is a test too", ["demo.widget.I5"]},
             {~S(test "size #{size} inside a comprehension"), ["demo.widget.I6"]},
             {"test the module tag again after describe", ["demo.widget.I1"]}
           ]

    %{tests: [first | _], problems: []} = scan(source)

    assert %Test{
             module: "Demo.WidgetContractTest",
             component: "demo.widget",
             file: "test/contract/x_contract_test.exs",
             line: 7,
             state: :tagged
           } = first
  end

  @tag obligation: "covenant.static.I1"
  test "within a level the last obligation tag wins, as in ExUnit" do
    source = """
    defmodule Demo.LastWinsContractTest do
      use Covenant.Case, component: "demo.widget"

      @tag obligation: "demo.widget.I1"
      @tag obligation: "demo.widget.I2"
      test "two tags" do
        assert true
      end
    end
    """

    assert tags(source) == [{"test two tags", ["demo.widget.I2"]}]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.static.I1"
  test "scan/2 expands directories and globs to *_test.exs files, relative to a root",
       %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "apps/a/test/contract/one_contract_test.exs" => """
      defmodule One do
        use Covenant.Case, component: "demo.widget"
        @tag obligation: "demo.widget.I1"
        test "one", do: :ok
      end
      """,
      "apps/b/test/contract/two_contract_test.exs" => """
      defmodule Two do
        use Covenant.Case, component: "demo.gadget"
        @tag obligation: "demo.gadget.I1"
        test "two", do: :ok
      end
      """,
      "apps/b/test/contract/notes.md" => "not a test"
    })

    scan = Static.scan([Path.join(dir, "apps/*/test/contract")], relative_to: dir)

    assert scan.files == [
             "apps/a/test/contract/one_contract_test.exs",
             "apps/b/test/contract/two_contract_test.exs"
           ]

    assert Enum.map(scan.modules, & &1.component) == ["demo.widget", "demo.gadget"]
    assert Enum.map(scan.tests, & &1.file) == scan.files
    assert scan.problems == []
  end

  @tag obligation: "covenant.static.I2"
  test "helper modules are ignored and nested modules are read on their own" do
    source = """
    defmodule Demo.Helpers do
      def test(_name), do: :not_a_test
    end

    defmodule Demo.OuterContractTest do
      use Covenant.Case, component: "demo.widget"

      defmodule World do
        def state, do: %{}
      end

      defmodule __MODULE__.InnerContractTest do
        use Covenant.Case, component: "demo.gadget"

        @tag obligation: "demo.gadget.I1"
        test "inner", do: :ok
      end

      @tag obligation: "demo.widget.I1"
      test "outer", do: :ok
    end
    """

    %{modules: modules, tests: tests, problems: []} = scan(source)

    assert Enum.map(modules, &{&1.module, &1.component}) == [
             {"Demo.OuterContractTest", "demo.widget"},
             {"Demo.OuterContractTest.InnerContractTest", "demo.gadget"}
           ]

    assert Enum.map(tests, &{&1.module, &1.name, &1.component}) == [
             {"Demo.OuterContractTest", "test outer", "demo.widget"},
             {"Demo.OuterContractTest.InnerContractTest", "test inner", "demo.gadget"}
           ]
  end

  @tag obligation: "covenant.static.I3"
  test "an unparsable file is a problem at its line, not a crash" do
    assert %{tests: [], modules: [], problems: [problem]} =
             scan("defmodule Broken do\n  test \"x\" do\nend\n")

    assert problem.file == "test/contract/x_contract_test.exs"
    assert is_integer(problem.line)
    assert problem.message =~ "cannot parse"
  end

  @tag obligation: "covenant.static.I3"
  test "non-literal tags and components, untagged and bodyless tests are problems at their lines" do
    source = """
    defmodule Demo.ProblemsContractTest do
      use Covenant.Case, component: "demo.widget"

      @id "demo.widget.I1"

      @tag obligation: @id
      test "attribute tag", do: :ok

      test "untagged", do: :ok

      @tag obligation: "demo.widget.I1"
      @tag obligation: "demo.widget.I2"
      test "twice", do: :ok

      @tag obligation: "demo.widget.I1"
      describe "group" do
        @tag obligation: "demo.widget.I1"
        test "inside", do: :ok
      end

      @tag obligation: "demo.widget.I1"
      test "pending"

      @tag obligation: "demo.widget.I1"
    end

    defmodule Demo.DynamicContractTest do
      use Covenant.Case, component: @component
    end
    """

    %{tests: tests, problems: problems} = scan(source)
    assert Enum.map(tests, & &1.name) == ["test twice", "test group inside"]

    assert messages(problems) == [
             "test/contract/x_contract_test.exs:6: @tag obligation: @id is not a literal string or list of strings; static mode reads only literals",
             "test/contract/x_contract_test.exs:9: test untagged has no obligation tag; every test in a Covenant.Case module must be tagged `@tag obligation: \"demo.widget.I<n>\"` (a list is allowed)",
             "test/contract/x_contract_test.exs:12: a second `@tag obligation:` replaces the first (ExUnit keeps only the last); tag once with a list",
             "test/contract/x_contract_test.exs:16: @tag before describe applies to no test (ExUnit rejects it); move it inside or use @describetag",
             "test/contract/x_contract_test.exs:22: test pending has no body; ExUnit fails it as not implemented and it proves nothing",
             "test/contract/x_contract_test.exs:24: @tag at the end of the module applies to no test",
             "test/contract/x_contract_test.exs:27: use Covenant.Case names component @component, which is not a literal string; static mode reads only literals"
           ]
  end

  @tag obligation: "covenant.static.I3"
  test "duplicate test names and literal names inside a comprehension are problems" do
    source = """
    defmodule Demo.DupContractTest do
      use Covenant.Case, component: "demo.widget"

      @tag obligation: "demo.widget.I1"
      test "same", do: :ok

      @tag obligation: "demo.widget.I1"
      test "same", do: :ok

      describe "group" do
        @tag obligation: "demo.widget.I1"
        test "same", do: :ok
      end

      for n <- [1, 2] do
        @tag obligation: "demo.widget.I1"
        test "fixed name", do: assert(unquote(n))

        @tag obligation: "demo.widget.I1"
        test "varying \#{n}", do: assert(unquote(n))

        describe "group \#{n}" do
          @tag obligation: "demo.widget.I1"
          test "same", do: assert(unquote(n))
        end
      end
    end
    """

    assert messages(scan(source).problems) == [
             "test/contract/x_contract_test.exs:8: test same is already defined in Demo.DupContractTest at line 5; ExUnit rejects the duplicate",
             "test/contract/x_contract_test.exs:17: test fixed name is defined inside a `for` with a literal name, so every iteration repeats it and ExUnit rejects the duplicate; interpolate the generator into the name"
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.static.I4"
  test "unknown components, other components' and retired obligations are problems; unknown ids are left to Check",
       %{tmp_dir: dir} do
    contract = Contract.load!(ContractBuilder.demo_contracts(Path.join(dir, "contracts")))

    source = """
    defmodule Demo.WidgetContractTest do
      use Covenant.Case, component: "demo.widget"

      @tag obligation: "demo.widget.I1"
      test "fine", do: :ok

      @tag obligation: "demo.gadget.I1"
      test "other component", do: :ok

      @tag obligation: "demo.widget.I2"
      test "retired", do: :ok

      @tag obligation: "demo.widget.I9"
      test "unknown id", do: :ok
    end

    defmodule Demo.NopeContractTest do
      use Covenant.Case, component: "demo.nope"

      @tag obligation: "demo.nope.I1"
      test "unknown component", do: :ok
    end
    """

    scan = Static.scan_source(source, "test/contract/demo_contract_test.exs")
    assert scan.problems == []

    assert Static.problems(contract, scan) |> messages() |> Enum.map(&String.replace(&1, dir, "")) ==
             [
               "test/contract/demo_contract_test.exs:17: Demo.NopeContractTest uses unknown component `demo.nope`; known components: demo.gadget, demo.widget",
               "test/contract/demo_contract_test.exs:8: test other component is tagged with `demo.gadget.I1`, which belongs to component `demo.gadget`, but this module tests `demo.widget`; move the test to that component's contract test file",
               "test/contract/demo_contract_test.exs:11: test retired is tagged with `demo.widget.I2`, which is retired (/contracts/demo/widget.intent.md:34); re-tag the test with the obligation that replaced it"
             ]
  end

  describe "Covenant.root/0 and Covenant.test_paths" do
    setup do
      env = System.get_env("COVENANT_ROOT")
      app = Application.get_all_env(:covenant)

      on_exit(fn ->
        if env, do: System.put_env("COVENANT_ROOT", env), else: System.delete_env("COVENANT_ROOT")

        for {key, _} <- Application.get_all_env(:covenant),
            do: Application.delete_env(:covenant, key)

        for {key, value} <- app, do: Application.put_env(:covenant, key, value)
      end)

      System.delete_env("COVENANT_ROOT")
      Application.delete_env(:covenant, :root)
      Application.delete_env(:covenant, :contracts_dir)
      :ok
    end

    @tag :tmp_dir
    @tag obligation: "covenant.static.I5"
    test "is the parent of the contracts directory from any directory under it", %{tmp_dir: dir} do
      dir = Path.expand(dir)
      File.mkdir_p!(Path.join(dir, "contracts"))
      deep = Path.join(dir, "apps/billing/test/contract")
      File.mkdir_p!(deep)

      roots =
        for cwd <- [dir, Path.join(dir, "apps/billing"), deep],
            do: File.cd!(cwd, fn -> Covenant.root() end)

      assert roots == [dir, dir, dir]

      Application.put_env(:covenant, :contracts_dir, "../../contracts")
      assert File.cd!(Path.join(dir, "apps/billing"), fn -> Covenant.root() end) == dir
    end

    @tag :tmp_dir
    @tag obligation: "covenant.static.I5"
    test "an absolute contracts_dir, config :root and COVENANT_ROOT win in that order", %{
      tmp_dir: dir
    } do
      dir = Path.expand(dir)
      Application.put_env(:covenant, :contracts_dir, Path.join(dir, "repo/contracts"))
      assert Covenant.root() == Path.join(dir, "repo")

      Application.put_env(:covenant, :root, Path.join(dir, "configured"))
      assert Covenant.root() == Path.join(dir, "configured")

      System.put_env("COVENANT_ROOT", Path.join(dir, "from-env"))
      assert Covenant.root() == Path.join(dir, "from-env")
    end

    @tag :tmp_dir
    @tag obligation: "covenant.static.I6"
    test "configured test paths resolve against the root, from any directory under it", %{
      tmp_dir: dir
    } do
      dir = Path.expand(dir)
      File.mkdir_p!(Path.join(dir, "contracts"))
      app = Path.join(dir, "apps/billing")
      File.mkdir_p!(app)

      Application.put_env(:covenant, :contracts_dir, Path.join(dir, "contracts"))

      Application.put_env(:covenant, :test_paths, [
        "apps/*/test/contract",
        "test/contract",
        "/elsewhere/contract"
      ])

      expected = [
        Path.join(dir, "apps/*/test/contract"),
        Path.join(dir, "test/contract"),
        "/elsewhere/contract"
      ]

      for cwd <- [dir, app] do
        assert File.cd!(cwd, fn -> Covenant.test_paths() end) == expected
        assert File.cd!(cwd, fn -> Covenant.test_paths([]) end) == expected
      end

      # a single string and the default are paths too
      Application.put_env(:covenant, :test_paths, "spec/contract")
      assert File.cd!(app, fn -> Covenant.test_paths() end) == [Path.join(dir, "spec/contract")]

      Application.delete_env(:covenant, :test_paths)
      assert File.cd!(app, fn -> Covenant.test_paths() end) == [Path.join(dir, "test/contract")]

      # a relative contracts_dir is found from the working directory upwards, as root/0 finds it
      Application.put_env(:covenant, :contracts_dir, "contracts")
      assert File.cd!(app, fn -> Covenant.test_paths() end) == [Path.join(dir, "test/contract")]

      # and COVENANT_ROOT moves them, like everything else under the root
      System.put_env("COVENANT_ROOT", Path.join(dir, "elsewhere"))

      assert File.cd!(app, fn -> Covenant.test_paths() end) ==
               [Path.join(dir, "elsewhere/test/contract")]
    end

    @tag :tmp_dir
    @tag obligation: "covenant.static.I6"
    test "typed test paths resolve against the working directory; none typed gives the configured ones",
         %{tmp_dir: dir} do
      dir = Path.expand(dir)
      File.mkdir_p!(Path.join(dir, "contracts"))
      app = Path.join(dir, "apps/billing")
      File.mkdir_p!(app)

      Application.put_env(:covenant, :contracts_dir, Path.join(dir, "contracts"))
      Application.put_env(:covenant, :test_paths, ["apps/*/test/contract"])

      assert File.cd!(app, fn -> Covenant.test_paths(["test/contract", "../*/test", "/abs/x"]) end) ==
               [
                 Path.join(app, "test/contract"),
                 Path.join(dir, "apps/*/test"),
                 "/abs/x"
               ]

      assert File.cd!(app, fn -> Covenant.test_paths([]) end) ==
               [Path.join(dir, "apps/*/test/contract")]
    end

    @tag :tmp_dir
    @tag obligation: "covenant.static.I5"
    test "falls back to the working directory when no contracts directory is found", %{
      tmp_dir: dir
    } do
      dir = Path.expand(dir)
      Application.put_env(:covenant, :contracts_dir, "no-such-contracts-dir-anywhere")
      assert File.cd!(dir, fn -> Covenant.root() end) == dir
    end
  end
end
