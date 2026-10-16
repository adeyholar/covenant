defmodule Covenant.Mutate do
  @moduledoc """
  Mutation testing against the Contract: the kill matrix behind
  `mix covenant.mutate <component>`.

  The pieces, in pipeline order:

  * `Covenant.Mutate.Modules` — which modules implement the component
    (`--module`, front matter `modules:`, or derived from the Contract);
  * `Covenant.Mutate.Mutator` and `Covenant.Mutate.Operators` — the mutants
    of a source file, enumerated deterministically at the AST level;
  * `Covenant.Mutate.Runner` — one VM runs the component's contract tests
    per mutant, hot-swapping the module in memory;
  * `Covenant.Mutate.Survivors` — the annotations file for the survivor sort;
  * `Covenant.Mutate.Matrix` — kills credited to obligations, unique kills,
    mutation-blind tests, the readable table and the JSON.

  The Mix task runs the Runner in worker processes (`MIX_ENV=test`, one per
  `--jobs`), each writing a raw results file that `merge/1` combines. This
  module holds the plan and that raw format.
  """

  alias Covenant.Contract
  alias Covenant.Contract.Component
  alias Covenant.Mutate.{Modules, Mutant}
  alias Covenant.Regen

  @timeout_floor_ms 1_000
  @timeout_factor 5
  @progress_every 25
  @default_seed 0

  @doc """
  The default per-test timeout for mutant runs, in milliseconds: five times the
  slowest baseline test, and never under one second. `tests` are the baseline's
  finished tests (`Covenant.Mutate.Runner.entry/2`, each with its `:ms`).

  A flat ceiling is either too long (a mutant that loops forever holds the run
  for the whole ceiling, test after test) or too short for a slow suite; the
  baseline says how long this suite's tests take.
  """
  @spec default_timeout([%{required(:ms) => non_neg_integer()}]) :: pos_integer()
  def default_timeout(tests),
    do: Enum.max([@timeout_floor_ms | Enum.map(tests, &(@timeout_factor * &1.ms))])

  @doc """
  Whether a mutant belongs to the primitive `id`: the primitives' `covers`
  references own the code at the mutant's module and function by the most
  specific rule (`Covenant.Covers.owners/3`).
  """
  @spec covered_by?(Contract.t(), String.t(), Mutant.t()) :: boolean()
  def covered_by?(%Contract{} = contract, id, %Mutant{function: function} = mutant) do
    primitives =
      for {pid, %Component{form: :primitive, covers: covers}} <- contract.components,
          into: %{},
          do: {pid, covers}

    Enum.any?(Mutant.modules(mutant), &(id in Covenant.Covers.owners(primitives, &1, function)))
  end

  @doc "Whether a progress line is due after `done` of `total` mutants: every 25th, but not the last."
  @spec progress_due?(non_neg_integer(), non_neg_integer()) :: boolean()
  def progress_due?(done, total),
    do: done >= @progress_every and rem(done, @progress_every) == 0 and done < total

  @doc """
  The progress line after `done` of `total` mutants in `elapsed_ms`:
  `progress: 25/700 mutants (3.6%), 14.8 mutants/min, ETA 45m 36s`.
  """
  @spec progress_line(pos_integer(), pos_integer(), non_neg_integer()) :: String.t()
  def progress_line(done, total, elapsed_ms) do
    per_ms = done / max(elapsed_ms, 1)
    eta_ms = round((total - done) / per_ms)

    "progress: #{done}/#{total} mutants (#{:erlang.float_to_binary(done * 100 / total, decimals: 1)}%), " <>
      "#{:erlang.float_to_binary(per_ms * 60_000, decimals: 1)} mutants/min, ETA #{duration(eta_ms)}"
  end

  defp duration(ms) do
    seconds = div(ms + 500, 1000)
    {hours, rest} = {div(seconds, 3600), rem(seconds, 3600)}
    {minutes, seconds} = {div(rest, 60), rem(rest, 60)}

    cond do
      hours > 0 -> "#{hours}h #{String.pad_leading("#{minutes}", 2, "0")}m"
      minutes > 0 -> "#{minutes}m #{String.pad_leading("#{seconds}", 2, "0")}s"
      true -> "#{seconds}s"
    end
  end

  @doc "The default ExUnit seed for mutant runs (0: definition order)."
  @spec default_seed() :: non_neg_integer()
  def default_seed, do: @default_seed

  @doc "Where a component's kill matrix and raw worker results go by default."
  @spec default_dir(String.t()) :: Path.t()
  def default_dir(component_id), do: Path.join(["tmp", "covenant", "mutate", component_id])

  @typedoc "What the task resolved before any worker starts."
  @type plan :: %{
          component: Component.t(),
          names: [String.t()],
          source: Modules.source(),
          test_files: [Path.t()]
        }

  @doc """
  Resolves the component, its module names and its contract test files.
  Options: `:modules` (the `--module` flags), `:test_paths`, `:root`.
  """
  @spec plan(Contract.t(), String.t(), keyword()) :: {:ok, plan()} | {:error, String.t()}
  def plan(%Contract{} = contract, component_id, opts \\ []) do
    case Contract.component(contract, component_id) do
      nil ->
        {:error,
         "unknown component `#{component_id}`; known: #{Enum.join(Contract.component_ids(contract), ", ")}"}

      %Component{} = component ->
        root = Keyword.get(opts, :root, File.cwd!())
        test_paths = Keyword.get(opts, :test_paths, Covenant.test_paths())
        {source, names} = Modules.resolve(component, Keyword.get(opts, :modules, []))
        tests = Regen.find_tests(component, test_paths, root)

        cond do
          names == [] and component.form == :primitive ->
            {:error,
             "`#{component_id}` covers no code: add a ```covers block to #{component.file} or pass --module"}

          names == [] ->
            {:error,
             "`#{component_id}` names no implementation module: its Public surface and obligation " <>
               "scopes contain no `Module.function` code span. Declare `modules:` in the front matter " <>
               "of #{component.file} or pass --module"}

          tests == [] and component.form == :primitive ->
            {:error, "no Contract test (`*_test.exs`) beside #{component.file}"}

          tests == [] ->
            {:error,
             "no contract test file declares `use Covenant.Case, component: \"#{component_id}\"` " <>
               "under #{Enum.map_join(test_paths, ", ", &Path.relative_to(&1, root))}"}

          true ->
            {:ok, %{component: component, names: names, source: source, test_files: tests}}
        end
    end
  end

  # -- raw worker results -----------------------------------------------------

  @doc "Encodes one worker's `Covenant.Mutate.Runner` result as JSON."
  @spec encode_raw(map(), keyword()) :: iodata()
  def encode_raw(result, meta) do
    %{
      "covenant" => Covenant.version(),
      "component" => Keyword.fetch!(meta, :component),
      "slice" => Keyword.get(meta, :slice, "1/1"),
      "complete" => Keyword.get(meta, :complete, true),
      "stopped" => Keyword.get(meta, :stopped, false),
      "retired" => Keyword.get(meta, :retired, false),
      "modules" => Keyword.get(meta, :modules, []),
      "ignored" => Enum.map(Keyword.get(meta, :ignored, []), fn {name, why} -> [name, why] end),
      "files" => result.files,
      "all" => result.all,
      "baseline_ms" => result.baseline_ms,
      "timeout_ms" => result.timeout_ms,
      "tests" =>
        Enum.map(result.tests, fn test ->
          %{
            "key" => test.key,
            "module" => test.module,
            "name" => test.name,
            "file" => test.file,
            "line" => test.line,
            "obligations" => test.obligations,
            "mutation_blind" => test.mutation_blind,
            "outcome" => Atom.to_string(test.outcome)
          }
        end),
      "mutants" => Enum.map(result.mutants, &Mutant.to_map/1)
    }
    |> then(fn raw ->
      case Keyword.get(meta, :only, []) do
        [] -> raw
        ids -> Map.put(raw, "only", ids)
      end
    end)
    |> Covenant.JSON.pretty()
  end

  @doc "Reads a raw results file back."
  @spec decode_raw(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def decode_raw(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"mutants" => mutants, "tests" => tests} = raw} when is_list(mutants) <-
           JSON.decode(text),
         {:ok, mutants} <- decode_mutants(mutants, path) do
      {:ok,
       %{
         component: raw["component"],
         only: List.wrap(raw["only"]),
         complete: Map.get(raw, "complete", true),
         stopped: Map.get(raw, "stopped", false),
         retired: Map.get(raw, "retired", false),
         slice: raw["slice"],
         modules: List.wrap(raw["modules"]),
         ignored: Enum.map(List.wrap(raw["ignored"]), fn [name, why] -> {name, why} end),
         files: List.wrap(raw["files"]),
         all: raw["all"] || length(mutants),
         baseline_ms: raw["baseline_ms"] || 0,
         timeout_ms: raw["timeout_ms"] || 0,
         tests: Enum.map(tests, &decode_test/1),
         mutants: mutants
       }}
    else
      {:ok, _} -> {:error, "#{path}: not a covenant.mutate results file"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, reason} -> {:error, "#{path}: invalid JSON: #{inspect(reason)}"}
    end
  end

  defp decode_mutants(maps, path) do
    Enum.reduce_while(maps, {:ok, []}, fn map, {:ok, acc} ->
      case Mutant.decode(map) do
        {:ok, mutant} -> {:cont, {:ok, [mutant | acc]}}
        {:error, message} -> {:halt, {:error, "#{path}: #{message}"}}
      end
    end)
    |> case do
      {:ok, mutants} -> {:ok, Enum.reverse(mutants)}
      error -> error
    end
  end

  defp decode_test(map) do
    %{
      key: map["key"],
      module: map["module"],
      name: map["name"],
      file: map["file"],
      line: map["line"],
      obligations: List.wrap(map["obligations"]),
      mutation_blind: map["mutation_blind"],
      outcome: outcome(map["outcome"])
    }
  end

  @outcomes %{
    "passed" => :passed,
    "failed" => :failed,
    "timeout" => :timeout,
    "invalid" => :invalid,
    "skipped" => :skipped,
    "excluded" => :excluded
  }

  defp outcome(name), do: Map.get(@outcomes, name, :invalid)

  @doc """
  Merges the raw results of every worker: tests, modules and files come from
  the first (every worker sees the same suite), mutants are concatenated and
  sorted by id, and `timeout_ms` is the largest timeout any worker used (each
  measures its own baseline).
  """
  @spec merge([map()]) :: {:ok, map()} | {:error, String.t()}
  def merge([]), do: {:error, "no worker results to merge"}

  def merge([first | _] = raws) do
    mutants = raws |> Enum.flat_map(& &1.mutants) |> Enum.sort_by(& &1.id)
    ids = Enum.map(mutants, & &1.id)

    cond do
      Enum.any?(raws, &(Map.get(&1, :only, []) != Map.get(first, :only, []))) ->
        {:error, "worker results have different mutant selections"}

      ids != Enum.uniq(ids) ->
        {:error, "worker results overlap (the same mutant was run twice)"}

      length(ids) != first.all ->
        {:error,
         "worker results are incomplete: #{length(ids)} of #{first.all} mutants have a verdict"}

      true ->
        {:ok,
         %{first | mutants: mutants, timeout_ms: raws |> Enum.map(& &1.timeout_ms) |> Enum.max()}}
    end
  end
