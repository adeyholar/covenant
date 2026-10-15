defmodule Covenant.MutateSelectionE2EContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false

  alias Covenant.ContractBuilder

  @moduletag :e2e
  @moduletag timeout: 300_000
  @moduletag obligation: "covenant.mutate.I29"
  @project ContractBuilder.fixture_project()

  setup_all do
    out = "tmp/selection-full.json"
    {output, status} = mutate(["--out", out])
    assert status == 0, output
    matrix = read_matrix(out)

    ids =
      for verdict <- ["killed", "survived", "invalid"] do
        Enum.find(matrix["mutants"], &(&1["verdict"] == verdict))["id"]
      end

    {:ok, full: matrix, ids: ids}
  end

  test "selected IDs retain exact verdicts across slices and worker retirement", %{
    full: full,
    ids: ids
  } do
    out = "tmp/selection-exact.json"

    {output, status} =
      mutate([
        "--only",
        Enum.join(ids, ","),
        "--jobs",
        "2",
        "--max-mutants-per-worker",
        "1",
        "--out",
        out
      ])

    assert status == 0, output
    matrix = read_matrix(out)
    assert matrix["selection"]["kind"] == "focused"
    assert matrix["selection"]["available"] == full["summary"]["mutants"]
    assert matrix["selection"]["selected"] == 3
    assert matrix["selection"]["deferred_annotations"] > 0
    assert matrix["summary"]["mutants"] == 3
    selected = Enum.filter(full["mutants"], &(&1["id"] in ids))

    assert Enum.map(matrix["mutants"], &Map.take(&1, ~w(id verdict credit killed_by))) ==
             Enum.map(selected, &Map.take(&1, ~w(id verdict credit killed_by)))

    assert output =~ "full component verification is deferred"
    refute output =~ "every mutant is caught or sorted"
  end

  test "fail-fast keeps exact verdicts and partial kill credit", %{ids: ids} do
    out = "tmp/selection-fast.json"
    {output, status} = mutate(["--only", Enum.join(ids, ","), "--fail-fast", "--out", out])
    assert status == 0, output
    matrix = read_matrix(out)
    assert matrix["fail_fast"]
    assert matrix["summary"]["partial"] == 1
    assert Enum.find(matrix["mutants"], &(&1["verdict"] == "survived"))["credit"] == "exact"
    assert Enum.find(matrix["mutants"], &(&1["verdict"] == "invalid"))["killed_by"] == []
  end

  test "malformed and unknown selections fail before workers start" do
    for {id, message} <- [{"", "--only expects"}, {"m999999", "unknown mutant"}] do
      {output, status} = mutate(["--only", id])
      assert status != 0
      assert output =~ message
      refute output =~ "raw results:"
    end
  end

  test "selected stale entries and unknown sites still fail", %{full: full} do
    killed = Enum.find(full["mutants"], &(&1["verdict"] == "killed"))
    root = Path.join(@project, "tmp/selection-stale-contracts")
    File.rm_rf!(root)
    File.cp_r!(Path.join(@project, "contracts"), root)
    path = Path.join(root, "example/counter.survivors.yml")
    original = File.read!(path)
    mutant = Covenant.Mutate.Mutant.from_map(killed)

    for annotation <- [mutant, %{mutant | file: "lib/no_such_source.ex"}] do
      File.write!(path, original <> "\n" <> Covenant.Mutate.Survivors.template(annotation))

      {output, status} =
        mutate(["--only", killed["id"], "--contracts", root, "--out", "tmp/selection-stale.json"])

      assert status != 0
      assert output =~ "stale" or output =~ "matches no mutant"
    end
  end

  defp mutate(args) do
    System.cmd(System.find_executable("mix"), ["covenant.mutate", "example.counter" | args],
      cd: @project,
      env: [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}],
      stderr_to_stdout: true
    )
  end

  defp read_matrix(path), do: @project |> Path.join(path) |> File.read!() |> JSON.decode!()
end
