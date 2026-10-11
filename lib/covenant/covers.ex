defmodule Covenant.Covers do
  @moduledoc """
  The code a sibling-layout primitive covers: the lines of the `covers` block
  in `contract/<primitive>/README.md`.

  ```covers
  MyApp.Calc            # a module
  MyApp.Calc.*          # a tree: the module and every module under it
  MyApp.Calc.add/2      # one function
  ```

  When several primitives cover the same code, the most specific reference
  wins: a function over a module, a module over a tree, a deeper tree over a
  shallower one. `owners/3` applies that rule to one function (or to module
  code outside any function), and `mix covenant.mutate` and `mix
  covenant.regen` use it to decide which primitive a mutant or a stub belongs
  to.
  """

  @type ref ::
          {:module, String.t()}
          | {:tree, String.t()}
          | {:function, String.t(), String.t(), non_neg_integer()}

  @type t :: %__MODULE__{ref: ref(), text: String.t(), file: String.t(), line: pos_integer()}

  @enforce_keys [:ref, :text, :file, :line]
  defstruct [:ref, :text, :file, :line]

  @module ~S"[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*"
  @module_line Regex.compile!("^(#{@module})$")
  @tree_line Regex.compile!("^(#{@module})\\.\\*$")
  @function_line Regex.compile!("^(#{@module})\\.([a-z_][A-Za-z0-9_]*[?!]?)/(\\d+)$")

  @doc """
  Parses one `covers` line: `Module`, `Module.*` or `Module.function/arity`.
  A `#` starts a comment; a line that is blank once the comment is gone is `:blank`.
  """
  @spec parse(String.t()) :: {:ok, ref()} | :blank | {:error, String.t()}
  def parse(line) do
    text = line |> String.split("#", parts: 2) |> hd() |> String.trim()

    cond do
      text == "" ->
        :blank

      match = Regex.run(@function_line, text) ->
        [_, module, function, arity] = match
        {:ok, {:function, module, function, String.to_integer(arity)}}

      match = Regex.run(@tree_line, text) ->
        {:ok, {:tree, Enum.at(match, 1)}}

      match = Regex.run(@module_line, text) ->
        {:ok, {:module, Enum.at(match, 1)}}

      true ->
        {:error,
         "covers line `#{text}` is not a module (`MyApp.Calc`), a tree (`MyApp.Calc.*`) " <>
           "or a function (`MyApp.Calc.add/2`)"}
    end
  end

  @doc "The reference as written in a `covers` block."
  @spec describe(ref()) :: String.t()
  def describe({:module, module}), do: module
  def describe({:tree, module}), do: module <> ".*"
  def describe({:function, module, function, arity}), do: "#{module}.#{function}/#{arity}"

  @doc """
  The module names to mutate for these references, as `--module` would name
  them: a module, a function's module, and a tree as `Module.*` (expanded by
  `expand/2` once the project's modules are known).
  """
  @spec module_names([t()]) :: [String.t()]
  def module_names(covers) do
    covers
    |> Enum.map(fn
      %__MODULE__{ref: {:tree, module}} -> module <> ".*"
      %__MODULE__{ref: {:module, module}} -> module
      %__MODULE__{ref: {:function, module, _, _}} -> module
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Expands a module name: `Module.*` becomes `Module` and every module whose
  name starts with `Module.`, out of `modules` (names without `Elixir.`);
  any other name is itself.
  """
  @spec expand(String.t(), [String.t()]) :: [String.t()]
  def expand(name, modules) do
    case String.split_at(name, -2) do
      {root, ".*"} ->
        Enum.filter(modules, &(&1 == root or String.starts_with?(&1, root <> "."))) |> Enum.sort()

      _ ->
        [name]
    end
  end

  @doc """
  The modules of the running Mix project's applications (every app of an
  umbrella), as names without `Elixir.`. Empty outside a Mix project.
  """
  @spec project_modules() :: [String.t()]
  def project_modules do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      apps =
        if Mix.Project.umbrella?(),
          do: Map.keys(Mix.Project.apps_paths()),
          else: [Mix.Project.config()[:app]]

      for app <- apps,
          app != nil,
          Application.load(app) in [:ok, {:error, {:already_loaded, app}}],
          module <- Application.spec(app, :modules) || [] do
        inspect(module)
      end
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  How specifically `ref` names the code at `module` (a name without `Elixir.`)
  and `function` (`"name/arity"`, or `nil` for code outside a function):
  `nil` when it doesn't, a larger tuple the more specific it is.
  """
  @spec specificity(ref(), String.t(), String.t() | nil) :: tuple() | nil
  def specificity({:function, module, function, arity}, module, at) do
    if at == "#{function}/#{arity}", do: {3, 0}
  end

  def specificity({:function, _, _, _}, _module, _at), do: nil
  def specificity({:module, module}, module, _at), do: {2, 0}
  def specificity({:module, _}, _module, _at), do: nil

  def specificity({:tree, root}, module, _at) do
    if module == root or String.starts_with?(module, root <> "."),
      do: {1, length(String.split(root, "."))}
  end

  @doc """
  The primitives that own the code at `module`/`function` by the most-specific
  rule. `primitives` maps a primitive id to its `covers` references.
  """
  @spec owners(%{String.t() => [t()]}, String.t(), String.t() | nil) :: [String.t()]
  def owners(primitives, module, function) do
    scored =
      for {id, covers} <- primitives,
          score = best(covers, module, function),
          score != nil,
          do: {id, score}

    case scored do
      [] ->
        []

      scored ->
        best = scored |> Enum.map(&elem(&1, 1)) |> Enum.max()
        for({id, ^best} <- scored, do: id) |> Enum.sort()
    end
  end

  defp best(covers, module, function) do
    covers
    |> Enum.map(&specificity(&1.ref, module, function))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  @doc """
  Whether the reference names code the running VM can load: the module (or,
  for a tree, the root or a module under it among `modules`) and, for a
  function, a public function of that name and arity.
  """
  @spec exists?(ref(), [String.t()]) :: boolean()
  def exists?({:module, module}, _modules), do: loaded?(module)

  def exists?({:tree, root}, modules),
    do: loaded?(root) or Enum.any?(expand(root <> ".*", modules), &loaded?/1)

  def exists?({:function, module, function, arity}, _modules) do
    with mod when is_atom(mod) <- to_module(module),
         true <- Code.ensure_loaded?(mod) do
      Enum.any?(mod.__info__(:functions) ++ mod.__info__(:macros), fn {f, a} ->
        Atom.to_string(f) == function and a == arity
      end)
    else
      _ -> false
    end
  end

  defp loaded?(module) do
    case to_module(module) do
      mod when is_atom(mod) -> Code.ensure_loaded?(mod)
      _ -> false
    end
  end

  # No new atom: the module's atom if it already exists, else a string (never loaded).
  defp to_module(name) do
    String.to_existing_atom("Elixir." <> String.replace_prefix(name, "Elixir.", ""))
  rescue
    ArgumentError -> name
  end
end
