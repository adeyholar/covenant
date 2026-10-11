defmodule Covenant.Mutate.Modules do
  @moduledoc """
  Which modules implement a component.

  The Contract already names them: the heavy form's `## Public surface` lists
  every function a caller can observe, and every obligation's `scope` names
  the functions it binds. `derive/1` reads the module names out of those code
  spans. When that is not the whole implementation (private helper modules
  that no obligation names), the component declares the full list in the
  front matter of its intent or obligations file:

  ```markdown
  ---
  modules: [Example.Counter, Example.Counter.Log]
  ---
  # example.counter
  ```

  A primitive of the sibling layout names its code in a `covers` block
  (`Covenant.Covers`); a tree (`MyApp.Calc.*`) is expanded to the project's
  modules under it when they are located.

  Precedence: `--module` flags on the command line, then the front matter
  (or a primitive's `covers`), then the derived set. Derivation reads inline code spans only (fenced
  blocks hold persisted-format examples, not module names). Derived modules
  must live under the project root (`String.t()` in a signature names a
  module too, and the standard library is not under test); explicitly named
  modules are an error when they do not.
  """

  alias Covenant.Contract.{Component, Obligation}
  alias Covenant.Covers

  @fence ~r/^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$/ms
  @code_span ~r/`([^`\n]+)`/
  @module_ref ~r/(?<![A-Za-z0-9_:.])([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)(?![A-Za-z0-9_])/

  @typedoc "Where a module name came from."
  @type source :: :flag | :front_matter | :covers | :derived

  @doc """
  The implementation module names of `component`, as strings, with their source.
  `flags` are the `--module` values.
  """
  @spec resolve(Component.t(), [String.t()]) :: {source(), [String.t()]}
  def resolve(%Component{} = component, flags \\ []) do
    cond do
      flags != [] ->
        {:flag, flags |> Enum.map(&String.trim_leading(&1, "Elixir.")) |> uniq()}

      component.form == :primitive ->
        {:covers, Covers.module_names(component.covers)}

      Component.declared_modules(component) != [] ->
        {:front_matter, uniq(Component.declared_modules(component))}

      true ->
        {:derived, derive(component)}
    end
  end

  @doc """
  Module names read from the `## Public surface` code spans and the `scope`
  of every testable obligation, sorted and unique.
  """
  @spec derive(Component.t()) :: [String.t()]
  def derive(%Component{} = component) do
    surface =
      case Component.section(component, "Public surface") do
        nil -> ""
        section -> section.body
      end

    scopes =
      component
      |> Component.testable_obligations()
      |> Enum.map_join("\n", fn %Obligation{scope: scope} -> scope || "" end)

    references(surface <> "\n" <> scopes)
  end

  @doc "The module names in the inline code spans of `text` (fenced blocks ignored), sorted and unique."
  @spec references(String.t()) :: [String.t()]
  def references(text) do
    text
    |> String.replace(@fence, "")
    |> then(&Regex.scan(@code_span, &1))
    |> Enum.flat_map(fn [_, span] -> Regex.scan(@module_ref, span) end)
    |> Enum.map(fn [_, name] -> name end)
    |> uniq()
  end

  @doc """
  Loads each named module and finds the source file it was compiled from.

  Returns `{:ok, [{module, source}], ignored}` where `ignored` lists the
  derived modules that were skipped with the reason, or `{:error, message}`
  for an explicit module that cannot be used. `root` is the project root
  sources must live under.
  """
  @spec locate([String.t()], source(), Path.t()) ::
          {:ok, [{module(), Path.t()}], [{String.t(), String.t()}]} | {:error, String.t()}
  def locate(names, source, root) do
    root = Path.expand(root)
    names = expand_trees(names)

    {located, ignored, errors} =
      Enum.reduce(names, {[], [], []}, fn name, {ok, ignored, errors} ->
        case locate_one(name, root) do
          {:ok, module, file} ->
            {[{module, file} | ok], ignored, errors}

          {:skip, reason} when source == :derived ->
            {ok, [{name, reason} | ignored], errors}

          {:skip, reason} ->
            {ok, ignored, ["#{name}: #{reason}" | errors]}
        end
      end)

    cond do
      errors != [] ->
        {:error, Enum.join(Enum.reverse(errors), "; ")}

      located == [] ->
        {:error,
         "no implementation module to mutate" <>
           case source do
             :derived ->
               "; the Public surface and obligation scopes name none under #{root}. " <>
                 "Declare `modules:` in the front matter or pass --module"

             _ ->
               ""
           end}

      true ->
        {:ok, located |> Enum.reverse() |> Enum.uniq() |> Enum.sort_by(&inspect(elem(&1, 0))),
         Enum.reverse(ignored)}
    end
  end

  defp expand_trees(names) do
    if Enum.any?(names, &String.ends_with?(&1, ".*")) do
      modules = Covers.project_modules()
      names |> Enum.flat_map(&Covers.expand(&1, modules)) |> Enum.uniq()
    else
      names
    end
  end

  defp locate_one(name, root) do
    module = Module.concat([name])

    cond do
      not Code.ensure_loaded?(module) ->
        {:skip, "is not a loaded module"}

      true ->
        case module.module_info(:compile)[:source] do
          source when is_list(source) ->
            file = source |> List.to_string() |> Path.expand()

            cond do
              not File.exists?(file) ->
                {:skip, "was compiled from #{file}, which does not exist"}

              not String.starts_with?(file, root <> "/") ->
                {:skip, "lives outside the project (#{file})"}

              true ->
                {:ok, module, file}
            end

          _ ->
            {:skip, "has no source file"}
        end
    end
  end

  defp uniq(names), do: names |> Enum.uniq() |> Enum.sort()
end
