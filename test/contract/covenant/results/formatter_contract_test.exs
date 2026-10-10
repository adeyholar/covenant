defmodule Covenant.FormatterContractTest do
  use Covenant.Case, component: "covenant.results", async: false

  alias Covenant.{Formatter, Results}

  defp ex_unit_test(name, tags, state) do
    %ExUnit.Test{
      name: name,
      case: Demo.ContractTest,
      module: Demo.ContractTest,
      state: state,
      tags: Map.merge(%{file: Path.expand("test/contract/demo_test.exs"), line: 7}, tags)
    }
  end

  @tag :tmp_dir
  @tag obligation: "covenant.results.I1"
  test "records tagged tests by outcome and writes <results_dir>/<app>.json at suite end", %{
    tmp_dir: dir
  } do
    # COVENANT_RESULTS_DIR outranks config and is set when this suite runs
    # under `mix covenant.check`, so pin the env var for the test's duration.
    previous = System.get_env("COVENANT_RESULTS_DIR")
    System.put_env("COVENANT_RESULTS_DIR", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("COVENANT_RESULTS_DIR", previous),
        else: System.delete_env("COVENANT_RESULTS_DIR")
    end)

    {:ok, state} = Formatter.init(seed: 1)

    events = [
      {:suite_started, %{}},
      {:module_started, %ExUnit.TestModule{name: Demo.ContractTest}},
      {:test_started,
       ex_unit_test(
         :"test a",
         %{obligation: "demo.widget.I1", covenant_component: "demo.widget"},
         nil
       )},
      {:test_finished,
       ex_unit_test(
         :"test a",
         %{obligation: "demo.widget.I1", covenant_component: "demo.widget"},
         nil
       )},
      {:test_finished,
       ex_unit_test(:"test b", %{obligation: ["demo.widget.I1", "demo.widget.I2"]}, {:failed, []})},
      {:test_finished,
       ex_unit_test(:"test c", %{obligation: "demo.widget.I2"}, {:skipped, "later"})},
      {:test_finished,
       ex_unit_test(:"test d", %{obligation: "demo.widget.I2"}, {:excluded, "tag"})},
      {:test_finished,
       ex_unit_test(:"test e", %{obligation: "demo.widget.I2"}, {:invalid, %ExUnit.TestModule{}})},
      {:test_finished, ex_unit_test(:"test untagged", %{}, nil)},
      {:module_finished, %ExUnit.TestModule{name: Demo.ContractTest}},
      {:suite_finished, %{run: 1, async: nil, load: nil}}
    ]

    Enum.reduce(events, state, fn event, state ->
      {:noreply, state} = Formatter.handle_cast(event, state)
      state
    end)

    assert {:ok, %Results{apps: [app], tests: tests}} = Results.read_dir(dir)
    assert app == Formatter.app_name()
    assert app == "covenant"

    assert Enum.map(tests, &{&1.name, &1.state}) == [
             {"test a", :passed},
             {"test b", :failed},
             {"test c", :skipped},
             {"test d", :excluded},
             {"test e", :invalid}
           ]

    assert Enum.map(tests, & &1.obligations) == [
             ["demo.widget.I1"],
             ["demo.widget.I1", "demo.widget.I2"],
             ["demo.widget.I2"],
             ["demo.widget.I2"],
             ["demo.widget.I2"]
           ]

    assert hd(tests).component == "demo.widget"
    assert hd(tests).file == "test/contract/demo_test.exs"
    assert hd(tests).line == 7
    assert hd(tests).module == "Demo.ContractTest"
  end

  @tag obligation: "covenant.results.I2"
  test "results_dir honours COVENANT_RESULTS_DIR over config" do
    previous = System.get_env("COVENANT_RESULTS_DIR")
    System.put_env("COVENANT_RESULTS_DIR", "/tmp/covenant-env-results")

    on_exit(fn ->
      if previous,
        do: System.put_env("COVENANT_RESULTS_DIR", previous),
        else: System.delete_env("COVENANT_RESULTS_DIR")
    end)

    assert Covenant.results_dir() == "/tmp/covenant-env-results"
  end

  @tag obligation: "covenant.results.I2"
  test "the default results dir sits next to the Mix build directory, independent of MIX_ENV" do
    # Neither the env var (set by a parent `mix covenant.check`) nor config may
    # be in force when asserting the default.
    previous_env = System.get_env("COVENANT_RESULTS_DIR")
    previous_config = Application.get_env(:covenant, :results_dir)
    System.delete_env("COVENANT_RESULTS_DIR")
    Application.delete_env(:covenant, :results_dir)

    on_exit(fn ->
      if previous_env, do: System.put_env("COVENANT_RESULTS_DIR", previous_env)
      if previous_config, do: Application.put_env(:covenant, :results_dir, previous_config)
    end)

    assert Covenant.results_dir() ==
             Path.join(Path.dirname(Mix.Project.build_path()), "covenant/results")

    assert String.ends_with?(Covenant.results_dir(), "_build/covenant/results")
  end
end
