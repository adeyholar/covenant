defmodule Covenant.MutateCheckpointContractTest do
  use Covenant.Case, component: "covenant.mutate", async: true
  alias Covenant.Mutate.{Checkpoint, Mutant}
  @moduletag :tmp_dir
  @moduletag obligation: "covenant.mutate.I31"

  test "input changes include untracked support, configuration, dependencies, BEAMs, and tool settings",
       %{tmp_dir: root} do
    project = Path.join(root, "project")
    dep = Path.join(root, "dependency")

    for path <- ["mix.exs", "mix.lock", "test/support.exs", "config/config.exs"] do
      write(Path.join(project, path), "original")
    end

    write(Path.join(dep, "lib/value.ex"), "original")
    write(Path.join(dep, "ebin/value.beam"), "original beam")
    consolidation = Path.join(project, "_build/test/consolidated")
    write(Path.join(consolidation, "protocol.beam"), "original protocol")

    inputs = %{
      roots: [project, dep],
      files: [consolidation],
      options: %{seed: 0, tool: "v1", env_hash: "x"}
    }

    assert {:ok, original, _} = Checkpoint.fingerprint(inputs)

    for path <- ["test/support.exs", "config/config.exs", "mix.lock"] do
      full = Path.join(project, path)
      File.write!(full, "changed")
      assert {:ok, changed, _} = Checkpoint.fingerprint(inputs)
      refute changed == original
      File.write!(full, "original")
    end

    for path <- ["lib/value.ex", "ebin/value.beam"] do
      full = Path.join(dep, path)
      previous = File.read!(full)
      File.write!(full, "changed")
      assert {:ok, changed, _} = Checkpoint.fingerprint(inputs)
      refute changed == original
      File.write!(full, previous)
    end

    for key <- [:seed, :tool, :env_hash] do
      assert {:ok, changed, _} =
               Checkpoint.fingerprint(%{inputs | options: Map.put(inputs.options, key, "other")})

      refute changed == original
    end

    protocol = Path.join(consolidation, "protocol.beam")
    File.write!(protocol, "changed protocol")
    assert {:ok, changed, _} = Checkpoint.fingerprint(inputs)
    refute changed == original
    File.write!(protocol, "original protocol")

    write(Path.join(project, "tmp/generated.json"), "output")
    assert {:ok, ^original, _} = Checkpoint.fingerprint(inputs)
    write(Path.join(project, "test/new.exs"), "untracked")
    assert {:ok, changed, _} = Checkpoint.fingerprint(inputs)
    refute changed == original
  end

  test "equal protocol checker data is stable while metadata and executable changes invalidate it",
       %{tmp_dir: root} do
    {:ok, _, chunks} = :beam_lib.all_chunks(File.read!(:code.which(Checkpoint)))
    path = Path.join(root, "protocol.beam")
    inputs = %{roots: [path], files: [], options: %{}}
    checker = {:elixir_checker, %{exports: %{a: 1, b: 2}, mode: :protocol}}
    chunks = List.keystore(chunks, ~c"ExCk", 0, {~c"ExCk", :erlang.term_to_binary(checker)})

    fingerprints =
      for options <- [[], [:compressed]] do
        chunks =
          List.keystore(chunks, ~c"ExCk", 0, {~c"ExCk", :erlang.term_to_binary(checker, options)})

        {:ok, bytes} = :beam_lib.build_module(chunks)
        File.write!(path, bytes)
        assert {:ok, fingerprint, _} = Checkpoint.fingerprint(inputs)
        fingerprint
      end

    assert [original, original] = fingerprints

    {~c"Code", code} = List.keyfind(chunks, ~c"Code", 0)

    for changed <- [
          List.keystore(chunks, ~c"ExCk", 0, {~c"ExCk", :erlang.term_to_binary(:changed)}),
          List.keystore(chunks, ~c"Code", 0, {~c"Code", code <> "changed"})
        ] do
      {:ok, bytes} = :beam_lib.build_module(changed)
      File.write!(path, bytes)
      assert {:ok, fingerprint, _} = Checkpoint.fingerprint(inputs)
      refute fingerprint == original
    end
  end

  test "only sealed zero-exit groups resume; partial, stopped, corrupt and overlapping groups fail",
       %{tmp_dir: root} do
    source = Path.join(root, "source")
    write(source, "original")
    inputs = %{roots: [source], files: [], options: %{seed: 0}}
    directory = Path.join(root, "first")
    File.mkdir_p!(directory)
    assert {:ok, state, []} = Checkpoint.open(directory, inputs, nil)
    raw = raw()
    path = Path.join(directory, "raw-1.json")
    File.write!(path, Covenant.Mutate.encode_raw(raw, component: "example"))
    # Even a complete raw file has no credit until the parent seals it.
    second = Path.join(root, "second")
    File.mkdir_p!(second)
    assert {:ok, _, []} = Checkpoint.open(second, inputs, directory)
    assert :ok = Checkpoint.seal(state, path, raw)
    assert {:ok, _, [reused]} = Checkpoint.open(second, inputs, directory)
    assert Enum.map(reused.mutants, & &1.id) == ["m001"]

    for altered <- [
          %{raw | complete: false},
          %{raw | stopped: true},
          %{raw | mutants: [%{hd(raw.mutants) | verdict: :timeout}]}
        ] do
      refute Checkpoint.reusable?(altered)
    end

    assert Checkpoint.reusable?(%{raw | complete: false, retired: true})
    File.write!(path, "corrupt")
    assert {:error, message} = Checkpoint.open(second, inputs, directory)
    assert message =~ "corrupt or unverified"
    File.write!(path, Covenant.Mutate.encode_raw(raw, component: "example"))

    File.cp!(
      Path.join(directory, "verified-raw-1.json"),
      Path.join(directory, "verified-duplicate.json")
    )

    assert {:error, "checkpoint groups overlap"} = Checkpoint.open(second, inputs, directory)
    File.rm!(Path.join(directory, "verified-duplicate.json"))
    File.write!(source, "changed")
    assert {:error, message} = Checkpoint.open(second, inputs, directory)
    assert message =~ "inputs changed"
    assert {:error, _} = Checkpoint.seal(state, path, raw)
    assert Checkpoint.baselines([raw, raw]) == :ok
    assert {:error, _} = Checkpoint.baselines([raw, %{raw | tests: []}])
  end

  defp write(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp raw do
    mutant = %Mutant{
      id: "m001",
      file: "lib/value.ex",
      line: 1,
      column: 1,
      operator: :return_nil,
      from: "true",
      to: "nil",
      index: 1,
      verdict: :killed,
      killed_by: ["Example:test value"]
    }

    %{
      component: "example",
      only: [],
      modules: ["Example"],
      files: ["lib/value.ex"],
      complete: true,
      retired: false,
      stopped: false,
      all: 1,
      baseline_ms: 1,
      timeout_ms: 1000,
      tests: [
        %{
          key: "Example:test value",
          module: "Example",
          name: "test value",
          file: "test/value.exs",
          line: 1,
          obligations: ["example.I1"],
          mutation_blind: nil,
          outcome: :passed
        }
      ],
      mutants: [mutant]
    }
  end
end
