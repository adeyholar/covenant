defmodule Covenant.Contract.Ceiling do
  @moduledoc """
  A scope-budget ceiling from `system/scope.yml`.

  ```yaml
  - name: core-modules
    ceiling: 60
    counter: { kind: glob, pattern: "apps/core/lib/**/*.ex" }
    why: The core stays small enough to regenerate in a day.
    record: six-tools          # optional decision record backing the ceiling
  - name: runtime-deps
    ceiling: 25
    counter: { kind: module, module: Machina.Scope, function: runtime_deps }
  ```

  A `glob` counter counts the files matching `pattern` (relative to the
  project root); a `module` counter calls `module.function/0`, which must
  return a non-negative integer. `mix covenant.check` fails when a count
  exceeds its ceiling.
  """

  @type counter ::
          {:glob, String.t()}
          | {:module, module(), atom()}

  @type t :: %__MODULE__{
          name: String.t(),
          ceiling: non_neg_integer(),
          counter: counter(),
          why: String.t() | nil,
          record: String.t() | nil,
          file: String.t(),
          line: pos_integer()
        }

  @enforce_keys [:name, :ceiling, :counter, :file, :line]
  defstruct [:name, :ceiling, :counter, :why, :record, :file, :line]

  @doc """
  Evaluates the counter. Returns `{:ok, count}` or `{:error, reason}` when a
  module counter cannot be called.
  """
  @spec count(t(), keyword()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def count(%__MODULE__{counter: {:glob, pattern}}, opts) do
    root = Keyword.get(opts, :root, File.cwd!())
    {:ok, root |> Path.join(pattern) |> Path.wildcard(match_dot: false) |> length()}
  end

  def count(%__MODULE__{counter: {:module, module, function}}, _opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, "counter module #{inspect(module)} is not loaded"}

      not function_exported?(module, function, 0) ->
        {:error, "counter #{inspect(module)}.#{function}/0 is not exported"}

      true ->
        case apply(module, function, []) do
          n when is_integer(n) and n >= 0 -> {:ok, n}
          other -> {:error, "counter #{inspect(module)}.#{function}/0 returned #{inspect(other)}"}
        end
    end
  end

  @doc "Describes the counter for messages."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{counter: {:glob, pattern}}), do: "glob #{pattern}"

  def describe(%__MODULE__{counter: {:module, module, function}}),
    do: "#{inspect(module)}.#{function}/0"
end
