defmodule Covenant.Parser.Records do
  @moduledoc """
  Parses a `*.decisions.yml` file into `Covenant.Contract.Record` structs.

  The file is a YAML list of records. Required keys are `id` (kebab-case),
  `date` (`YYYY-MM-DD`), `decision`, `driver` and `approved_by`; the rest of
  the convention's keys are optional but type-checked when present.

  YAML parsers do not report where a list item starts, so provenance is
  recovered by scanning the raw text for top-level `- ` items: the n-th
  record is anchored at the n-th item line.
  """

  alias Covenant.Contract.{Condition, Record}
  alias Covenant.Error

  @item_line ~r/^-[ \t]/
  @date ~r/^\d{4}-\d{2}-\d{2}$/

  @doc "Reads and parses a file. See `parse/3`."
  @spec parse_file(Path.t(), String.t()) :: {:ok, [Record.t()]} | {:error, [Error.t()]}
  def parse_file(path, component_id) do
    case File.read(path) do
      {:ok, text} ->
        parse(text, path, component_id)

      {:error, reason} ->
        {:error, [Error.new(path, nil, "cannot read file: #{:file.format_error(reason)}")]}
    end
  end

  @doc "Parses `text` as the decision records of `component_id`; `file` is used for provenance."
  @spec parse(String.t(), Path.t(), String.t()) :: {:ok, [Record.t()]} | {:error, [Error.t()]}
  def parse(text, file, component_id) do
    with {:ok, items} <- read_yaml(text, file) do
      item_lines = item_lines(text)

      {records, errors} =
        items
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          line = Enum.at(item_lines, index, 1)
          record(item, index, line, file, component_id)
        end)
        |> Enum.split_with(&match?({:ok, _}, &1))

      errors = Enum.flat_map(errors, fn {:error, errs} -> errs end)
      records = Enum.map(records, fn {:ok, record} -> record end)

      case errors ++ duplicate_ids(records) do
        [] -> {:ok, records}
        errors -> {:error, errors}
      end
    end
  end

  defp read_yaml(text, file) do
    if String.trim(text) == "", do: {:ok, []}, else: read_yaml_document(text, file)
  end

  defp read_yaml_document(text, file) do
    case YamlElixir.read_from_string(text) do
      {:ok, items} when is_list(items) ->
        {:ok, items}

      {:ok, nil} ->
        {:ok, []}

      {:ok, _other} ->
        {:error, [Error.new(file, 1, "decision records must be a YAML list of records")]}

      {:error, %{line: line, message: message}} ->
        {:error, [Error.new(file, line, "invalid YAML: #{message}")]}

      {:error, error} ->
        {:error, [Error.new(file, 1, "invalid YAML: #{Exception.message(error)}")]}
    end
  end

  defp item_lines(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(@item_line, line) end)
    |> Enum.map(fn {_, n} -> n end)
  end

  defp record(item, index, line, file, component_id) when is_map(item) do
    label =
      case item["id"] do
        id when is_binary(id) and id != "" -> "record `#{id}`"
        _ -> "record ##{index + 1}"
      end

    checks = [
      required(item, "id", label, file, line),
      required(item, "date", label, file, line),
      required(item, "decision", label, file, line),
      required(item, "driver", label, file, line),
      required(item, "approved_by", label, file, line),
      id_shape(item, label, file, line),
      date_shape(item, label, file, line),
      enum(item, "kind", Record.kinds(), label, file, line),
      string_or_list(item, "invariant", label, file, line),
      string_or_list(item, "source", label, file, line),
      string_or_list(item, "depends_on", label, file, line),
      optional_string(item, "superseded_by", label, file, line),
      alternatives(item, label, file, line),
      conditions(item, label, file, line)
    ]

    case List.flatten(checks) do
      [] ->
        {:ok,
         %Record{
           id: item["id"],
           component_id: component_id,
           date: item["date"],
           decision: to_text(item["decision"]),
           driver: to_text(item["driver"]),
           approved_by: to_text(item["approved_by"]),
           evidence: to_text(item["evidence"]),
           expires: to_text(item["expires"]),
           kind: item["kind"],
           notes: to_text(item["notes"]),
           superseded_by: item["superseded_by"],
           invariant: List.wrap(item["invariant"]),
           alternatives: Enum.map(List.wrap(item["alternatives"]), &alternative/1),
           conditions: Enum.map(List.wrap(item["conditions"]), &condition/1),
           depends_on: List.wrap(item["depends_on"]),
           source: List.wrap(item["source"]),
           file: file,
           line: line
         }}

      errors ->
        {:error, errors}
    end
  end

  defp record(_item, index, line, file, _component_id),
    do: {:error, [Error.new(file, line, "record ##{index + 1} must be a mapping")]}

  defp required(item, key, label, file, line) do
    case Map.get(item, key) do
      nil -> Error.new(file, line, "#{label} is missing `#{key}`")
      "" -> Error.new(file, line, "#{label} has an empty `#{key}`")
      _ -> []
    end
  end

  defp id_shape(%{"id" => id}, label, file, line) when is_binary(id) do
    if Record.valid_id?(id),
      do: [],
      else: Error.new(file, line, "#{label} id must be kebab-case (got `#{id}`)")
  end

  defp id_shape(%{"id" => id}, label, file, line),
    do: Error.new(file, line, "#{label} id must be a string (got #{inspect(id)})")

  defp id_shape(_, _, _, _), do: []

  defp date_shape(%{"date" => date}, label, file, line) when is_binary(date) do
    if Regex.match?(@date, date),
      do: [],
      else: Error.new(file, line, "#{label} date must be `YYYY-MM-DD` (got `#{date}`)")
  end

  defp date_shape(%{"date" => date}, label, file, line),
    do:
      Error.new(
        file,
        line,
        "#{label} date must be a quoted `YYYY-MM-DD` string (got #{inspect(date)})"
      )

  defp date_shape(_, _, _, _), do: []

  defp enum(item, key, allowed, label, file, line) do
    value = Map.get(item, key)

    cond do
      is_nil(value) ->
        []

      value in allowed ->
        []

      true ->
        Error.new(
          file,
          line,
          "#{label} has unknown `#{key}` #{inspect(value)} (expected one of: #{Enum.join(allowed, ", ")})"
        )
    end
  end

  defp string_or_list(item, key, label, file, line) do
    case Map.get(item, key) do
      nil ->
        []

      value when is_binary(value) ->
        []

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: [],
          else: Error.new(file, line, "#{label} `#{key}` must be a string or a list of strings")

      _ ->
        Error.new(file, line, "#{label} `#{key}` must be a string or a list of strings")
    end
  end

  defp optional_string(item, key, label, file, line) do
    case Map.get(item, key) do
      nil -> []
      value when is_binary(value) -> []
      _ -> Error.new(file, line, "#{label} `#{key}` must be a string")
    end
  end

  defp alternatives(item, label, file, line) do
    case Map.get(item, "alternatives") do
      nil ->
        []

      list when is_list(list) ->
        list
        |> Enum.with_index(1)
        |> Enum.flat_map(fn
          {%{"option" => option}, _} when is_binary(option) -> []
          {_, i} -> [Error.new(file, line, "#{label} alternative ##{i} must have an `option`")]
        end)

      _ ->
        Error.new(file, line, "#{label} `alternatives` must be a list")
    end
  end

  defp conditions(item, label, file, line) do
    case Map.get(item, "conditions") do
      nil ->
        []

      list when is_list(list) ->
        list
        |> Enum.with_index(1)
        |> Enum.flat_map(fn
          {text, _} when is_binary(text) ->
            []

          {%{"text" => text} = cond, i} when is_binary(text) ->
            condition_check(cond, i, label, file, line)

          {_, i} ->
            [Error.new(file, line, "#{label} condition ##{i} must have a `text`")]
        end)

      _ ->
        Error.new(file, line, "#{label} `conditions` must be a list")
    end
  end

  defp condition_check(%{"check" => %{"kind" => kind}}, _i, _label, _file, _line)
       when is_binary(kind), do: []

  defp condition_check(%{"check" => _}, i, label, file, line),
    do: [
      Error.new(file, line, "#{label} condition ##{i} `check` must be a mapping with a `kind`")
    ]

  defp condition_check(_, _, _, _, _), do: []

  defp alternative(%{"option" => option} = alt),
    do: %{option: option, rejected: to_text(alt["rejected"])}

  defp condition(text) when is_binary(text), do: %Condition{text: text}
  defp condition(%{"text" => text} = cond), do: %Condition{text: text, check: cond["check"]}

  defp duplicate_ids(records) do
    records
    |> Enum.group_by(& &1.id)
    |> Enum.flat_map(fn
      {_, [_]} ->
        []

      {id, [first | rest]} ->
        Enum.map(
          rest,
          &Error.new(
            &1.file,
            &1.line,
            "record `#{id}` is declared twice (first at line #{first.line})"
          )
        )
    end)
  end

  defp to_text(nil), do: nil
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)
end
