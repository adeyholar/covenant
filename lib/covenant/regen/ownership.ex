defmodule Covenant.Regen.Ownership do
  @moduledoc """
  Which modules a Public surface reference names does the component own?

  A stub for a module the component does not own (`System.halt(1)` in prose,
  `Ecto.UUID.cast/1`, another component's `MyApp.Repo.Scoped`) would shadow
  the real one. `partition/4` sorts the signatures of a Public surface into the
  ones to stub and the ones to skip:

  1. **A listed set is authoritative.** When the Public surface has a
     `#### Modules` paragraph, or the front matter has `modules:`, exactly
     those modules are stubbed and every other reference is skipped. In the
     paragraph only the backticked names outside parentheses count
     (`` `MyApp.Cache` (behaviour, see `MyApp.Registry`) `` lists one).
  2. **A module another component lists is foreign.** A module in the
     `#### Modules` paragraph or `modules:` of another component of the
     Contract belongs to that component: it is skipped and attributed to it
     (`:skipped` entries carry `owner: "<component id>"`), whether or not it
     is implemented yet.
  3. **Otherwise ownership follows where a module lives.** A loadable module
     is foreign when its beam (`:code.which/1`) lies under the OTP or Elixir
     installation or a dependency's build path, and is already implemented
     (skipped, `implemented: true`) when it lies in an app of the running Mix
     project (umbrella children and `in_umbrella` dependencies included): the
     component declared no modules, so nothing says the implementation is its
     own, and a stub would shadow it. A module that is not loadable is foreign
     when its first segment is a dependency's namespace (`Ecto` for `:ecto`,
     even when `:ecto` is not compiled in this VM), is stubbed when its first
     segment is a namespace the component's obligation scopes use (or when
     they name no module at all) and is *unplaced* otherwise.
  4. **When it cannot be told, it is stubbed and reported.** A loadable module
     whose beam is anywhere else is stubbed and listed as `possibly_foreign`.

  An alias is resolved to the one module whose name ends in it: the bare
  `Scope`, a dotted fragment such as `Repo.Scoped` for `MyApp.Repo.Scoped`,
  and an unplaced module name (`Spend.Policy`). The candidates are the listed
  modules, the modules other components list and the modules the surface
  itself stubs. It is dropped when none or several match; a bare name that is
  itself a loadable module (`System`) is never an alias.
  """

  alias Covenant.Contract
  alias Covenant.Contract.{Component, Obligation}
  alias Covenant.Mutate.Modules

  @typedoc "Where the running VM keeps OTP, Elixir, dependencies and the project's own apps."
  @type environment :: %{
          own_dirs: [Path.t()],
          foreign_dirs: [Path.t()],
          dep_namespaces: [String.t()]
        }

  @typedoc """
  What `classify/3` says: `:own` (stub it), `:foreign` (skip it), `:implemented` (a loadable
  module of the running project, skipped), `:unsure` (stub it and report it) or `:unplaced`
  (not loadable, in a namespace the component does not use: resolve it as an alias or skip it).
  """
  @type verdict :: :own | :foreign | :implemented | :unsure | :unplaced

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
  The modules the other components of `contract` list (rule 2 of the module docs), as
  `%{module => component id}`; a module two components list belongs to the first by id.
  """
  @spec declared_elsewhere(Contract.t(), Component.t()) :: %{String.t() => String.t()}
  def declared_elsewhere(%Contract{components: components}, %Component{id: id}) do
    components
    |> Enum.reject(fn {other, _} -> other == id end)
    |> Enum.sort()
    |> Enum.reduce(%{}, fn {other, component}, acc ->
      Enum.reduce(listed(component), acc, &Map.put_new(&2, &1, other))
    end)
  end

  @doc """
  Splits `signatures` (maps with a `:module` string) into `:stub`, `:skipped`
  and the `:possibly_foreign` module names. A stubbed alias has its `:module`
  rewritten to the module it resolves to. A skipped signature carries
  `owner: "<component id>"` when another component lists its module and
  `implemented: true` when the running project already has it.

  `declared_elsewhere` is `declared_elsewhere/2`'s `%{module => component id}`.
  """
  @spec partition(Component.t(), [map()], environment(), %{String.t() => String.t()}) :: %{
          stub: [map()],
          skipped: [map()],
          possibly_foreign: [String.t()]
        }
  def partition(%Component{} = component, signatures, environment, declared_elsewhere \\ %{}) do
    listed = listed(component)
    namespaces = own_namespaces(component)

    verdict = fn module ->
      cond do
        module in listed -> :own
        Map.has_key?(declared_elsewhere, module) -> {:elsewhere, declared_elsewhere[module]}
        listed != [] -> :foreign
        true -> classify(module, environment, namespaces)
      end
    end

    {qualified, bare} = Enum.split_with(signatures, &String.contains?(&1.module, "."))
    qualified = Enum.map(qualified, &{&1, verdict.(&1.module)})

    known =
      Enum.uniq(
        listed ++
          Map.keys(declared_elsewhere) ++
          for({sig, v} <- qualified, v in [:own, :unsure], do: sig.module)
      )

    resolve = fn sig -> resolve_alias(sig, known, verdict) end

    qualified =
      Enum.map(qualified, fn
        {sig, :unplaced} -> resolve.(sig)
        other -> other
      end)

    bare =
      Enum.map(bare, fn sig ->
        loaded? = loaded?(sig.module)

        cond do
          sig.module in listed -> {sig, :own}
          loaded? -> {sig, verdict.(sig.module)}
          true -> resolve.(sig)
        end
      end)

    all = qualified ++ bare

    %{
      stub: for({sig, v} <- all, v in [:own, :unsure], do: sig),
      skipped: for({sig, v} <- all, v not in [:own, :unsure], do: skipped(sig, v)),
      possibly_foreign: for({sig, :unsure} <- all, do: sig.module) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp skipped(sig, {:elsewhere, owner}), do: Map.put(sig, :owner, owner)
  defp skipped(sig, :implemented), do: Map.put(sig, :implemented, true)
  defp skipped(sig, _), do: sig

  # The one known module whose name ends in the alias takes its verdict (a stubbed module
  # keeps the alias's functions); none or several, and the reference is dropped.
  defp resolve_alias(sig, known, verdict) do
    case Enum.filter(known, &String.ends_with?(&1, "." <> sig.module)) do
      [module] ->
        case verdict.(module) do
          :unsure -> {%{sig | module: module}, :own}
          other -> {%{sig | module: module}, other}
        end

      _ ->
        {sig, :foreign}
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
  Classifies one module name by where it lives (rule 3 and 4 of the module
  docs). `own_namespaces` are the first segments the component is known to
  use; with none known, a module nobody can place is simply owned.
  """
  @spec classify(String.t(), environment(), [String.t()]) :: verdict()
  def classify(module, environment, own_namespaces \\ []) do
    if loaded?(module) do
      case [module] |> Module.concat() |> :code.which() |> classify_beam(environment) do
        :own -> :implemented
        other -> other
      end
    else
      first = first_segment(module)

      cond do
        first in environment.dep_namespaces -> :foreign
        own_namespaces != [] and first not in own_namespaces -> :unplaced
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
