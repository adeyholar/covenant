defmodule Covenant.Mutate.Mutator do
  @moduledoc """
  Enumerates and applies mutants at the Elixir AST level.

  `parse/2` reads a source file into an AST where every literal carries its
  position. `sites/2` walks that AST once with `Macro.traverse/4`, numbering
  every node, and asks `Covenant.Mutate.Operators` for the variants at each
  node inside the target modules. `apply/2` re-walks the AST with the same
  numbering and swaps in the k-th replacement. Because both walks are pure
  functions of the source, the mutant set, its order and its ids are the same
  on every machine for the same commit.

  Nothing is mutated inside documentation and typespec attributes, macro and
  guard definitions (their bodies expand in *callers*, compiled long before
  the mutant exists), `use`/`import`/`alias`/`require`, `quote` blocks and
  sigils.

  `compile/2` turns a (mutated) AST back into loaded modules in memory. No
  file is written: the mutant lives in the VM until `Covenant.Mutate.Runner`
  restores the original.
  """

  alias Covenant.Mutate.{Mutant, Operators}

  @skipped_attributes ~w(moduledoc doc typedoc shortdoc spec type typep opaque callback
    macrocallback impl behaviour derive external_resource compile dialyzer deprecated
    optional_callbacks before_compile after_compile on_definition on_load)a

  @skipped_forms ~w(defmacro defmacrop defguard defguardp defdelegate defoverridable use
    import alias require quote)a

  @doc "Parses `source` with positions on every literal."
  @spec parse(String.t(), Path.t()) :: {:ok, Macro.t()} | {:error, String.t()}
  def parse(source, file) do
    Code.string_to_quoted(source,
      file: file,
      columns: true,
      token_metadata: true,
      emit_warnings: false,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}}
    )
    |> case do
      {:ok, ast} -> {:ok, ast}
      {:error, {meta, message, token}} -> {:error, "#{file}:#{meta[:line]}: #{message}#{token}"}
    end
  end

  @doc """
  Every mutant of `ast`, in traversal order. Options:

  * `:file` — the path recorded on each mutant (default `"nofile"`);
  * `:modules` — the module names (strings) to mutate inside; `nil` mutates
    every module in the file.
  """
  @spec sites(Macro.t(), keyword()) :: [Mutant.t()]
  def sites(ast, opts \\ []) do
    file = Keyword.get(opts, :file, "nofile")
    targets = Keyword.get(opts, :modules)

    state = %{counter: 0, modules: [], defs: [], skip: 0, sites: [], file: file, targets: targets}
    {_, state} = Macro.traverse(ast, state, &enter/2, &leave/2)
    Enum.reverse(state.sites)
  end

  @doc "Every mutant of the file's `ast`, numbered `m001`, `m002`, ... in order."
  @spec numbered([Mutant.t()]) :: [Mutant.t()]
  def numbered(mutants) do
    width = max(3, mutants |> length() |> Integer.to_string() |> String.length())

    mutants
    |> Enum.with_index(1)
    |> Enum.map(fn {mutant, i} ->
      %{mutant | id: "m" <> String.pad_leading(Integer.to_string(i), width, "0")}
    end)
  end

  defp enter(node, state) do
    state = %{state | counter: state.counter + 1}
    state = push(node, state)

    if state.skip == 0 and targeted?(state) do
      sites =
        node
        |> Operators.variants()
        |> Enum.map(fn variant ->
          {line, column} = position(variant.anchor)

          %Mutant{
            file: state.file,
            line: line,
            column: column,
            operator: variant.operator,
            from: variant.from,
            to: variant.to,
            module: List.first(state.modules),
            function: List.first(state.defs),
            index: state.counter,
            replacement: variant.replacement
          }
        end)
        |> Enum.reject(&(&1.line == nil))

      {node, %{state | sites: Enum.reverse(sites) ++ state.sites}}
    else
      {node, state}
    end
  end

  defp leave(node, state), do: {node, pop(node, state)}

  defp push({:defmodule, _, [alias, _]}, state),
    do: %{state | modules: [module_name(alias, state.modules) | state.modules]}

  defp push({form, _, [head | _]}, state) when form in [:def, :defp],
    do: %{state | defs: [def_name(head) | state.defs]}

  defp push(node, state) do
    if skip?(node), do: %{state | skip: state.skip + 1}, else: state
  end

  defp pop({:defmodule, _, [_, _]}, state), do: %{state | modules: tl(state.modules)}

  defp pop({form, _, [_ | _]}, state) when form in [:def, :defp],
    do: %{state | defs: tl(state.defs)}

  defp pop(node, state) do
    if skip?(node), do: %{state | skip: state.skip - 1}, else: state
  end

  defp skip?({:@, _, [{name, _, args}]}) when name in @skipped_attributes and is_list(args),
    do: true

  defp skip?({form, _, args}) when form in @skipped_forms and is_list(args), do: true

  defp skip?({form, _, args}) when is_atom(form) and is_list(args),
    do: String.starts_with?(Atom.to_string(form), "sigil_")

  defp skip?(_), do: false

  defp targeted?(%{targets: nil, modules: [_ | _]}), do: true
  defp targeted?(%{targets: nil}), do: false
  defp targeted?(%{targets: targets, modules: [current | _]}), do: current in targets
  defp targeted?(_), do: false

  defp module_name({:__aliases__, _, parts}, [outer | _]) when is_binary(outer),
    do: Enum.join([outer | Enum.map(parts, &part_name/1)], ".")

  defp module_name({:__aliases__, _, parts}, _), do: Enum.map_join(parts, ".", &part_name/1)
  defp module_name({:__block__, _, [atom]}, _) when is_atom(atom), do: inspect(atom)
  defp module_name(atom, _) when is_atom(atom), do: inspect(atom)
  defp module_name(_, _), do: "?"

  defp part_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp part_name(other), do: Operators.describe(other)

  defp def_name({:when, _, [head, _]}), do: def_name(head)

  defp def_name({name, _, args}) when is_atom(name) and is_list(args),
    do: "#{name}/#{length(args)}"

  defp def_name({name, _, nil}) when is_atom(name), do: "#{name}/0"
  defp def_name(_), do: nil

  defp position({_, meta, _}) when is_list(meta), do: {meta[:line], meta[:column]}
  defp position(_), do: {nil, nil}

  @doc "The AST with the mutant's replacement swapped in at its index."
  @spec apply(Macro.t(), Mutant.t()) :: Macro.t()
  def apply(ast, %Mutant{index: index, replacement: replacement}) do
    {mutated, _} =
      Macro.prewalk(ast, 0, fn node, n ->
        n = n + 1
        if n == index, do: {replacement, n}, else: {node, n}
      end)

    mutated
  end

  @doc """
  Removes the literal encoder's single-expression `__block__` wrappers.

  A block of one expression is that expression, so this is always safe, and
  it is required before compiling: the encoder also wraps the `do:` keys of
  definitions, which `def` and friends would not recognise.
  """
  @spec unwrap(Macro.t()) :: Macro.t()
  def unwrap(ast) do
    Macro.prewalk(ast, fn
      {:__block__, _, [single]} -> single
      other -> other
    end)
  end

  @doc """
  Compiles `ast` (after `unwrap/1`) and loads the modules it defines,
  replacing any loaded version. Warnings are swallowed; a compile error is
  returned as a message.
  """
  @spec compile(Macro.t(), Path.t()) :: {:ok, [{module(), binary()}]} | {:error, String.t()}
  def compile(ast, file) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      {result, diagnostics} =
        Code.with_diagnostics(fn ->
          try do
            {:ok, Code.compile_quoted(unwrap(ast), file)}
          rescue
            error -> {:error, Exception.message(error)}
          catch
            kind, reason -> {:error, Exception.format(kind, reason)}
          end
        end)

      case result do
        {:ok, modules} -> {:ok, modules}
        {:error, message} -> {:error, first_error(diagnostics) || message}
      end
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  defp first_error(diagnostics) do
    case Enum.find(diagnostics, &(&1.severity == :error)) do
      nil -> nil
      %{message: message, position: position} -> "#{describe_position(position)}#{message}"
    end
  end

  defp describe_position({line, column}), do: "line #{line}:#{column}: "
  defp describe_position(line) when is_integer(line), do: "line #{line}: "
  defp describe_position(_), do: ""
end
