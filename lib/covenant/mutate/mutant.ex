defmodule Covenant.Mutate.Mutant do
  @moduledoc """
  One mutant: a single AST change at one location of one implementation
  module, and (after a run) its verdict.

  Mutants are enumerated by `Covenant.Mutate.Mutator.sites/2` in source order,
  so the same source always yields the same list, with the same ids. The
  `index` is the position of the mutated node in a `Macro.traverse/4` walk of
  the file's AST; `replacement` is the node that takes its place and is never
  serialized.

  ## Verdicts

  * `:killed` — at least one contract test failed with a real failure;
  * `:survived` — every contract test passed;
  * `:timeout` — the only failures were `ExUnit.TimeoutError`s; counted as a
    survivor, never as a kill (record `timeouts-are-survivors`);
  * `:invalid` — the mutant does not compile; excluded from the denominator.
  """

  @type operator ::
          :boolean_flip
          | :comparison_swap
          | :arithmetic_swap
          | :logical_swap
          | :condition_negate
          | :statement_removal
          | :return_nil
          | :integer_shift
          | :string_empty
          | :guard_removal
          | :clause_removal
          | :element_removal
          | :ecto_where_removal

  @type verdict :: :killed | :survived | :timeout | :invalid

  @type t :: %__MODULE__{
          id: String.t() | nil,
          file: Path.t(),
          line: pos_integer(),
          column: pos_integer(),
          operator: operator(),
          from: String.t(),
          to: String.t(),
          module: String.t() | nil,
          function: String.t() | nil,
          index: pos_integer(),
          replacement: Macro.t() | nil,
          verdict: verdict() | nil,
          killed_by: [String.t()],
          timeouts: [String.t()],
          reason: String.t() | nil
        }

  @enforce_keys [:file, :line, :column, :operator, :from, :to, :index]
  defstruct [
    :id,
    :file,
    :line,
    :column,
    :operator,
    :from,
    :to,
    :module,
    :function,
    :index,
    :replacement,
    :verdict,
    :reason,
    killed_by: [],
    timeouts: []
  ]

  @operators ~w(boolean_flip comparison_swap arithmetic_swap logical_swap condition_negate
    statement_removal return_nil integer_shift string_empty guard_removal clause_removal
    element_removal ecto_where_removal)a

  @doc "Every operator, in the order variants are generated at a node."
  @spec operators() :: [operator()]
  def operators, do: @operators

  @doc "The location key used by survivor annotations: `file:line:column`."
  @spec at(t()) :: String.t()
  def at(%__MODULE__{file: file, line: line, column: column}), do: "#{file}:#{line}:#{column}"

  @doc "The change as one line: `` `from` → `to` ``."
  @spec mutation(t()) :: String.t()
  def mutation(%__MODULE__{from: from, to: to}), do: "`#{from}` → `#{to}`"

  @doc "The JSON-ready map (no AST, no timing)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = mutant) do
    %{
      "id" => mutant.id,
      "at" => at(mutant),
      "file" => mutant.file,
      "line" => mutant.line,
      "column" => mutant.column,
      "operator" => Atom.to_string(mutant.operator),
      "from" => mutant.from,
      "to" => mutant.to,
      "module" => mutant.module,
      "function" => mutant.function,
      "verdict" => mutant.verdict && Atom.to_string(mutant.verdict),
      "killed_by" => mutant.killed_by,
      "timeouts" => mutant.timeouts,
      "reason" => mutant.reason
    }
  end

  defp verdict("killed"), do: :killed
  defp verdict("survived"), do: :survived
  defp verdict("timeout"), do: :timeout
  defp verdict("invalid"), do: :invalid
  defp verdict(_), do: nil

  @doc "Rebuilds a mutant from `to_map/1` output (without its replacement AST)."
  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      id: map["id"],
      file: map["file"],
      line: map["line"],
      column: map["column"],
      operator: Enum.find(@operators, :boolean_flip, &(Atom.to_string(&1) == map["operator"])),
      from: map["from"],
      to: map["to"],
      module: map["module"],
      function: map["function"],
      index: map["index"] || 0,
      verdict: verdict(map["verdict"]),
      killed_by: List.wrap(map["killed_by"]),
      timeouts: List.wrap(map["timeouts"]),
      reason: map["reason"]
    }
  end
end
