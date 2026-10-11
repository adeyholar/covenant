defmodule Covenant.Target do
  @moduledoc """
  Resolves the `target` of a `kind: exception` block to code and checks that
  it still exists.

  Accepted forms (backticks are stripped by the parser):

  * `Example.Greeter.clamp/1` — a function or macro, checked with
    `Code.ensure_loaded?/1` and the module's exports;
  * `Example.Greeter` — a module;
  * `lib/example/greeter.ex` — a file, relative to the project root and not leaving it.

  A target is contract data, so its names are never turned into atoms: a module is its atom when
  that atom already exists and its name (a string) when it does not, a function is its name.
  """

  @type t ::
          {:function, module() | String.t(), String.t(), non_neg_integer()}
          | {:module, module() | String.t()}
          | {:file, Path.t()}

  @function ~r/^([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_]*[?!]?)\/(\d+)$/
  @module ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/

  @doc "Parses a target string."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(target) when is_binary(target) do
    target = String.trim(target)

    cond do
      match = Regex.run(@function, target) ->
        [_, module, function, arity] = match

        {:ok, {:function, to_module(module), function, String.to_integer(arity)}}

      Regex.match?(@module, target) ->
        {:ok, {:module, to_module(target)}}

      String.contains?(target, "/") or String.ends_with?(target, [".ex", ".exs"]) ->
        cond do
          Path.type(target) == :absolute or String.starts_with?(target, "~") ->
            {:error,
             "target `#{target}` must be a path relative to the project root, not an absolute or `~` path"}

          within?(target, "/project") ->
            {:ok, {:file, target}}

          true ->
            {:error, "target `#{target}` is outside the project root"}
        end

      true ->
        {:error,
         "cannot read target `#{target}`; expected `Module.function/arity`, `Module` or a file path"}
    end
  end

  # No new atom: the module's atom if it already exists, else its name.
  defp to_module(name) do
    String.to_existing_atom("Elixir." <> String.replace_prefix(name, "Elixir.", ""))
  rescue
    ArgumentError -> name
  end

  @doc """
  True when `path`, expanded against `root`, is `root` or lies under it. `..`, an absolute path
  and `~` all expand before the test. Symlinks are not resolved: a link inside the root that
  points outside it is followed.
  """
  @spec within?(Path.t(), Path.t()) :: boolean()
  def within?(path, root) do
    root = Path.expand(root)
    expanded = Path.expand(path, root)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  @doc "True when the target still exists. Files are resolved against `root`."
  @spec exists?(t(), Path.t()) :: boolean()
  def exists?({:function, module, function, arity}, _root) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.any?(module.module_info(:exports), fn
        {name, ^arity} ->
          Atom.to_string(name) == function

        {name, macro_arity} ->
          macro_arity == arity + 1 and Atom.to_string(name) == "MACRO-" <> function
      end)
  end

  def exists?({:function, _name, _function, _arity}, _root), do: false
  def exists?({:module, module}, _root) when is_atom(module), do: Code.ensure_loaded?(module)
  def exists?({:module, _name}, _root), do: false

  def exists?({:file, path}, root),
    do: within?(path, root) and root |> Path.join(path) |> File.exists?()

  @doc "Describes a parsed target for messages."
  @spec describe(t()) :: String.t()
  def describe({:function, module, function, arity}),
    do: "#{module_name(module)}.#{function}/#{arity}"

  def describe({:module, module}), do: module_name(module)
  def describe({:file, path}), do: path

  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(name), do: name
end
