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

  @default_timeout 10_000
  @default_seed 0

  @doc "The default per-test timeout for mutant runs, in milliseconds."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

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
        tests = Regen.find_tests(component_id, test_paths, root)

        cond do
          names == [] ->
            {:error,
             "`#{component_id}` names no implementation module: its Public surface and obligation " <>
               "scopes contain no `Module.function` code span. Declare `modules:` in the front matter " <>
               "of #{component.file} or pass --module"}

          tests == [] ->
            {:error,
             "no contract test file declares `use Covenant.Case, component: \"#{component_id}\"` " <>
               "under #{Enum.join(test_paths, ", ")}"}

          true ->
            {:ok, %{component: component, names: names, source: source, test_files: tests}}
        end
    end
  end

  # -- raw worker results -----------------------------------------------------

  @doc "Encodes one worker's `Covenant.Mutate.Runner` result as JSON."
  @spec encode_raw(map(), keyword()) :: iodata()
  def encode_raw(result, meta) do
    Covenant.JSON.pretty(%{
      "covenant" => Covenant.version(),
      "component" => Keyword.fetch!(meta, :component),
      "slice" => Keyword.get(meta, :slice, "1/1"),
      "modules" => Keyword.get(meta, :modules, []),
      "ignored" => Enum.map(Keyword.get(meta, :ignored, []), fn {name, why} -> [name, why] end),
      "files" => result.files,
      "all" => result.all,
      "baseline_ms" => result.baseline_ms,
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
    })
  end

  @doc "Reads a raw results file back."
  @spec decode_raw(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def decode_raw(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"mutants" => mutants, "tests" => tests} = raw} when is_list(mutants) <-
           JSON.decode(text) do
      {:ok,
       %{
         component: raw["component"],
         slice: raw["slice"],
         modules: List.wrap(raw["modules"]),
         ignored: Enum.map(List.wrap(raw["ignored"]), fn [name, why] -> {name, why} end),
         files: List.wrap(raw["files"]),
         all: raw["all"] || length(mutants),
         baseline_ms: raw["baseline_ms"] || 0,
         tests: Enum.map(tests, &decode_test/1),
         mutants: Enum.map(mutants, &Mutant.from_map/1)
       }}
    else
      {:ok, _} -> {:error, "#{path}: not a covenant.mutate results file"}
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, reason} -> {:error, "#{path}: invalid JSON: #{inspect(reason)}"}
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
  sorted by id.
  """
  @spec merge([map()]) :: {:ok, map()} | {:error, String.t()}
  def merge([]), do: {:error, "no worker results to merge"}

  def merge([first | _] = raws) do
    mutants = raws |> Enum.flat_map(& &1.mutants) |> Enum.sort_by(& &1.id)
    ids = Enum.map(mutants, & &1.id)

    cond do
      ids != Enum.uniq(ids) ->
        {:error, "worker results overlap (the same mutant was run twice)"}

      length(ids) != first.all ->
        {:error,
         "worker results are incomplete: #{length(ids)} of #{first.all} mutants have a verdict"}

      true ->
        {:ok, %{first | mutants: mutants}}
    end
  end
end
