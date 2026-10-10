defmodule Covenant.Regen.Ownership do
  @moduledoc """
  Which modules a Public surface reference names does the component own?

  A stub for a module the component does not own (`System.halt(1)` in prose,
  `Ecto.UUID.cast/1`) would shadow the real one. `partition/3` sorts the
  signatures of a Public surface into the ones to stub and the ones to skip:

  1. **A listed set is authoritative.** When the Public surface has a
     `#### Modules` paragraph, or the front matter has `modules:`, exactly
     those modules are stubbed and every other reference is skipped. In the
     paragraph only the backticked names outside parentheses count
     (`` `Machina.Cache` (behaviour, see `Machina.Registry`) `` lists one).
  2. **Otherwise ownership follows where a module lives.** A loadable module
     is foreign when its beam (`:code.which/1`) lies under the OTP or Elixir
     installation or a dependency's build path, and owned when it lies in an
     app of the running Mix project (umbrella children and `in_umbrella`
     dependencies included). A module that is not loadable is foreign when
     its first segment is a dependency's namespace (`Ecto` for `:ecto`, even
     when `:ecto` is not compiled in this VM) and is stubbed otherwise.
  3. **When it cannot be told, it is stubbed and reported.** A loadable module
     whose beam is anywhere else, or a module that is not loadable and whose
     first segment is none of the namespaces the component's obligation scopes
     use, is stubbed and listed as `possibly_foreign`.

  A bare alias (`Scope.put/1`) is merged into the one owned module whose last
  segment matches (`Machina.Scope`) and dropped when none or several match; a
  bare name that is itself a foreign module (`System`) is never an alias.
  """

  alias Covenant.Contract.{Component, Obligation}
  alias Covenant.Mutate.Modules

  @typedoc "Where the running VM keeps OTP, Elixir, dependencies and the project's own apps."
  @type environment :: %{
          own_dirs: [Path.t()],
          foreign_dirs: [Path.t()],
          dep_namespaces: [String.t()]
        }

  @type verdict :: :own | :foreign | :unsure

  @module_span ~r/`([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)`/

  @doc """
  The modules the intent lists as its own: the `#### Modules` paragraph of the
  Public surface and the front matter's `modules:`. Empty when it lists none.
  """
  @spec listed(Component.t()) :: [String.t()]
  def listed(%Component{} = component) do
    Enum.uniq(Component.declared_modules(component) ++ paragraph(component))
  end

  defp paragraph(component) do
    with %{body: body} <- Component.section(component, "Public surface"),
         [_ | rest] <-
           body |> String.split("\n") |> Enum.drop_while(&(String.trim(&1) != "#### Modules")) do
      rest
      |> Enum.take_while(&(not String.starts_with?(&1, "#")))
      |> Enum.join("\n")
      |> strip_parentheses()
      |> then(&Regex.scan(@module_span, &1))
      |> Enum.map(fn [_, name] -> name end)
    else
      _ -> []
    end
  end

  defp strip_parentheses(text) do
    case Regex.replace(~r/\([^()]*\)/, text, "") do
      ^text -> text
      shorter -> strip_parentheses(shorter)
    end
  end

  @doc """
  Splits `signatures` (maps with a `:module` string) into `:stub`, `:skipped`
  and the `:possibly_foreign` module names. A stubbed bare alias has its
  `:module` rewritten to the module it resolves to.
  """
  @spec partition(Component.t(), [map()], environment()) :: %{
          stub: [map()],
          skipped: [map()],
          possibly_foreign: [String.t()]
        }
  def partition(%Component{} = component, signatures, environment) do
    listed = listed(component)
    namespaces = own_namespaces(component)

    verdict = fn module ->
      if listed == [] do
        classify(module, environment, namespaces)
      else
        if module in listed, do: :own, else: :foreign
      end
    end

    {qualified, bare} = Enum.split_with(signatures, &String.contains?(&1.module, "."))
    qualified = Enum.map(qualified, &{&1, verdict.(&1.module)})
    known = Enum.uniq(listed ++ for({sig, v} <- qualified, v != :foreign, do: sig.module))

    bare =
      Enum.map(bare, fn sig ->
        loaded? = loaded?(sig.module)

        cond do
          sig.module in listed -> {sig, :own}
          loaded? and classify(sig.module, environment) == :foreign -> {sig, :foreign}
          loaded? and listed != [] -> {sig, :foreign}
          loaded? -> {sig, verdict.(sig.module)}
          true -> resolve_alias(sig, known)
        end
      end)

    all = qualified ++ bare

    %{
      stub: for({sig, v} <- all, v != :foreign, do: sig),
      skipped: for({sig, :foreign} <- all, do: sig),
      possibly_foreign: for({sig, :unsure} <- all, do: sig.module) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp resolve_alias(sig, known) do
    case Enum.filter(known, &(List.last(String.split(&1, ".")) == sig.module)) do
      [module] -> {%{sig | module: module}, :own}
      _ -> {sig, :foreign}
    end
  end

  # The first segments of the modules the component's obligation scopes name:
  # the namespaces it is known to live in.
  defp own_namespaces(component) do
    component
    |> Component.testable_obligations()
    |> Enum.map_join("\n", fn %Obligation{scope: scope} -> scope || "" end)
    |> Modules.references()
    |> Enum.map(&first_segment/1)
    |> Enum.uniq()
  end

  defp first_segment(module), do: module |> String.split(".") |> hd()

  defp loaded?(module), do: Code.ensure_loaded?(Module.concat([module]))

  @doc """
  Classifies one module name by where it lives (rule 2 and 3 of the module
  docs). `own_namespaces` are the first segments the component is known to
  use; with none known, a module nobody can place is simply owned.
  """
  @spec classify(String.t(), environment(), [String.t()]) :: verdict()
  def classify(module, environment, own_namespaces \\ []) do
    if loaded?(module) do
      [module] |> Module.concat() |> :code.which() |> classify_beam(environment)
    else
      first = first_segment(module)

      cond do
        first in environment.dep_namespaces -> :foreign
        own_namespaces != [] and first not in own_namespaces -> :unsure
        true -> :own
      end
    end
  end

  @doc "Classifies a beam path as `:code.which/1` returns it."
  @spec classify_beam(term(), environment()) :: verdict()
  def classify_beam(:preloaded, _environment), do: :foreign

  def classify_beam(beam, environment) when is_list(beam) or is_binary(beam) do
    case to_string(beam) do
      "" ->
        :unsure

      path ->
        path = Path.expand(path)

        cond do
          under?(path, environment.own_dirs) -> :own
          under?(path, environment.foreign_dirs) -> :foreign
          true -> :unsure
        end
    end
  end

  def classify_beam(_other, _environment), do: :unsure

  defp under?(path, dirs),
    do: Enum.any?(dirs, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  @doc """
  The environment of the running VM: the OTP and Elixir installations, the
  running Mix project's apps (an umbrella's children, `in_umbrella`
  dependencies) and its dependencies.
  """
  @spec environment() :: environment()
  def environment do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      config = Mix.Project.config()

      environment(%{
        app: config[:app],
        apps: Map.keys(Mix.Project.apps_paths() || %{}),
        in_umbrella: in_umbrella(config[:deps]),
        deps: Map.keys(Mix.Project.deps_paths()),
        build_path: Mix.Project.build_path()
      })
    else
      environment(%{})
    end
  end

  @doc """
  The environment for `facts`: `:app`, `:apps` (an umbrella's children),
  `:in_umbrella` (dependencies that are sibling apps), `:deps` (every
  dependency app) and `:build_path`.
  """
  @spec environment(map()) :: environment()
  def environment(facts) do
    own = Enum.uniq(List.wrap(facts[:app]) ++ (facts[:apps] || []) ++ (facts[:in_umbrella] || []))
    foreign = Enum.uniq(facts[:deps] || []) -- own

    in_build = fn app ->
      Path.expand(Path.join([facts[:build_path] || "_build", "lib", to_string(app)]))
    end

    %{
      own_dirs: Enum.map(own, in_build),
      foreign_dirs: system_roots() ++ Enum.map(foreign, in_build),
      dep_namespaces: foreign |> Enum.flat_map(&namespaces/1) |> Enum.uniq()
    }
  end

  @doc "The apps a Mix `deps:` list marks `in_umbrella: true`."
  @spec in_umbrella(list()) :: [atom()]
  def in_umbrella(deps) do
    for dep <- List.wrap(deps),
        is_tuple(dep),
        opts = elem(dep, tuple_size(dep) - 1),
        Keyword.keyword?(opts),
        opts[:in_umbrella] == true,
        do: elem(dep, 0)
  end

  defp system_roots do
    elixir = :elixir |> :code.lib_dir() |> to_string() |> Path.dirname()
    Enum.map([to_string(:code.root_dir()), elixir], &Path.expand/1)
  end

  # `:ecto` owns `Ecto` whether or not it is compiled in this VM; a compiled
  # app also says which first segments its modules use (`Phoenix` for
  # `:phoenix_pubsub`).
  defp namespaces(app) do
    [app |> Atom.to_string() |> Macro.camelize() | compiled_namespaces(app)]
  end

  defp compiled_namespaces(app) do
    with dir when is_list(dir) <- :code.lib_dir(app),
         {:ok, [{:application, _, props}]} <-
           :file.consult(Path.join([to_string(dir), "ebin", "#{app}.app"])) do
      for module <- props[:modules] || [],
          "Elixir." <> name <- [Atom.to_string(module)],
          do: first_segment(name)
    else
      _ -> []
    end
  end
end
