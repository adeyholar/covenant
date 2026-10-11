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
    counter: { kind: module, module: MyApp.Scope, function: runtime_deps }
  ```

  A `glob` counter counts the files matching `pattern` (relative to the
  project root); a `module` counter calls `module.function/0`, which must
  return a non-negative integer. `mix covenant.check` fails when a count
  exceeds its ceiling. A module counter that raises (a stub that is not
  implemented yet) leaves its ceiling unchecked, which is reported but never
  a failure.
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
  Evaluates the counter. Returns `{:ok, count}`, `{:error, reason}` when a
  module counter cannot be called or returns something else, or
  `{:unchecked, reason}` when it raises, throws or exits (`reason` names the
  exception module).
  """
  @spec count(t(), keyword()) ::
          {:ok, non_neg_integer()} | {:unchecked, String.t()} | {:error, String.t()}
  def count(%__MODULE__{counter: {:glob, pattern}}, opts) do
    root = Keyword.get(opts, :root, File.cwd!())
    {:ok, root |> Path.join(pattern) |> Path.wildcard(match_dot: false) |> length()}
  end

  def count(%__MODULE__{counter: {:module, module, function}}, _opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, "counter module #{inspect(module)} is not loaded"}

      system_module?(module) ->
        {:error,
         "counter #{inspect(module)}.#{function}/0 is refused: #{inspect(module)} is part of Elixir or OTP"}

      not function_exported?(module, function, 0) ->
        {:error, "counter #{inspect(module)}.#{function}/0 is not exported"}

      true ->
        case call(module, function) do
          {:returned, n} when is_integer(n) and n >= 0 ->
            {:ok, n}

          {:returned, other} ->
            {:error, "counter #{inspect(module)}.#{function}/0 returned #{inspect(other)}"}

          {:raised, what} ->
            {:unchecked, what}
        end
    end
  end

  @doc """
  True when the loaded `module`'s beam lies under the OTP or Elixir installation. A counter or
  value check calls project functions; one that reaches `System.halt/0` would end the VM, which
  `rescue` cannot stop. This is a mitigation, not a sandbox.
  """
  @spec system_module?(module()) :: boolean()
  def system_module?(module) do
    Covenant.Regen.Ownership.classify_beam(
      :code.which(module),
      Covenant.Regen.Ownership.environment(%{})
    ) == :foreign
  end

  defp call(module, function) do
    {:returned, apply(module, function, [])}
  rescue
    exception -> {:raised, inspect(exception.__struct__)}
  catch
    kind, reason -> {:raised, "#{kind} #{inspect(reason)}"}
  end

  @doc "Describes the counter for messages."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{counter: {:glob, pattern}}), do: "glob #{pattern}"

  def describe(%__MODULE__{counter: {:module, module, function}}),
    do: "#{inspect(module)}.#{function}/0"
end
