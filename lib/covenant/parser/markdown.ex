defmodule Covenant.Parser.Markdown do
  @moduledoc """
  Parses intent files (heavy form), obligations files (light form) and the
  system intent into `Covenant.Contract.Component` structs.

  The parser is deliberately small: it reads `#` headings outside fenced code
  blocks, splits the document into `##` sections, and reads obligation blocks
  of the form

  ```markdown
  ### <component id>.I<n> — <title>
  - **field:** value
  ```

  Everything else is kept as section body text so that `mix covenant.regen`
  can hand it to a regenerator verbatim. Every problem is reported with the
  line it was found on.

  A file may open with YAML front matter between two `---` lines; it is parsed
  into the component's `meta`. The only key the convention gives a meaning to
  is `modules:`, a list of module names (`Covenant.Mutate.Modules`).
  """

  alias Covenant.Contract.{Component, Obligation, Section}
  alias Covenant.Error

  @heavy_sections [
    "Purpose",
    "Scope",
    "Environment facts",
    "Public surface",
    "Invariants",
    "Decisions",
    "Orderings",
    "Known limits",
    "Regeneration brief"
  ]

  @revision_log_header ~r/^\|\s*Rev\s*\|\s*Date\s*\|\s*Change\s*\|\s*Driver\s*\|/

  @heading ~r/^(\#{1,6})[ \t]+(.+?)[ \t]*\#*[ \t]*$/
  @field ~r/^[ \t]*[-*][ \t]+\*\*([a-z_]+):\*\*[ \t]*(.*)$/
  @block_heading ~r/^(\S+)[ \t]+(?:—|–|--|-)[ \t]+(.+)$/
  @block_id_like ~r/^[a-z0-9_.]+\.I[0-9]+$/
  @fence ~r/^[ \t]*(```|~~~)/

  @typep token ::
           {:heading, 1..6, String.t(), pos_integer()}
           | {:field, String.t(), String.t(), pos_integer()}
           | {:text, String.t(), pos_integer()}

  @doc "The required `##` headings of a heavy-form intent, in order."
  @spec heavy_sections() :: [String.t()]
  def heavy_sections, do: @heavy_sections

  @doc "Reads and parses a file. See `parse/4`."
  @spec parse_file(Path.t(), String.t(), Component.form()) ::
          {:ok, Component.t()} | {:error, [Error.t()]}
  def parse_file(path, component_id, form) do
    case File.read(path) do
      {:ok, text} ->
        parse(text, path, component_id, form)

      {:error, reason} ->
        {:error, [Error.new(path, nil, "cannot read file: #{:file.format_error(reason)}")]}
    end
  end

  @doc """
  Parses `text` as the intent (`:heavy`), obligations file (`:light`) or
  system intent (`:system`) of `component_id`. `file` is used for provenance.
  """
  @spec parse(String.t(), Path.t(), String.t(), Component.form()) ::
          {:ok, Component.t()} | {:error, [Error.t()]}
  def parse(text, file, component_id, form) do
    {meta, meta_errors, lines} =
      text |> String.split(["\r\n", "\n"]) |> Enum.with_index(1) |> front_matter(file)

    tokens = tokenize(lines)
    sections = sections(tokens, lines)
    {obligations, block_errors} = obligations(tokens, component_id, file, form)
    structure_errors = structure(sections, form, file, last_line(lines))

    case meta_errors ++ block_errors ++ structure_errors do
      [] ->
        {app, name} = split_id(component_id)

        {:ok,
         %Component{
           id: component_id,
           app: app,
           name: name,
           form: form,
           file: file,
           purpose: purpose(sections),
           sections: sections,
           obligations: obligations,
           meta: meta
         }}

      errors ->
        {:error, errors}
    end
  end

  # -- front matter -----------------------------------------------------------

  @module_name ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/

  # YAML between a leading `---` and the next `---`; those lines are blanked so
  # line numbers of everything after them are unchanged.
  defp front_matter([{"---", 1} | rest] = lines, file) do
    case Enum.find(rest, fn {line, _} -> String.trim(line) == "---" end) do
      nil ->
        {%{}, [Error.new(file, 1, "front matter is not closed by a `---` line")], lines}

      {_, close} ->
        yaml =
          rest |> Enum.filter(fn {_, n} -> n < close end) |> Enum.map_join("\n", &elem(&1, 0))

        blanked = Enum.map(lines, fn {line, n} -> if n <= close, do: {"", n}, else: {line, n} end)

        case parse_front_matter(yaml, file) do
          {:ok, meta} -> {meta, [], blanked}
          {:error, errors} -> {%{}, errors, blanked}
        end
    end
  end

  defp front_matter(lines, _file), do: {%{}, [], lines}

  defp parse_front_matter(yaml, file) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, map} when is_map(map) ->
        case Map.get(map, "modules") do
          nil ->
            {:ok, map}

          modules when is_list(modules) ->
            bad = Enum.reject(modules, &(is_binary(&1) and Regex.match?(@module_name, &1)))

            if bad == [],
              do: {:ok, map},
              else:
                {:error,
                 [
                   Error.new(
                     file,
                     2,
                     "front matter `modules` must list module names such as `Example.Counter`, got: #{inspect(bad)}"
                   )
                 ]}

          other ->
            {:error,
             [Error.new(file, 2, "front matter `modules` must be a list, got: #{inspect(other)}")]}
        end

      {:ok, _other} ->
        {:error, [Error.new(file, 1, "front matter must be a YAML mapping")]}

      {:error, %{line: line, message: message}} ->
        {:error, [Error.new(file, line + 1, "invalid front matter YAML: #{message}")]}

      {:error, error} ->
        {:error, [Error.new(file, 1, "invalid front matter YAML: #{Exception.message(error)}")]}
    end
  end

  # The last line with content (a trailing newline yields an empty final line).
  defp last_line(lines) do
    case List.last(lines) do
      {"", n} when n > 1 -> n - 1
      {_, n} -> n
      nil -> 1
    end
  end

  # -- tokens -----------------------------------------------------------------

  @spec tokenize([{String.t(), pos_integer()}]) :: [token()]
  defp tokenize(lines) do
    {tokens, _in_fence?} =
      Enum.reduce(lines, {[], false}, fn {line, n}, {acc, in_fence?} ->
        cond do
          Regex.match?(@fence, line) -> {[{:text, line, n} | acc], not in_fence?}
          in_fence? -> {[{:text, line, n} | acc], true}
          true -> {[classify(line, n) | acc], false}
        end
      end)

    Enum.reverse(tokens)
  end

  defp classify(line, n) do
    cond do
      match = Regex.run(@heading, line) ->
        [_, hashes, title] = match
        {:heading, String.length(hashes), title, n}

      match = Regex.run(@field, line) ->
        [_, key, value] = match
        {:field, key, String.trim(value), n}

      true ->
        {:text, line, n}
    end
  end

  # -- sections ---------------------------------------------------------------

  defp sections(tokens, lines) do
    h2s = for {:heading, 2, title, n} <- tokens, do: {title, n}
    boundaries = for {:heading, level, _, n} <- tokens, level <= 2, do: n
    last = length(lines)

    Enum.map(h2s, fn {title, n} ->
      stop = Enum.find(boundaries, last + 1, &(&1 > n))

      body =
        lines
        |> Enum.filter(fn {_, i} -> i > n and i < stop end)
        |> Enum.map_join("\n", fn {line, _} -> line end)
        |> String.trim()

      %Section{title: title, line: n, body: body}
    end)
  end

  defp purpose(sections) do
    case Enum.find(sections, &(&1.title == "Purpose")) do
      nil ->
        nil

      %Section{body: ""} ->
        nil

      %Section{body: body} ->
        body |> String.split(~r/\n[ \t]*\n/, parts: 2) |> hd() |> String.trim()
    end
  end

  # -- obligation blocks ------------------------------------------------------

  defp obligations(tokens, component_id, file, form) do
    tokens
    |> blocks()
    |> Enum.reduce({[], [], %{}}, fn {title, n, body}, {obls, errors, seen} ->
      case block(title, n, body, component_id, file, form) do
        :skip ->
          {obls, errors, seen}

        {:ok, %Obligation{id: id} = obligation} ->
          case Map.fetch(seen, id) do
            {:ok, first} ->
              message = "obligation `#{id}` is declared twice (first at line #{first})"
              {obls, [Error.new(file, n, message) | errors], seen}

            :error ->
              {[obligation | obls], errors, Map.put(seen, id, n)}
          end

        {:error, new_errors} ->
          {obls, new_errors ++ errors, seen}
      end
    end)
    |> then(fn {obls, errors, _} -> {Enum.reverse(obls), Enum.reverse(errors)} end)
  end

  # Every `###` heading with the tokens that follow it up to the next heading.
  defp blocks(tokens) do
    tokens
    |> Enum.chunk_while(nil, &chunk_block/2, &{:cont, &1, nil})
    |> Enum.reject(&is_nil/1)
  end

  defp chunk_block({:heading, 3, title, n}, current), do: {:cont, current, {title, n, []}}
  defp chunk_block({:heading, _, _, _}, current), do: {:cont, current, nil}
  defp chunk_block(_token, nil), do: {:cont, nil}

  defp chunk_block(token, {title, n, body}), do: {:cont, {title, n, [token | body]}}

  defp block(title, n, body_rev, component_id, file, form) do
    body = Enum.reverse(body_rev)
    fields = fields(body)

    case Regex.run(@block_heading, title) do
      [_, id, block_title] ->
        cond do
          Regex.match?(@block_id_like, id) ->
            build(id, String.trim(block_title), n, fields, component_id, file, form)

          fields == %{} ->
            :skip

          true ->
            {:error, [Error.new(file, n, bad_heading(component_id))]}
        end

      nil ->
        if fields == %{},
          do: :skip,
          else: {:error, [Error.new(file, n, bad_heading(component_id))]}
    end
  end

  defp bad_heading(component_id),
    do: "obligation heading must be `### #{component_id}.I<n> — <title>`"

  # `- **key:** value` lines; an indented line directly after a field continues it.
  defp fields(tokens) do
    tokens
    |> Enum.reduce({%{}, nil}, fn
      {:field, key, value, n}, {acc, _} ->
        {Map.put(acc, key, {value, n}), key}

      {:text, line, _}, {acc, key} when is_binary(key) ->
        if Regex.match?(~r/^[ \t]{2,}\S/, line) do
          {value, n} = acc[key]
          {Map.put(acc, key, {value <> " " <> String.trim(line), n}), key}
        else
          {acc, nil}
        end

      _, {acc, _} ->
        {acc, nil}
    end)
    |> elem(0)
  end

  defp build(id, title, n, fields, component_id, file, form) do
    value = fn key -> fields |> Map.get(key) |> maybe(&elem(&1, 0)) end
    line = fn key -> fields |> Map.get(key) |> maybe(&elem(&1, 1)) end
    kind_name = value.("kind")
    kind = kind_name && Obligation.parse_kind(kind_name)
    status_name = value.("status")
    status = status_name && Obligation.parse_status(status_name)

    errors =
      []
      |> check(
        not Obligation.valid_id?(id) or Obligation.component_of(id) != component_id,
        file,
        n,
        "obligation id `#{id}` must be `#{component_id}.I<n>`"
      )
      |> check(
        kind_name != nil and kind == nil,
        file,
        line.("kind"),
        "obligation `#{id}` has unknown kind `#{kind_name}` " <>
          "(expected one of: #{Enum.join(Obligation.kind_names(), ", ")})"
      )
      |> check(
        status_name != nil and status == nil,
        file,
        line.("status"),
        "obligation `#{id}` has unknown status `#{status_name}` " <>
          "(expected one of: #{Enum.join(Obligation.status_names(), ", ")})"
      )
      |> check(
        kind == :exception and value.("target") in [nil, ""],
        file,
        n,
        "obligation `#{id}` is `kind: exception` but has no `target` naming the code it covers"
      )
      |> missing_fields(id, fields, required_fields(form, kind), file, n)

    case errors do
      [] ->
        {:ok,
         %Obligation{
           id: id,
           title: title,
           component_id: component_id,
           scope: value.("scope"),
           must: value.("must"),
           why: value.("why"),
           kind: kind,
           record: value.("record") |> maybe(&unquote_code/1),
           status: status,
           target: value.("target") |> maybe(&unquote_code/1),
           fields: Map.new(fields, fn {k, {v, _}} -> {k, v} end),
           file: file,
           line: n
         }}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  defp required_fields(:heavy, _kind), do: ~w(scope must why kind status)
  defp required_fields(_form, _kind), do: ~w(scope must kind status)

  defp missing_fields(errors, id, fields, required, file, n) do
    Enum.reduce(required, errors, fn key, acc ->
      case Map.get(fields, key) do
        nil -> [Error.new(file, n, "obligation `#{id}` is missing `#{key}`") | acc]
        {"", line} -> [Error.new(file, line, "obligation `#{id}` has an empty `#{key}`") | acc]
        _ -> acc
      end
    end)
  end

  defp check(errors, true, file, line, message), do: [Error.new(file, line, message) | errors]
  defp check(errors, false, _file, _line, _message), do: errors

  defp maybe(nil, _fun), do: nil
  defp maybe(value, fun), do: fun.(value)

  defp unquote_code(value), do: value |> String.trim() |> String.trim("`")

  # -- structure --------------------------------------------------------------

  defp structure(sections, form, file, line_count) do
    duplicates =
      sections
      |> Enum.group_by(& &1.title)
      |> Enum.flat_map(fn
        {_, [_]} ->
          []

        {title, [first | rest]} ->
          Enum.map(
            rest,
            &Error.new(
              file,
              &1.line,
              "section `## #{title}` is declared twice (first at line #{first.line})"
            )
          )
      end)

    duplicates ++
      required_sections(sections, form, file, line_count) ++ purpose_errors(sections, form, file)
  end

  defp required_sections(sections, :heavy, file, line_count),
    do: required_sections(sections, @heavy_sections, "heavy form", file, line_count)

  defp required_sections(sections, :light, file, line_count),
    do: required_sections(sections, ["Purpose"], "light form", file, line_count)

  defp required_sections(_sections, :system, _file, _line_count), do: []

  defp required_sections(sections, required, form_name, file, line_count) do
    present = Enum.filter(sections, &(&1.title in required))
    index = fn title -> Enum.find_index(required, &(&1 == title)) end

    missing =
      required
      |> Enum.reject(fn title -> Enum.any?(present, &(&1.title == title)) end)
      |> Enum.map(fn title ->
        line =
          present
          |> Enum.filter(&(index.(&1.title) > index.(title)))
          |> Enum.map(& &1.line)
          |> Enum.min(fn -> line_count end)

        Error.new(file, line, "missing required section `## #{title}` (#{form_name})")
      end)

    out_of_order =
      present
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] -> index.(a.title) > index.(b.title) end)
      |> Enum.map(fn [a, b] ->
        Error.new(
          file,
          b.line,
          "section `## #{b.title}` must come before `## #{a.title}` (#{form_name})"
        )
      end)

    missing ++ out_of_order
  end

  defp purpose_errors(sections, form, file) do
    case Enum.find(sections, &(&1.title == "Purpose")) do
      nil ->
        []

      %Section{body: "", line: line} ->
        [Error.new(file, line, "section `## Purpose` is empty")]

      %Section{body: body, line: line} when form == :heavy ->
        if Regex.match?(@revision_log_header, body) or String.contains?(body, "| Rev |") do
          []
        else
          [
            Error.new(
              file,
              line,
              "section `## Purpose` lacks the revision log table `| Rev | Date | Change | Driver |` (heavy form)"
            )
          ]
        end

      _ ->
        []
    end
  end

  defp split_id(component_id) do
    case String.split(component_id, ".") do
      [name] -> {name, name}
      parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
    end
  end
end
