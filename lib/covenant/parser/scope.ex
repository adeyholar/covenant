defmodule Covenant.Parser.Scope do
  @moduledoc """
  Parses `system/scope.yml` into `Covenant.Contract.Ceiling` structs.

  See `Covenant.Contract.Ceiling` for the file format.
  """

  alias Covenant.Contract.Ceiling
  alias Covenant.Error

  @item_line ~r/^-[ \t]/

  @doc "Reads and parses a scope file."
  @spec parse_file(Path.t()) :: {:ok, [Ceiling.t()]} | {:error, [Error.t()]}
  def parse_file(path) do
    case File.read(path) do
      {:ok, text} ->
        parse(text, path)

      {:error, reason} ->
        {:error, [Error.new(path, nil, "cannot read file: #{:file.format_error(reason)}")]}
    end
  end

  @doc "Parses `text` as a scope file; `file` is used for provenance."
  @spec parse(String.t(), Path.t()) :: {:ok, [Ceiling.t()]} | {:error, [Error.t()]}
  def parse(text, file) do
    if String.trim(text) == "", do: {:ok, []}, else: parse_document(text, file)
  end

  defp parse_document(text, file) do
    case Covenant.Parser.Records.read_document(text, file) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, items} when is_list(items) ->
        lines = item_lines(text)

        items
        |> Enum.with_index()
        |> Enum.map(fn {item, i} -> ceiling(item, i, Enum.at(lines, i, 1), file) end)
        |> collect()

      {:ok, _} ->
        {:error, [Error.new(file, 1, "scope.yml must be a YAML list of ceilings")]}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp collect(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, c} -> c end)}
      {_, errors} -> {:error, Enum.flat_map(errors, fn {:error, e} -> e end)}
    end
  end

  defp item_lines(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(@item_line, line) end)
    |> Enum.map(fn {_, n} -> n end)
  end

  defp ceiling(%{} = item, index, line, file) do
    label = "ceiling ##{index + 1}#{if is_binary(item["name"]), do: " `#{item["name"]}`"}"

    with {:ok, name} <- fetch_string(item, "name", label, file, line),
         {:ok, limit} <- fetch_ceiling(item, label, file, line),
         {:ok, counter} <- counter(item["counter"], label, file, line),
         :ok <- text(item, "why", label, file, line),
         :ok <- text(item, "record", label, file, line) do
      {:ok,
       %Ceiling{
         name: name,
         ceiling: limit,
         counter: counter,
         why: item["why"],
         record: item["record"],
         file: file,
         line: line
       }}
    end
  end

  defp ceiling(_item, index, line, file),
    do: {:error, [Error.new(file, line, "ceiling ##{index + 1} must be a mapping")]}

  defp text(item, key, label, file, line) do
    case Map.get(item, key) do
      value when is_map(value) or is_list(value) ->
        {:error, [Error.new(file, line, "#{label} `#{key}` must be text")]}

      _ ->
        :ok
    end
  end

  defp fetch_string(item, key, label, file, line) do
    case Map.get(item, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, [Error.new(file, line, "#{label} must have a `#{key}`")]}
    end
  end

  defp fetch_ceiling(item, label, file, line) do
    case Map.get(item, "ceiling") do
      n when is_integer(n) and n >= 0 ->
        {:ok, n}

      _ ->
        {:error, [Error.new(file, line, "#{label} must have a non-negative integer `ceiling`")]}
    end
  end

  defp counter(%{"kind" => "glob", "pattern" => pattern}, _label, _file, _line)
       when is_binary(pattern),
       do: {:ok, {:glob, pattern}}

  defp counter(
         %{"kind" => "module", "module" => module, "function" => function},
         _label,
         _file,
         _line
       )
       when is_binary(module) and is_binary(function) do
    {:ok, {:module, module, function}}
  end

  defp counter(_, label, file, line) do
    {:error,
     [
       Error.new(
         file,
         line,
         "#{label} needs a `counter` of kind `glob` (with `pattern`) or `module` (with `module` and `function`)"
       )
     ]}
  end
end
