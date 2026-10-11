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
          | {:module, String.t(), String.t()}

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
    name = module_name(module)
    function = to_string(function)
    atom = existing_module(module)

    cond do
      is_nil(atom) or not Code.ensure_loaded?(atom) ->
        {:error, "counter module #{name} is not loaded"}

      system_module?(atom) ->
        {:error, "counter #{name}.#{function}/0 is refused: #{name} is part of Elixir or OTP"}

      fun = exported_function(atom, function) ->
        case call(atom, fun) do
          {:returned, n} when is_integer(n) and n >= 0 ->
            {:ok, n}

          {:returned, other} ->
            {:error, "counter #{name}.#{function}/0 returned #{inspect(other)}"}

          {:raised, what} ->
            {:unchecked, what}
        end

      true ->
        {:error, "counter #{name}.#{function}/0 is not exported"}
    end
  end

  # A counter's names come from the Contract and are strings: no atom is made for them.
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(name), do: name

  defp existing_module(module) when is_atom(module), do: module

  defp existing_module(name) do
    String.to_existing_atom("Elixir." <> String.replace_prefix(name, "Elixir.", ""))
  rescue
    ArgumentError -> nil
  end

  defp exported_function(module, function) do
    Enum.find_value(module.module_info(:exports), fn
      {name, 0} -> if Atom.to_string(name) == function, do: name
      _ -> nil
    end)
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
    do: "#{module_name(module)}.#{function}/0"
end
