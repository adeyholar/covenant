defmodule Covenant.Parser.Primitive do
  @moduledoc """
  Reads the sibling layout: the Contract as flinch, qualm and exhale read it.

  ```
  contract/
    calc/
      README.md         # obligations and a covers block
      calc_test.exs     # the calc Contract tests
      mutants.md        # declared survivors, optional
  ```

  Each direct subdirectory of the Contract directory that holds a README.md
  is a primitive named after the directory; names starting with `.` or `_`
  are skipped, and a subdirectory without a README.md holds helpers.

  In a README, an obligation is a line outside a fence of exactly the form
  `- **A1** text`: a dash, one space, an id of uppercase letters then digits
  in bold, and the text. Its full id is `<primitive>/<id>` (`calc/A1`). Any
  other line that holds a bold id (`* **A1**`, `- **A1:**`, an indented or
  numbered item, a lowercase id, an id with no text) is an error, never
  silently skipped, and so is a fence that is never closed. A fenced `covers`
  block lists the code the primitive covers (`Covenant.Covers`). `covers`
  blocks count only in README.md, and `equivalent` and `unpromised` blocks
  only in mutants.md.

  A Contract test names the obligations it proves with comment lines directly
  above it, `# Contract: calc/A1` (several ids separated by commas, or several
  lines); `comment_ids/2` reads them. Outside the sibling layout only a
  comment naming a primitive id (`claimed_ids/2`) counts, so prose such as
  `# Contract: never negative` is just a comment.
  """

  alias Covenant.Contract.{Component, Obligation}
  alias Covenant.Covers
  alias Covenant.Error
  alias Covenant.Mutate.Survivors.Annotation

  @name ~r/^[a-z][a-z0-9_]*$/
  @obligation ~r/^- \*\*([A-Z]+[0-9]+)\*\*[ \t]+(.+?)[ \t]*$/
  @bold_id ~r/^\s*(?:[-*+]|\d+\.)\s+\*\*[A-Za-z]+[0-9]+[:.]?\*\*/
  @primitive_id ~r/^[a-z][a-z0-9_]*\/[A-Z]+[0-9]+$/
  @fence_open ~r/^ {0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)/
  @atx ~r/^ {0,3}\#{1,6}[ \t]+(.+?)[ \t]*\#*[ \t]*$/
  @setext ~r/^ {0,3}(=+|-+)[ \t]*$/
  @contract_comment ~r/^\s*#\s*Contract:\s*(.*)$/
  @above ~r/^\s*(#|@)/
  @unit ~S"[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*(?:\.[a-z_][A-Za-z0-9_]*[?!]?/\d+)?"
  @declaration Regex.compile!("^(#{@unit}):[ \\t]+(.+)$")
  @occurrence ~r/^(.*\S)[ \t]+#([1-9][0-9]*)$/
  @arrow ~r/\s(?:->|→)\s/u

  @doc "The primitives under `dir`, each as a `Covenant.Contract.Component` of form `:primitive`."
  @spec parse_dir(Path.t()) :: {:ok, [Component.t()]} | {:error, [Error.t()]}
  def parse_dir(dir) do
    results =
      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reject(&(String.starts_with?(&1, ".") or String.starts_with?(&1, "_")))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&(File.dir?(&1) and File.regular?(Path.join(&1, "README.md"))))
      |> Enum.map(&parse_primitive/1)

    case Enum.flat_map(results, fn
           {:error, errors} -> errors
           _ -> []
         end) do
      [] -> {:ok, for({:ok, component} <- results, do: component)}
      errors -> {:error, errors}
    end
  end

  defp parse_primitive(path) do
    name = Path.basename(path)
    readme = Path.join(path, "README.md")

    if Regex.match?(@name, name) do
      parse_readme(File.read!(readme), readme, name)
      |> add_errors(misplaced_blocks(path))
    else
      {:error,
       [
         Error.new(
           path,
           nil,
           "primitive directory `#{name}` must be snake_case (lowercase letters, digits and underscores)"
         )
       ]}
    end
  end

  defp add_errors({:ok, _} = ok, []), do: ok
  defp add_errors({:ok, _}, errors), do: {:error, errors}
  defp add_errors({:error, errors}, more), do: {:error, errors ++ more}

  # `covers` blocks count only in README.md, `equivalent` and `unpromised` only in mutants.md.
  defp misplaced_blocks(path) do
    for file <- path |> Path.join("*.md") |> Path.wildcard() |> Enum.sort(),
        name = Path.basename(file),
        name != "README.md",
        %{kind: :fence, info: info, line: line} <- blocks(File.read!(file)),
        problem = misplaced(name, info),
        problem != nil do
      Error.new(file, line, problem)
    end
  end

  defp misplaced(_file, "covers"), do: "a covers block belongs in README.md"

  defp misplaced(file, info) when info in ["equivalent", "unpromised"] and file != "mutants.md",
    do: "an #{info} block belongs in mutants.md"

  defp misplaced(_file, _info), do: nil

  @doc "Parses one primitive's README.md; `name` is the primitive."
  @spec parse_readme(String.t(), Path.t(), String.t()) ::
          {:ok, Component.t()} | {:error, [Error.t()]}
  def parse_readme(text, file, name) do
    parts = blocks(text)

    obligations =
      for %{kind: :line, text: line_text, line: n} <- parts,
          [_, id, title] <- [Regex.run(@obligation, line_text)] do
        %Obligation{
          id: "#{name}/#{id}",
          title: title,
          component_id: name,
          must: title,
          kind: :functional,
          status: :active,
          file: file,
          line: n
        }
      end

    {covers, cover_errors} =
      for %{kind: :fence, info: "covers", body: body} <- parts,
          {text, n} <- body,
          reduce: {[], []} do
        {covers, errors} ->
          case Covers.parse(text) do
            {:ok, ref} ->
              {covers ++ [%Covers{ref: ref, text: Covers.describe(ref), file: file, line: n}],
               errors}

            :blank ->
              {covers, errors}

            {:error, message} ->
              {covers, errors ++ [Error.new(file, n, message)]}
          end
      end

    misplaced =
      for %{kind: :fence, info: info, line: n} <- parts, info in ["equivalent", "unpromised"] do
        Error.new(file, n, "an #{info} block belongs in mutants.md")
      end

    errors =
      Enum.sort_by(
        duplicates(obligations) ++
          malformed(parts, file) ++ cover_errors ++ misplaced ++ unclosed(parts, file),
        & &1.line
      )

    if errors == [] do
      {:ok,
       %Component{
         id: name,
         app: "contract",
         name: name,
         form: :primitive,
         file: file,
         purpose: purpose(parts),
         obligations: obligations,
         covers: covers
       }}
    else
      {:error, errors}
    end
  end

  defp duplicates(obligations) do
    obligations
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
            "obligation `#{id}` is declared twice (also at line #{first.line})"
          )
        )
    end)
    |> Enum.sort_by(& &1.line)
  end

  # A list item that opens with a bold id but is not `- **A1** text` would
  # otherwise be dropped without a word. Bold words in prose are just prose.
  defp malformed(parts, file) do
    for %{kind: :line, text: text, line: n} <- parts,
        Regex.match?(@bold_id, text),
        not Regex.match?(@obligation, text) do
      Error.new(
        file,
        n,
        "`#{String.trim(text)}` looks like an obligation but is not one: write it as " <>
          "`- **A1** text` (a dash, one space, uppercase letters then digits in bold, then the text)"
      )
    end
  end

  defp unclosed(parts, file) do
    for %{kind: :fence, unclosed: true, line: n, marker: marker} <- parts do
      Error.new(file, n, "the fence opened here with #{marker} is never closed")
    end
  end

  defp purpose(parts) do
    parts
    |> Enum.drop_while(&(&1.kind != :heading))
    |> Enum.drop(1)
    |> Enum.drop_while(&(&1.kind == :line and String.trim(&1.text) == ""))
    |> Enum.take_while(&(&1.kind == :line and String.trim(&1.text) != ""))
    |> case do
      [] -> nil
      lines -> lines |> Enum.map_join(" ", &String.trim(&1.text))
    end
  end

  # -- blocks -----------------------------------------------------------------

  # The text as headings, plain lines and fenced blocks (CommonMark fences:
  # three or more backticks or tildes, closed by the same character at least
  # as many times; the info string is the first word after the fence).
  defp blocks(text) do
    lines = text |> String.split(["\r\n", "\n"]) |> Enum.with_index(1)
    walk(lines, [], nil)
  end

  defp walk([], acc, nil), do: Enum.reverse(acc)

  defp walk([], acc, open),
    do: Enum.reverse([Map.merge(open, %{body: Enum.reverse(open.body), unclosed: true}) | acc])

  defp walk([{text, n} | rest], acc, nil) do
    cond do
      match = Regex.run(@fence_open, text) ->
        [_, marker, info] = match
        walk(rest, acc, %{kind: :fence, info: info, line: n, marker: marker, body: []})

      match = Regex.run(@atx, text) ->
        walk(rest, [%{kind: :heading, text: Enum.at(match, 1), line: n} | acc], nil)

      Regex.match?(@setext, text) and setext_above?(acc) ->
        [%{text: title, line: line} | acc] = acc
        walk(rest, [%{kind: :heading, text: String.trim(title), line: line} | acc], nil)

      true ->
        walk(rest, [%{kind: :line, text: text, line: n} | acc], nil)
    end
  end

  defp walk([{text, n} | rest], acc, open) do
    if closes?(text, open.marker) do
      walk(rest, [%{open | body: Enum.reverse(open.body)} | acc], nil)
    else
      walk(rest, acc, %{open | body: [{text, n} | open.body]})
    end
  end

  # CommonMark: a Setext underline belongs to a plain paragraph. A paragraph holding a list item
  # (or a block quote) is not one: `- **A1** must ...` then `---` is an item and a thematic break.
  defp setext_above?([%{kind: :line, text: text} | _] = acc) do
    String.trim(text) != "" and
      not (acc
           |> Enum.take_while(&(&1.kind == :line and String.trim(&1.text) != ""))
           |> Enum.any?(&container_start?(&1.text)))
  end

  defp setext_above?(_), do: false

  defp container_start?(text),
    do: Regex.match?(~r/^\s*(?:[-*+]|\d{1,9}[.)]|>)(?:\s|$)/, text)

  defp closes?(text, marker) do
    char = String.first(marker)
    trimmed = String.trim(text)

    String.length(trimmed) >= String.length(marker) and
      trimmed == String.duplicate(char, String.length(trimmed))
  end

  # -- mutants.md ---------------------------------------------------------------

  @doc """
  Reads a primitive's `mutants.md`: every line of an `equivalent` or
  `unpromised` block declares a survivor.

  * `Unit: from -> to` declares the one mutant of the unit with that change.
    A unit is `Module.function/arity`, or a bare `Module` for a mutation outside
    any function (`@label "hello"`); the change is the mutation as
    `mix covenant.mutate` prints it (`→` and backticks around `from` and `to`
    accepted). When several of the unit's mutants share the change, an
    occurrence suffix picks one: `Unit: from -> to #2` is the second of them in
    source order, counting every one, killed or not.
  * `Unit: *`, in an `unpromised` block only, declares every survivor of the
    unit: the Contract promises nothing about it. Equivalence is per mutant,
    so a wildcard in an `equivalent` block is an error.

  Each declaration's reason is the nearest heading above its block plus the
  prose between them, and a block with no heading above it is an error, as is
  a fence that is never closed and a line declaring what another already does.
  Which mutant a declaration names is settled against the run
  (`Covenant.Mutate.Survivors.resolve/2`), since a change can contain an arrow
  of its own (`fn x -> x end`).
  """
  @spec declarations(String.t(), Path.t()) :: {:ok, [Annotation.t()]} | {:error, [Error.t()]}
  def declarations(text, file) do
    parts = blocks(text)

    {annotations, errors, _heading, _prose} =
      Enum.reduce(parts, {[], [], nil, []}, fn
        %{kind: :heading, text: heading}, {acc, errors, _, _} ->
          {acc, errors, heading, []}

        %{kind: :line, text: line}, {acc, errors, heading, prose} ->
          {acc, errors, heading, prose ++ [String.trim(line)]}

        %{kind: :fence, info: info} = block, {acc, errors, heading, prose}
        when info in ["equivalent", "unpromised"] ->
          {found, more} = declare(block, heading, prose, file)
          {acc ++ found, errors ++ more, heading, []}

        %{kind: :fence}, {acc, errors, heading, _} ->
          {acc, errors, heading, []}
      end)

    errors = Enum.sort_by(errors ++ repeated(annotations) ++ unclosed(parts, file), & &1.line)
    if errors == [], do: {:ok, annotations}, else: {:error, errors}
  end

  defp declare(%{line: line, info: info}, nil, _prose, file),
    do:
      {[],
       [Error.new(file, line, "the #{info} block has no heading above it to give its reason")]}

  defp declare(%{info: info, body: body}, heading, prose, file) do
    prose = prose |> Enum.join(" ") |> String.replace(~r/\s+/, " ") |> String.trim()
    reason = if prose == "", do: heading, else: "#{heading}: #{prose}"

    Enum.reduce(body, {[], []}, fn {text, n}, {found, errors} ->
      case declaration(String.trim(text), info) do
        :blank ->
          {found, errors}

        {:ok, unit, change, occurrence} ->
          {from, to} = if change, do: split_change(change), else: {nil, nil}

          annotation = %Annotation{
            at: unit,
            operator: "*",
            mutation: change && "`#{from}` → `#{to}`",
            sort: info,
            reason: reason,
            file: file,
            line: n,
            unit: unit,
            change: change,
            occurrence: occurrence,
            from: from,
            to: to
          }

          {found ++ [annotation], errors}

        {:error, message} ->
          {found, errors ++ [Error.new(file, n, message)]}
      end
    end)
  end

  defp declaration("", _info), do: :blank

  defp declaration(text, info) do
    case Regex.run(@declaration, text) do
      [_, unit, "*"] when info == "unpromised" ->
        {:ok, unit, nil, nil}

      [_, _unit, "*"] ->
        {:error,
         "a wildcard can't be equivalent: equivalence is per mutant, so list them, or declare the unit unpromised"}

      [_, unit, rest] ->
        {change, occurrence} =
          case Regex.run(@occurrence, rest) do
            [_, change, k] -> {change, String.to_integer(k)}
            nil -> {rest, nil}
          end

        if Regex.match?(@arrow, change),
          do: {:ok, unit, String.trim(change), occurrence},
          else: {:error, "`#{text}` is not `Unit: from -> to`"}

      nil ->
        {:error, "`#{text}` is not `Module.function/arity: from -> to`"}
    end
  end

  # For display only: which arrow separates `from` from `to` is settled when
  # the change is matched against a mutant's own text.
  defp split_change(change) do
    [_, from, to] = Regex.run(~r/^(.*)\s(?:->|→)\s(.*)$/u, change)
    {unquote_code(from), unquote_code(to)}
  end

  defp unquote_code(text) do
    text = String.trim(text)

    if String.length(text) >= 2 and String.starts_with?(text, "`") and
         String.ends_with?(text, "`"),
       do: text |> String.slice(1..-2//1) |> String.trim(),
       else: text
  end

  @doc """
  Whether a declared change (`from -> to`, `→` or backticks allowed) is the
  mutation `from` → `to`.
  """
  @spec change?(String.t(), String.t(), String.t()) :: boolean()
  def change?(change, from, to) do
    Enum.any?([" -> ", " → "], fn arrow ->
      change == from <> arrow <> to or change == "`#{from}`" <> arrow <> "`#{to}`"
    end)
  end

  defp repeated(annotations) do
    annotations
    |> Enum.group_by(&{&1.unit, normalize(&1.change), &1.occurrence})
    |> Enum.flat_map(fn {_, [first | rest]} ->
      Enum.map(
        rest,
        &Error.new(&1.file, &1.line, "declares what line #{first.line} already declares")
      )
    end)
    |> Enum.sort_by(& &1.line)
  end

  defp normalize(nil), do: nil
  defp normalize(change), do: split_change(change)

  # -- Contract comments ----------------------------------------------------------

  @doc """
  The obligation ids named by `# Contract: ...` comments directly above line
  `line` of `lines` (the source, one string per line): the contiguous comment
  and attribute (`@tag ...`) lines above it, read upwards until a blank line
  or code.
  """
  @spec comment_ids([String.t()], pos_integer()) :: [String.t()]
  def comment_ids(lines, line) do
    lines
    |> attached(line)
    |> Enum.flat_map(fn {text, _n} -> split_ids(text) end)
    |> Enum.uniq()
  end

  @doc """
  The line numbers of the `# Contract:` comments directly above line `line`
  (the ones `comment_ids/2` reads).
  """
  @spec attached_comment_lines([String.t()], pos_integer()) :: [pos_integer()]
  def attached_comment_lines(lines, line),
    do: for({text, n} <- attached(lines, line), Regex.match?(@contract_comment, text), do: n)

  @doc """
  The line numbers of the `# Contract:` comments in `lines` that lie in `range` (default: the
  whole file). Only real comments count: the same text inside a heredoc or a string is not one.
  """
  @spec contract_comment_lines([String.t()], Range.t() | nil) :: [pos_integer()]
  def contract_comment_lines(lines, range \\ nil) do
    candidates =
      for {text, n} <- Enum.with_index(lines, 1), Regex.match?(@contract_comment, text), do: n

    real =
      case Code.string_to_quoted_with_comments(Enum.join(lines, "\n"), emit_warnings: false) do
        {:ok, _ast, comments} -> MapSet.new(comments, & &1.line)
        _ -> nil
      end

    for n <- candidates, real == nil or MapSet.member?(real, n), range == nil or n in range, do: n
  end

  @doc """
  The line range of the innermost `defmodule` of `lines` that holds `line`, or `nil`.
  """
  @spec module_range([String.t()], pos_integer()) :: Range.t() | nil
  def module_range(lines, line) do
    case Code.string_to_quoted(Enum.join(lines, "\n"), token_metadata: true, emit_warnings: false) do
      {:ok, ast} ->
        {_, ranges} =
          Macro.prewalk(ast, [], fn
            {:defmodule, meta, [_, _]} = node, acc ->
              first = meta[:line]
              last = get_in(meta, [:end, :line])
              {node, if(first && last && line in first..last, do: [first..last | acc], else: acc)}

            node, acc ->
              {node, acc}
          end)

        Enum.min_by(ranges, &Range.size/1, fn -> nil end)

      _ ->
        nil
    end
  end

  defp attached(lines, line) do
    lines
    |> Enum.with_index(1)
    |> Enum.take(max(line - 1, 0))
    |> Enum.reverse()
    |> Enum.take_while(fn {text, _} -> Regex.match?(@above, text) end)
    |> Enum.reverse()
  end

  # Ids are separated by commas only, so trailing prose is never an id.
  defp split_ids(text) do
    case Regex.run(@contract_comment, text) do
      [_, ids] -> ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      nil -> []
    end
  end

  @doc """
  The primitive obligation ids (`calc/A1`) named by `# Contract:` comments
  directly above line `line`: what counts as a claim outside the sibling
  layout, where `# Contract: never negative` is only prose.
  """
  @spec claimed_ids([String.t()], pos_integer()) :: [String.t()]
  def claimed_ids(lines, line), do: lines |> comment_ids(line) |> Enum.filter(&primitive_id?/1)

  @doc "True when `line` is a `# Contract:` comment that names a primitive obligation id."
  @spec contract_comment?(String.t()) :: boolean()
  def contract_comment?(line), do: line |> split_ids() |> Enum.any?(&primitive_id?/1)

  @doc "True for a primitive obligation id, `<primitive>/<id>`."
  @spec primitive_id?(String.t()) :: boolean()
  def primitive_id?(id), do: Regex.match?(@primitive_id, id)

  @doc """
  The primitive a file belongs to: the first directory of its path inside
  `sibling_dir`, or `nil` when it lies outside (or directly in) that directory.
  """
  @spec primitive_of(Path.t(), Path.t() | nil) :: String.t() | nil
  def primitive_of(_file, nil), do: nil

  def primitive_of(file, sibling_dir) do
    file = Path.expand(file)
    dir = Path.expand(sibling_dir)

    if String.starts_with?(file, dir <> "/") do
      case file |> Path.relative_to(dir) |> Path.split() do
        [primitive, _ | _] -> primitive
        _ -> nil
      end
    end
  end
end
