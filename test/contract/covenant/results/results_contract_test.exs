defmodule Covenant.ResultsContractTest do
  use Covenant.Case, component: "covenant.results", async: true

  alias Covenant.Results
  alias Covenant.Results.Test, as: Entry
  alias Covenant.ResultsBuilder

  @tag :tmp_dir
  @tag obligation: "covenant.results.I2"
  test "writes one file per app and merges them back in file order", %{tmp_dir: dir} do
    %Results{tests: [a, b]} =
      ResultsBuilder.results(["demo.widget.I1", {"demo.widget.I2", :failed}])

    Results.write(dir, "web", [b])
    Results.write(dir, "core", [a])

    assert {:ok, %Results{apps: ["core", "web"], tests: [^a, ^b]}} = Results.read_dir(dir)
  end

  @tag :tmp_dir
  @tag obligation: "covenant.results.I3"
  test "an empty results dir is an error that says what to do", %{tmp_dir: dir} do
    assert {:error, message} = Results.read_dir(dir)
    assert message =~ "no contract test results"
    assert message =~ "Covenant.Formatter"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.results.I3"
  test "a corrupt file is reported with its path", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "x.json"), "{")
    assert {:error, message} = Results.read_dir(dir)
    assert message =~ "x.json: invalid JSON"

    File.write!(Path.join(dir, "x.json"), ~s({"covenant": "0", "app": "x", "tests": "no"}))
    assert {:error, message} = Results.read_dir(dir)
    assert message =~ "not a Covenant results file"
  end

  @tag obligation: "covenant.results.I4"
  test "groups tests by obligation, keeping multi-obligation tests under each" do
    results = ResultsBuilder.results(["demo.widget.I1", {"demo.widget.I2", :failed}])

    shared = %Entry{
      module: "M",
      name: "test both",
      obligations: ["demo.widget.I1", "demo.widget.I2"],
      state: :passed
    }

    grouped = Results.by_obligation(%{results | tests: results.tests ++ [shared]})

    assert Enum.map(grouped["demo.widget.I1"], & &1.name) == [
             "test demo.widget.I1 #1",
             "test both"
           ]

    assert Enum.map(grouped["demo.widget.I2"], & &1.name) == [
             "test demo.widget.I2 #2",
             "test both"
           ]
  end

  @tag obligation: "covenant.results.I3"
  test "decodes an unknown state as invalid" do
    assert {:ok, "a", [%Entry{state: :invalid}]} =
             (fn ->
                path =
                  Path.join(
                    System.tmp_dir!(),
                    "covenant-results-#{System.unique_integer([:positive])}.json"
                  )

                File.write!(
                  path,
                  ~s({"app":"a","tests":[{"module":"M","name":"t","obligations":["x.I1"],"state":"weird"}]})
                )

                on_exit(fn -> File.rm(path) end)
                Results.read_file(path)
              end).()
  end

  @tag :tmp_dir
  @tag obligation: "covenant.results.I3"
  test "a state that is not a test outcome (even a Covenant one, :tagged) decodes as invalid",
       %{tmp_dir: dir} do
    path = Path.join(dir, "a.json")

    File.write!(
      path,
      ~s({"covenant":"0","app":"a","tests":[{"module":"M","name":"t","obligations":["x.I1"],"state":"tagged"},{"module":"M","name":"u","obligations":["x.I1"],"state":"passed"}]})
    )

    assert {:ok, "a", [%Entry{state: :invalid}, %Entry{state: :passed}]} = Results.read_file(path)
  end

  @tag :tmp_dir
  @tag obligation: "covenant.results.I3"
  test "read_dir skips JSON files that are not Covenant results documents", %{tmp_dir: dir} do
    %Results{tests: [a]} = ResultsBuilder.results(["demo.widget.I1"])
    Results.write(dir, "core", [a])
    File.write!(Path.join(dir, "package.json"), ~s({"name": "someone else's"}))
    File.write!(Path.join(dir, "list.json"), "[1, 2]")

    assert {:ok, %Results{apps: ["core"], tests: [^a]}} = Results.read_dir(dir)

    File.rm!(Path.join(dir, "core.json"))
    assert {:error, message} = Results.read_dir(dir)
    assert message =~ "no contract test results"
  end
end