end

defmodule Covenant.Mutate.Checkpoint do
  @moduledoc false

  alias Covenant.Mutate

  # Checkpoints are opt-in. Keep input values (including environment values)
  # out of the manifest; persist their digest only. Hash dependency sources and
  # compiled BEAMs as well as the consumer's untracked source and fixture data.
  @doc false
  def inputs(settings, plan) do
    roots = [File.cwd!() | Map.values(Mix.Project.deps_paths())] |> Enum.uniq() |> Enum.sort()
    beams = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    consolidation = Mix.Project.consolidation_path()
    beams = if File.dir?(consolidation), do: [consolidation | beams], else: beams

    options =
      Map.take(
        settings,
        ~w(component modules only timeout fail_fast macros recompile seed contracts test_paths selective_recompile)a
      )
      |> Map.put(:profile, {plan.names, plan.source, plan.test_files})
      |> Map.put(:environment, System.get_env())
      |> Map.put(:runtime, {System.version(), :erlang.system_info(:system_version), Mix.env()})
      |> Map.put(:compiler, Code.compiler_options())
      |> Map.put(:hints, settings.hints)

    %{roots: roots, files: beams, options: options}
  end

  @doc false
  def fingerprint(%{roots: roots, files: files, options: options}) do
    try do
      entries = Enum.reduce(roots ++ files, %{}, &walk(Path.expand(&1), &2))
      {:ok, hash({Enum.sort(entries), options}), map_size(entries)}
    rescue
      error -> {:error, "cannot fingerprint checkpoint inputs: #{Exception.message(error)}"}
    end
  end

  defp walk(path, entries) do
    if Map.has_key?(entries, path) do
      entries
    else
      case File.lstat!(path) do
        %{type: :regular, mode: mode} ->
          Map.put(entries, path, {mode, file_hash(path, File.read!(path))})

        %{type: :symlink} ->
          target = File.read_link!(path)
          walk(Path.expand(target, Path.dirname(path)), Map.put(entries, path, {:link, target}))

        %{type: :directory, mode: mode} ->
          project? = File.regular?(Path.join(path, "mix.exs"))

          plts? =
            Path.basename(path) == "priv" and
              File.regular?(Path.join(Path.dirname(path), "mix.exs"))

          entries = Map.put(entries, path, {:directory, mode})

          File.ls!(path)
          |> Enum.reject(&(excluded?(&1, project?) or (plts? and &1 == "plts")))
          |> Enum.sort()
          |> Enum.reduce(entries, &walk(Path.join(path, &1), &2))

        _ ->
          raise "unsupported checkpoint input: #{path}"
      end
    end
  end

  defp excluded?(name, project?) do
    name in ~w(.git .elixir_ls .lexical .expert erl_crash.dump) or
      (project? and name in ~w(_build deps tmp cover doc))
  end

  # Protocol consolidation can encode equal checker maps in different orders.
  # Normalize that term only; retain every executable and other metadata chunk.
  # Unrecognized or malformed BEAMs keep their exact bytes in the fingerprint.
  defp file_hash(path, bytes) do
    with ".beam" <- Path.extname(path),
         {:ok, module, chunks} <- :beam_lib.all_chunks(bytes) do
      chunks =
        Enum.map(chunks, fn
          {~c"ExCk", checker} -> {~c"ExCk", {:term, :erlang.binary_to_term(checker)}}
          chunk -> chunk
        end)

      hash({module, chunks})
    else
      _ -> hash(bytes)
    end
  rescue
    _ -> hash(bytes)
  end

  defp hash(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp bytes_hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc false
  def open(directory, inputs, resume) do
    with {:ok, fingerprint, count} <- fingerprint(inputs),
         {:ok, saved} <- load(resume, fingerprint) do
      state = %{directory: directory, inputs: inputs, fingerprint: fingerprint}

      atomic(Path.join(directory, "checkpoint.json"), %{
        "format" => 1,
        "fingerprint" => fingerprint,
        "inputs" => count
      })

      for {{_raw, bytes}, index} <- Enum.with_index(saved, 1) do
        path = Path.join(directory, "cached-#{index}.json")
        File.write!(path, bytes, [:sync])
        seal_file(state, path, bytes)
      end

      {:ok, state, Enum.map(saved, &elem(&1, 0))}
    end
  end

  defp load(nil, _fingerprint), do: {:ok, []}

  defp load(directory, fingerprint) do
    with {:ok, text} <- File.read(Path.join(directory, "checkpoint.json")),
         {:ok, %{"format" => 1, "fingerprint" => ^fingerprint}} <- JSON.decode(text) do
      Path.wildcard(Path.join(directory, "verified-*.json"))
      |> Enum.reduce_while({:ok, []}, fn seal, {:ok, groups} ->
        case load_group(seal, fingerprint) do
          {:ok, group} -> {:cont, {:ok, groups ++ [group]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> unique_groups()
    else
      _ ->
        {:error, "checkpoint inputs changed or manifest is missing; cannot resume #{directory}"}
    end
  end

  defp load_group(seal, fingerprint) do
    with {:ok, text} <- File.read(seal),
         {:ok, %{"format" => 1, "fingerprint" => ^fingerprint, "raw" => name, "sha256" => digest}} <-
           JSON.decode(text),
         true <- is_binary(name) and Path.basename(name) == name,
         path = Path.join(Path.dirname(seal), name),
         {:ok, bytes} <- File.read(path),
         true <- bytes_hash(bytes) == digest,
         {:ok, raw} <- Mutate.decode_raw(path),
         true <- reusable?(raw) do
      {:ok, {raw, bytes}}
    else
      _ -> {:error, "checkpoint group is corrupt or unverified: #{seal}"}
    end
  rescue
    _ -> {:error, "checkpoint group is corrupt or unverified: #{seal}"}
  end

  defp unique_groups({:ok, groups}) do
    ids = for {raw, _} <- groups, mutant <- raw.mutants, do: mutant.id
    if Enum.uniq(ids) == ids, do: {:ok, groups}, else: {:error, "checkpoint groups overlap"}
  end

  defp unique_groups(error), do: error

  @doc false
  def reusable?(raw) do
    (raw.complete or raw.retired) and not raw.stopped and raw.mutants != [] and
      raw.tests != [] and Enum.all?(raw.tests, &(&1.outcome in [:passed, :skipped, :excluded])) and
      Enum.all?(
        raw.mutants,
        &(&1.verdict in [:killed, :survived, :invalid] and &1.timeouts == [])
      )
  end

  # Called by the parent only after a zero worker exit. Per-mutant writes and
  # watchdog results never get a seal, even if their JSON claims completion.
  @doc false
  def seal(nil, _path, _raw), do: :ok

  def seal(state, path, raw) do
    with {:ok, fingerprint, _} <- fingerprint(state.inputs),
         true <- fingerprint == state.fingerprint do
      if reusable?(raw), do: seal_file(state, path, File.read!(path))
      :ok
    else
      _ -> {:error, "checkpoint inputs changed while workers ran; results cannot be reused"}
    end
  end

  defp seal_file(state, path, bytes) do
    name = Path.basename(path)

    atomic(Path.join(state.directory, "verified-#{name}"), %{
      "format" => 1,
      "fingerprint" => state.fingerprint,
      "raw" => name,
      "sha256" => bytes_hash(bytes)
    })
  end

  defp atomic(path, map) do
    temporary = path <> ".tmp"
    File.write!(temporary, [Covenant.JSON.pretty(map), "\n"], [:sync])
    File.rename!(temporary, path)
  end

  @doc false
  def baselines(raws) do
    signatures =
      Enum.map(raws, fn raw ->
        {raw.component, raw.modules, raw.files, raw.only, raw.all,
         Enum.sort_by(raw.tests, & &1.key)}
      end)

    if length(Enum.uniq(signatures)) == 1,
      do: :ok,
      else:
        {:error,
         "checkpoint baseline differs from the current suite; cached verdicts cannot be used"}
  end
end

defmodule Covenant.Mutate.Selection do
  @moduledoc false

  alias Covenant.Mutate.{Mutant, Mutator, Survivors}

  @doc false
  def ids(values) do
    ids = values |> Enum.flat_map(&String.split(&1, ",")) |> Enum.map(&String.trim/1)

    if Enum.any?(ids, &(not Regex.match?(~r/^m\d+$/, &1))),
      do: {:error, "--only expects mutant IDs, for example --only m0001,m0007"},
      else: {:ok, Enum.uniq(ids)}
  end

  @doc false
  def choose(mutants, []), do: {:ok, mutants}

  def choose(mutants, ids) do
    known = MapSet.new(mutants, & &1.id)
    unknown = Enum.reject(ids, &MapSet.member?(known, &1))

    if unknown == [],
      do: {:ok, Enum.filter(mutants, &(&1.id in ids))},
      else: {:error, "unknown mutant ID(s) for this profile: #{Enum.join(unknown, ", ")}"}
  end

  # Match the runner's file order, ownership filter, and numbering. No target
  # compilation runs in the parent. The workers still compile and verify it.
  @doc false
  def catalog(modules, root, macros, keep) do
    modules
    |> Enum.group_by(fn {_, file} -> file end, fn {module, _} -> inspect(module) end)
    |> Enum.sort()
    |> Enum.flat_map(fn {file, targets} ->
      {:ok, ast} = Mutator.parse(File.read!(file), file)
      Mutator.sites(ast, file: Path.relative_to(file, root), modules: targets, macros: macros)
    end)
    |> Enum.filter(keep)
    |> Mutator.numbered()
  end

  # Resolve declarations against every site before selection. This keeps #k
  # occurrences stable. Defer only annotations known to match excluded sites;
  # unknown sites and annotations contradicted by selected verdicts still fail.
  @doc false
  def annotations(annotations, catalog, selected) do
    {resolved, errors} = Survivors.resolve(annotations, catalog)

    active =
      Enum.filter(resolved, fn annotation ->
        Enum.any?(selected, &Survivors.matches?(annotation, &1)) or
          not Enum.any?(catalog, &Survivors.matches?(annotation, &1))
      end)

    {active, errors, length(resolved) - length(active)}
  end

  @doc false
  def metadata(catalog, selected, deferred) do
    %{
      "kind" => "focused",
      "ids" => Enum.map(selected, & &1.id),
      "selected" => length(selected),
      "available" => length(catalog),
      "deferred_annotations" => deferred,
      "sites" =>
        Enum.map(
          selected,
          &%{
            "at" => Mutant.at(&1),
            "operator" => to_string(&1.operator),
            "mutation" => Mutant.mutation(&1)
          }
        )
    }
  end
end

defmodule Covenant.Mutate.Hints do
  @moduledoc false

  alias Covenant.Mutate.Mutant

  # Prior results are scheduling hints only. Every verdict is measured again.
  @doc false
  def load(nil, _component), do: {:ok, %{}}

  def load(path, component) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"component" => ^component, "mutants" => mutants, "tests" => tests}}
         when is_list(mutants) and (is_map(tests) or is_list(tests)) <- JSON.decode(text),
         true <- Enum.all?(mutants, &(is_map(&1) and is_list(Map.get(&1, "killed_by", [])))),
         true <- is_map(tests) or Enum.all?(tests, &(is_map(&1) and is_binary(&1["key"]))) do
      tests = if is_map(tests), do: tests, else: Map.new(tests, &{&1["key"], &1})

      hints =
        for m <- mutants, m["verdict"] == "killed", into: %{} do
          killers =
            m
            |> Map.get("killed_by", [])
            |> Enum.flat_map(fn key ->
              case tests[key] do
                %{"module" => module} when is_binary(module) -> [key]
                _ -> []
              end
            end)
            |> Enum.uniq()

          {key(m), killers}
        end

      {:ok, hints}
    else
      _ -> {:error, "cannot read mutation hints for #{component} from #{path}"}
    end
  end

  @doc false
  def preferred(hints, _mutant, _modules, _tests) when map_size(hints) == 0, do: []

  def preferred(hints, mutant, modules, tests) do
    known = Map.get(hints, key(mutant), [])
    modules = Map.new(modules, &{inspect(&1), &1})

    tests
    |> Enum.filter(
      &(&1.outcome == :passed and &1.key in known and Map.has_key?(modules, &1.module))
    )
    |> Enum.sort_by(&{&1.ms, &1.key})
    |> Enum.take(1)
    |> Enum.map(&%{module: Map.fetch!(modules, &1.module), name: &1.name})
  end

  defp key(%Mutant{} = m),
    do: {m.file, m.line, m.column, Atom.to_string(m.operator), m.from, m.to}

  defp key(m),
    do: {m["file"], m["line"], m["column"], m["operator"], m["from"], m["to"]}
end
