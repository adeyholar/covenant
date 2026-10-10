defmodule Covenant.Target do
  @moduledoc """
  Resolves the `target` of a `kind: exception` block to code and checks that
  it still exists.

  Accepted forms (backticks are stripped by the parser):

  * `Example.Greeter.clamp/1` — a function or macro, checked with
    `Code.ensure_loaded?/1` and `function_exported?/3`;
  * `Example.Greeter` — a module;
  * `lib/example/greeter.ex` — a file, relative to the project root.
  """

  @type t ::
          {:function, module(), atom(), non_neg_integer()}
          | {:module, module()}
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

        {:ok,
         {:function, Module.concat([module]), String.to_atom(function), String.to_integer(arity)}}

      Regex.match?(@module, target) ->
        {:ok, {:module, Module.concat([target])}}

      String.contains?(target, "/") or String.ends_with?(target, [".ex", ".exs"]) ->
        {:ok, {:file, target}}

      true ->
        {:error,
         "cannot read target `#{target}`; expected `Module.function/arity`, `Module` or a file path"}
    end
  end

  @doc "True when the target still exists. Files are resolved against `root`."
  @spec exists?(t(), Path.t()) :: boolean()
  def exists?({:function, module, function, arity}, _root) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, function, arity) or macro_exported?(module, function, arity))
  end

  def exists?({:module, module}, _root), do: Code.ensure_loaded?(module)
  def exists?({:file, path}, root), do: root |> Path.join(path) |> File.exists?()

  @doc "Describes a parsed target for messages."
  @spec describe(t()) :: String.t()
  def describe({:function, module, function, arity}),
    do: "#{inspect(module)}.#{function}/#{arity}"

  def describe({:module, module}), do: inspect(module)
  def describe({:file, path}), do: path
end
