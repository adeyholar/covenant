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
  @field ~r/^[ \t]*[-*+][ \t]+\*\*([a-z_]+):\*\*[ \t]*(.*)$/
  # `**Record:**` or `**record**:` — a field the reader would otherwise drop.
  @near_field ~r/^[ \t]*[-*+][ \t]+\*\*([A-Za-z_]+)(:\*\*|\*\*:)/
  # The fields the convention gives a meaning to; only these are policed outside prose.
  @known_fields ~w(scope must why kind status record target)
  @block_heading ~r/^(\S+)[ \t]+(?:—|–|--|-)[ \t]+(.+)$/
  @block_id_like ~r/^[a-z0-9_.]+\.I[0-9]+$/
  @fence ~r/^[ \t]*(`{3,}|~{3,})(.*)$/
  @indented_heading ~r/^ {1,3}(\#{1,6})[ \t]+(.+?)[ \t]*\#*[ \t]*$/

  @typep token ::
           {:heading, 1..6, String.t(), pos_integer()}
           | {:indented_heading, 1..6, String.t(), pos_integer()}
           | {:unclosed_fence, pos_integer()}
           | {:field, String.t(), String.t(), pos_integer()}
           | {:bad_field, String.t(), String.t(), pos_integer()}
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
    text = String.trim_leading(text, "\uFEFF")

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
    {tokens, fence} =
      Enum.reduce(lines, {[], nil}, fn {line, n}, {acc, fence} ->
        case {fence, Regex.run(@fence, line)} do
          {nil, [_, marker, info]} ->
            if String.starts_with?(marker, "`") and String.contains?(info, "`"),
              do: {[classify(line, n) | acc], nil},
              else:
                {[{:text, line, n} | acc],
                 {String.first(marker), String.length(marker), n, indent(line)}}

          {{char, size, _, open_indent}, [_, marker, info]}
          when binary_part(marker, 0, 1) == char ->
            # CommonMark: a closing fence is indented at most three spaces more than the opening.
            if String.length(marker) >= size and String.trim(info) == "" and
                 indent(line) <= open_indent + 3,
               do: {[{:text, line, n} | acc], nil},
               else: {[{:text, line, n} | acc], fence}

          {nil, _} ->
            {[classify(line, n) | acc], nil}

          {_, _} ->
            {[{:text, line, n} | acc], fence}
        end
      end)

    case fence do
      nil -> Enum.reverse(tokens)
      {_, _, n, _} -> Enum.reverse([{:unclosed_fence, n} | tokens])
    end
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  defp classify(line, n) do
    cond do
      match = Regex.run(@heading, line) ->
        [_, hashes, title] = match
        {:heading, String.length(hashes), title, n}

      (match = Regex.run(@indented_heading, line)) && obligation_shaped?(Enum.at(match, 2)) ->
        [_, hashes, title] = match
        {:indented_heading, String.length(hashes), title, n}

      match = Regex.run(@field, line) ->
        [_, key, value] = match
        {:field, key, String.trim(value), n}

      bad = near_field(line) ->
        {key, correct} = bad
        {:bad_field, key, correct, n}

      true ->
        {:text, line, n}
    end
  end

  # A known field written in a way the reader would not recognise, as `{written, correct}`.
  defp near_field(line) do
    with [_, key, tail] <- Regex.run(@near_field, line),
         lower = String.downcase(key),
         true <- lower in @known_fields do
      {key <> if(tail == ":**", do: ":", else: "**:"), lower}
    else
      _ -> nil
    end
  end

  defp obligation_shaped?(title) do
    case Regex.run(@block_heading, title) do
      [_, id, _] -> Regex.match?(@block_id_like, id)
      nil -> false
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
    |> Enum.reduce({[], heading_errors(tokens, file), %{}}, fn
      {:stray_bad, key, correct, n}, {obls, errors, seen} ->
        {obls, [bad_field_error(file, n, key, correct) | errors], seen}

      {:stray, key, n}, {obls, errors, seen} ->
        message = "field `#{key}` is outside an obligation block"
        {obls, [Error.new(file, n, message) | errors], seen}

      {title, n, body}, {obls, errors, seen} ->
        reduce_block(
          block(title, n, body, component_id, file, form),
          n,
          file,
          {obls, errors, seen}
        )
    end)
    |> then(fn {obls, errors, _} ->
      {Enum.reverse(obls), errors |> Enum.reverse() |> Enum.sort_by(& &1.line)}
    end)
  end

  # Problems with how a block is introduced, found whatever the block holds.
  defp heading_errors(tokens, file) do
    tokens
    |> Enum.flat_map(fn
      {:heading, level, title, n} when level != 3 ->
        if obligation_shaped?(title) do
          id = title |> String.split() |> hd()

          message =
            "obligation heading `#{id}` must be a `###` heading, found `#{String.duplicate("#", level)}`"

          [Error.new(file, n, message)]
        else
          []
        end

      {:indented_heading, _, title, n} ->
        id = title |> String.split() |> hd()
        [Error.new(file, n, "obligation heading `#{id}` must start in column 1")]

      {:unclosed_fence, n} ->
        [Error.new(file, n, "code fence opened here is never closed")]

      _ ->
        []
    end)
    |> Enum.reverse()
  end

  defp reduce_block(result, n, file, {obls, errors, seen}) do
    case result do
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
  end

  # Every `###` heading with the tokens that follow it up to the next heading.
  defp blocks(tokens) do
    tokens
    |> Enum.chunk_while(nil, &chunk_block/2, &{:cont, emit(&1), nil})
    |> Enum.reject(&is_nil/1)
  end

  defp chunk_block({:heading, 3, title, n}, current), do: {:cont, emit(current), {title, n, []}}

  defp chunk_block({:heading, _, title, _}, current) do
    {:cont, emit(current), if(obligation_shaped?(title), do: :ignored)}
  end

  defp chunk_block({:indented_heading, _, _, _}, current), do: {:cont, emit(current), :ignored}

  defp chunk_block({:field, key, _, n}, nil) when key in @known_fields,
    do: {:cont, {:stray, key, n}, nil}

  defp chunk_block({:bad_field, key, correct, n}, nil),
    do: {:cont, {:stray_bad, key, correct, n}, nil}

  defp chunk_block(_token, current) when current in [nil, :ignored], do: {:cont, current}

  defp chunk_block(token, {title, n, body}), do: {:cont, {title, n, [token | body]}}

  defp emit(block) when is_tuple(block), do: block
  defp emit(_), do: nil

  defp block(title, n, body_rev, component_id, file, form) do
    body = Enum.reverse(body_rev)
    {fields, repeats} = fields(body)

    bad =
      for {:bad_field, key, correct, line} <- body, do: bad_field_error(file, line, key, correct)

    known? = Enum.any?(@known_fields, &is_map_key(fields, &1))

    result =
      case Regex.run(@block_heading, title) do
        [_, id, block_title] ->
          cond do
            Regex.match?(@block_id_like, id) ->
              build(id, String.trim(block_title), n, {fields, repeats}, component_id, file, form)

            known? ->
              {:error, [Error.new(file, n, bad_heading(component_id))]}

            true ->
              :skip
          end

        nil ->
          if known?,
            do: {:error, [Error.new(file, n, bad_heading(component_id))]},
            else: :skip
      end

    case {result, bad} do
      {_, []} -> result
      {{:error, errors}, _} -> {:error, errors ++ bad}
      {_, _} -> {:error, bad}
    end
  end

  defp bad_field_error(file, line, written, correct) do
    Error.new(file, line, "field `#{written}` must be written `- **#{correct}:** <value>`")
  end

  defp bad_heading(component_id),
    do: "obligation heading must be `### #{component_id}.I<n> — <title>`"

  # `- **key:** value` lines; an indented line directly after a field continues it.
  defp fields(tokens) do
    {fields, _key, repeats} =
      Enum.reduce(tokens, {%{}, nil, []}, fn
        {:field, key, value, n}, {acc, _, repeats} ->
          repeats =
            case acc do
              %{^key => {_, first}} -> [{key, first, n} | repeats]
              _ -> repeats
            end

          {Map.put_new(acc, key, {value, n}), key, repeats}

        {:text, line, _}, {acc, key, repeats} when is_binary(key) ->
          if Regex.match?(~r/^[ \t]{2,}\S/, line) do
            {value, n} = acc[key]
            {Map.put(acc, key, {value <> " " <> String.trim(line), n}), key, repeats}
          else
            {acc, nil, repeats}
          end

        _, {acc, _, repeats} ->
          {acc, nil, repeats}
      end)

    {fields, Enum.reverse(repeats)}
  end

  defp build(id, title, n, {fields, repeats}, component_id, file, form) do
    value = fn key -> fields |> Map.get(key) |> maybe(&elem(&1, 0)) end
    line = fn key -> fields |> Map.get(key) |> maybe(&elem(&1, 1)) end
    kind_name = value.("kind")
    kind = kind_name && Obligation.parse_kind(kind_name)
    status_name = value.("status")
    status = status_name && Obligation.parse_status(status_name)

    errors =
      repeats
      |> Enum.map(fn {key, first, line} ->
        Error.new(file, line, "obligation `#{id}` repeats `#{key}` (first at line #{first})")
      end)
      |> Enum.reverse()
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
