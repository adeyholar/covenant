defmodule Covenant.Static do
  @moduledoc """
  Reads contract test files without compiling or running them.

  `mix covenant.check --static` uses this when the code under test does not
  exist yet (a Contract written ahead of its implementation) or cannot be
  built where the check runs. Each file is parsed with
  `Code.string_to_quoted/2`; nothing is evaluated.

  A module counts when its body contains `use Covenant.Case, component: "..."`
  with a literal string. In such a module every `test` and `property` (also
  inside `describe` blocks) is read with the `obligation` tag ExUnit would
  give it, merged as ExUnit merges tags: `@tag` over `@describetag` over
  `@moduletag`, and at each level the last `obligation:` wins (a later tag
  overrides an earlier one, so `@tag :obligation` after a string tag leaves
  `true`, which is a problem). A tag is a literal string or a list of literal
  strings. A test inside `for`, `Enum.each`, `if`, `case` and the like can
  define zero or many tests, so it is never credited and is not an error: it
  is returned in `generated` for the caller to report as needing compiled
  code.

  `scan/1` returns one `Covenant.Results.Test` per test, with state
  `:tagged` (seen, not run), and the problems that `Covenant.Case` would
  raise at compile time, plus the ones only a static reader can have:

  * a file that does not parse;
  * a `component:` or `obligation` tag that is not a literal;
  * a test with no obligation tag;
  * a second `obligation:` tag at one level (ExUnit keeps the last, so the
    first is silently lost; use a list);
  * a `@tag` left dangling before `describe` or at the end of a module;
  * a `test` or `property` with no body (ExUnit fails it as not implemented);
  * a `@describetag` outside a `describe` block (ExUnit raises);
  * a test name used twice in a module (ExUnit rejects the duplicate at
    compile time).

  With `sibling: dir` (the sibling layout's directory), a file under
  `dir/<primitive>/` belongs to that primitive: its `use Covenant.Case` may
  leave out `component:`, and each test's obligations are its `# Contract:`
  comments directly above it merged with its tag, as `Covenant.Case` reads
  them. A test there that names none is a problem, and so is a `# Contract:`
  comment naming a primitive's obligation above a test anywhere else.

  `problems/2` adds the checks that need the Contract: an unknown
  component, a tag naming another component's obligation, and a tag naming
  a retired obligation. A tag naming an obligation the Contract does not
  declare is reported by `Covenant.Check.run/3`.
  """

  alias Covenant.Contract
  alias Covenant.Contract.Obligation
  alias Covenant.Error
  alias Covenant.Parser.Primitive
  alias Covenant.Results.Test

  @typedoc "A contract test module found in a file."
  @type module_entry :: %{
          module: String.t(),
          component: String.t(),
          file: String.t(),
          line: pos_integer() | nil
        }

  @typedoc "A test a static reader cannot credit: `name` is `file:line: test <name>`."
  @type generated :: %{file: String.t(), line: pos_integer() | nil, name: String.t()}

  @type scan :: %{
          files: [String.t()],
          modules: [module_entry()],
          tests: [Test.t()],
          problems: [Error.t()],
          generated: [generated()]
        }

  @doc """
  Expands `paths` (files, directories or globs) to `*_test.exs` files and
  reads each. `opts[:relative_to]` makes the reported file paths relative to
  that directory (default: the current directory); `opts[:sibling]` is the
  sibling layout's directory (default: none).
  """
  @spec scan([Path.t()], keyword()) :: scan()
  def scan(paths, opts \\ []) do
    relative_to = Keyword.get(opts, :relative_to, File.cwd!())
    sibling = opts[:sibling]
    files = expand(paths)

    Enum.reduce(files, %{files: [], modules: [], tests: [], problems: [], generated: []}, fn file,
                                                                                             acc ->
      shown = Path.relative_to(Path.expand(file), Path.expand(relative_to))
      primitive = sibling && Primitive.primitive_of(file, sibling)

      %{modules: modules, tests: tests, problems: problems, generated: generated} =
        scan_source(File.read!(file), shown, primitive)

      %{
        files: acc.files ++ [shown],
        modules: acc.modules ++ modules,
        tests: acc.tests ++ tests,
        problems: acc.problems ++ problems,
        generated: acc.generated ++ generated
      }
    end)
  end

  @doc """
  The test files that `paths` (files, directories or globs) name, sorted and unique: those whose
  name matches the project's `test_pattern` (`Mix.Project.config()`, default `*_test.exs`).
  """
  @spec expand([Path.t()]) :: [Path.t()]
  def expand(paths) do
    pattern = test_pattern()
    matcher = pattern_regex(pattern)

    paths
    |> List.wrap()
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(fn path ->
      if File.dir?(path), do: Path.wildcard(Path.join(path, "**/" <> pattern)), else: [path]
    end)
    |> Enum.filter(&(File.regular?(&1) and Regex.match?(matcher, Path.basename(&1))))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @default_test_pattern "*_test.exs"

  defp test_pattern do
    with true <- Code.ensure_loaded?(Mix.Project),
         pattern when is_binary(pattern) <- Mix.Project.config()[:test_pattern] do
      pattern
    else
      _ -> @default_test_pattern
    end
  end

  defp pattern_regex(pattern) do
    Regex.compile!("^" <> glob_body(String.graphemes(pattern), 0) <> "$")
  end

  # `*`, `?` and `{a,b}` (alternatives, nestable); every other character is literal.
  defp glob_body([], _depth), do: ""
  defp glob_body(["*" | rest], depth), do: ".*" <> glob_body(rest, depth)
  defp glob_body(["?" | rest], depth), do: "." <> glob_body(rest, depth)
  defp glob_body(["{" | rest], depth), do: "(" <> glob_body(rest, depth + 1)
  defp glob_body(["}" | rest], depth) when depth > 0, do: ")" <> glob_body(rest, depth - 1)
  defp glob_body(["," | rest], depth) when depth > 0, do: "|" <> glob_body(rest, depth)
  defp glob_body([char | rest], depth), do: Regex.escape(char) <> glob_body(rest, depth)

  @doc """
  Reads one file's source; `file` is the name used in results and problems, and `primitive` the
  sibling-layout primitive the file sits in (`nil` outside the sibling layout).
  """
  @spec scan_source(String.t(), String.t(), String.t() | nil) :: %{
          modules: [module_entry()],
          tests: [Test.t()],
          problems: [Error.t()],
          generated: [generated()]
        }
  def scan_source(source, file, primitive \\ nil) do
    case Code.string_to_quoted(source, file: file, columns: false, emit_warnings: false) do
      {:ok, ast} ->
        acc = %{
          modules: [],
          tests: [],
          problems: [],
          generated: [],
          seen: %{},
          lines: String.split(source, ["\r\n", "\n"]),
          primitive: primitive
        }

        acc = walk_top(ast, nil, file, acc)

        %{
          modules: Enum.reverse(acc.modules),
          tests: Enum.reverse(acc.tests),
          problems: Enum.reverse(acc.problems),
          generated: Enum.reverse(acc.generated)
        }

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: meta[:line], else: meta
        message = if is_binary(message), do: message, else: inspect(message)

        %{
          modules: [],
          tests: [],
          problems: [Error.new(file, line, "cannot parse: #{message}#{token}")],
          generated: []
        }
    end
  end

  # -- modules ----------------------------------------------------------------

  defp walk_top({:defmodule, meta, [name, [do: body]]}, parent, file, acc) do
    module = module_name(name, parent)
    exprs = block(body)

    acc =
      case find_use(exprs, acc.primitive) do
        nil ->
          unseen_use(exprs, module, meta[:line], file, acc)

        {:ok, component} ->
          entry = %{module: module, component: component, file: file, line: meta[:line]}

          state = %{
            module: module,
            component: component,
            file: file,
            describe: nil
          }

          acc = %{acc | modules: [entry | acc.modules]}
          walk_tests(exprs, state, %{moduletag: [], describetag: [], tag: []}, acc)

        {:error, message} ->
          %{acc | problems: [Error.new(file, meta[:line], message) | acc.problems]}
      end

    Enum.reduce(exprs, acc, &walk_nested(&1, module, file, &2))
  end

  defp walk_top({:__block__, _, exprs}, parent, file, acc),
    do: Enum.reduce(exprs, acc, &walk_top(&1, parent, file, &2))

  defp walk_top(_other, _parent, _file, acc), do: acc

  defp walk_nested({:defmodule, _, _} = node, parent, file, acc),
    do: walk_top(node, parent, file, acc)

  defp walk_nested(_other, _parent, _file, acc), do: acc

  defp module_name({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, parent)
       when is_binary(parent),
       do: Enum.map_join([parent | parts], ".", &to_string/1)

  defp module_name({:__aliases__, _, parts}, parent) do
    name = Enum.map_join(parts, ".", &part/1)
    if parent, do: parent <> "." <> name, else: name
  end

  defp module_name(other, _parent), do: Macro.to_string(other)

  # A module that tags obligations but whose `use` this reader cannot see (a project wrapper
  # around Covenant.Case, an alias) would otherwise be silently ignored.
  defp unseen_use(exprs, module, line, file, acc) do
    {_, tagged} =
      Macro.prewalk(exprs, false, fn
        {:defmodule, _, _}, found ->
          {:ok, found}

        {:@, _, [{level, _, [value]}]} = node, found
        when level in [:tag, :moduletag, :describetag] ->
          {node, found or obligation_value(value) != :none}

        node, found ->
          {node, found}
      end)

    if tagged do
      message =
        "module #{module} has `obligation` tags but no `use Covenant.Case, component: \"...\"` " <>
          "that static mode can see: static mode reads only a literal `use Covenant.Case, " <>
          "component: \"...\"` (or `use <wrapper>, component: \"...\"` for a wrapper listed in " <>
          "`config :covenant, case_modules: [...]`)"

      %{acc | problems: [Error.new(file, line, message) | acc.problems]}
    else
      acc
    end
  end

  defp part(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp part(other), do: Macro.to_string(other)

  defp find_use(exprs, primitive) do
    Enum.find_value(exprs, fn
      {:use, _, [{:__aliases__, _, parts} | rest]} ->
        if Enum.map_join(parts, ".", &part/1) in case_modules(),
          do: use_component(rest, primitive)

      _ ->
        nil
    end)
  end

  # `Covenant.Case` and the wrapper modules the project declares with
  # `config :covenant, case_modules: [MyApp.ContractCase]`, as names.
  defp case_modules do
    wrappers = Application.get_env(:covenant, :case_modules, [])

    [
      "Covenant.Case"
      | wrappers |> List.wrap() |> Enum.map(&(&1 |> inspect() |> String.trim_leading(":")))
    ]
  end

  defp use_component(rest, primitive) do
    opts = List.first(rest) || []

    case is_list(opts) && Keyword.keyword?(opts) && Keyword.fetch(opts, :component) do
      :error when primitive != nil ->
        {:ok, primitive}

      {:ok, component} when is_binary(component) and primitive in [nil, component] ->
        {:ok, component}

      {:ok, component} when is_binary(component) ->
        {:error,
         "use Covenant.Case names component #{inspect(component)}, but the file sits in the " <>
           "sibling layout's `#{primitive}` primitive"}

      {:ok, other} ->
        {:error,
         "use Covenant.Case names component #{Macro.to_string(other)}, which is not a literal string; " <>
           "static mode reads only literals"}

      _ ->
        {:error, "use Covenant.Case without component: \"<app>.<component>\""}
    end
  end

  # -- tests ------------------------------------------------------------------

  @opaque_forms [:def, :defp, :defmacro, :defmacrop, :defmodule, :@, :describe, :test, :property]

  defp walk_tests(exprs, state, tags, acc) do
    {tags, acc} = Enum.reduce(exprs, {tags, acc}, &walk_expr(&1, state, &2))

    if tags.tag != [] do
      {_, line} = List.last(tags.tag)
      where = if state.describe, do: "describe \"#{state.describe}\"", else: "module"
      problem = Error.new(state.file, line, "@tag at the end of the #{where} applies to no test")
      %{acc | problems: [problem | acc.problems]}
    else
      acc
    end
  end

  defp walk_expr({:@, meta, [{:describetag, _, [_]}]}, %{describe: nil} = state, {tags, acc}) do
    problem =
      Error.new(
        state.file,
        meta[:line],
        "@describetag outside a describe block; ExUnit raises when it compiles it"
      )

    {tags, %{acc | problems: [problem | acc.problems]}}
  end

  defp walk_expr({:@, meta, [{level, _, [value]}]}, state, {tags, acc})
       when level in [:tag, :describetag, :moduletag] do
    case obligation_value(value) do
      :none ->
        {tags, acc}

      found ->
        entry =
          case found do
            {:ok, ids} -> {ids, meta[:line]}
            {:error, _} -> {:unreadable, meta[:line]}
          end

        problems =
          case found do
            {:error, shown} ->
              [
                Error.new(
                  state.file,
                  meta[:line],
                  "@#{level} obligation: #{shown} is not a literal string or list of strings; " <>
                    "static mode reads only literals"
                )
              ]

            _ ->
              []
          end

        problems =
          if Map.fetch!(tags, level) != [] or repeated_obligation?(value) do
            problems ++
              [
                Error.new(
                  state.file,
                  meta[:line],
                  "a second `@#{level} obligation:` replaces the first (ExUnit keeps only the last); " <>
                    "tag once with a list"
                )
              ]
          else
            problems
          end

        {Map.update!(tags, level, &(&1 ++ [entry])),
         %{acc | problems: Enum.reverse(problems) ++ acc.problems}}
    end
  end

  defp walk_expr({:describe, meta, [name, [do: body]]}, state, {tags, acc}) do
    acc =
      if tags.tag != [] do
        problem =
          Error.new(
            state.file,
            meta[:line],
            "@tag before describe applies to no test (ExUnit rejects it); move it inside or use @describetag"
          )

        %{acc | problems: [problem | acc.problems]}
      else
        acc
      end

    inner_state = %{
      state
      | describe: literal_name(name)
    }

    inner_tags = %{tags | describetag: [], tag: []}
    acc = walk_tests(block(body), inner_state, inner_tags, acc)
    {%{tags | tag: []}, acc}
  end

  defp walk_expr({kind, meta, [name | rest]}, state, {tags, acc})
       when kind in [:test, :property] do
    acc =
      if has_body?(rest) do
        record_test(kind, name, meta[:line], state, tags, acc)
      else
        problem =
          Error.new(
            state.file,
            meta[:line],
            "#{kind} #{literal_name(name)} has no body; ExUnit fails it as not implemented and it proves nothing"
          )

        %{acc | problems: [problem | acc.problems]}
      end

    {%{tags | tag: []}, acc}
  end

  # A `test` under `for`, `Enum.each`, `if`, `case` and the like can be defined zero or many times
  # (and a `@tag` before it reaches only the first), so static mode cannot credit it. It is not an
  # error either: the scan lists it in `generated` for the task to report.
  defp walk_expr({form, _, _} = node, state, {tags, acc}) when form not in @opaque_forms do
    case nested_tests(node) do
      [] ->
        {tags, acc}

      found ->
        generated =
          for {kind, line, name} <- found,
              do: %{file: state.file, line: line, name: "#{kind} #{name}"}

        {%{tags | tag: []}, %{acc | generated: Enum.reverse(generated) ++ acc.generated}}
    end
  end

  defp walk_expr(_other, _state, tags_acc), do: tags_acc

  defp nested_tests(node) do
    {_, found} =
      Macro.prewalk(node, [], fn
        {kind, meta, [name | _]}, found when kind in [:test, :property] ->
          {nil, [{kind, meta[:line], literal_name(name)} | found]}

        {form, _, _}, found when form in @opaque_forms ->
          {nil, found}

        other, found ->
          {other, found}
      end)

    Enum.reverse(found)
  end

  defp has_body?(rest), do: Enum.any?(rest, &(is_list(&1) and Keyword.has_key?(&1, :do)))

  defp record_test(kind, name, line, state, tags, acc) do
    full_name =
      [Atom.to_string(kind), state.describe, literal_name(name)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    commented =
      if acc.primitive,
        do: Primitive.comment_ids(acc.lines, line || 1),
        else: Primitive.claimed_ids(acc.lines, line || 1)

    {test, problem} =
      case contract_ids(effective(tags), commented, acc.primitive) do
        {:error, message} ->
          {nil, Error.new(state.file, line, "#{full_name} #{message}")}

        :missing ->
          problem =
            Error.new(
              state.file,
              line,
              "#{full_name} has no obligation tag; every test in a Covenant.Case module must be " <>
                "tagged `@tag obligation: \"#{state.component}.I<n>\"` (a list is allowed)"
            )

          {nil, problem}

        :unreadable ->
          {nil, nil}

        ids ->
          {%Test{
             module: state.module,
             name: full_name,
             file: state.file,
             line: line,
             component: state.component,
             obligations: ids,
             state: :tagged
           }, nil}
      end

    acc = if problem, do: %{acc | problems: [problem | acc.problems]}, else: acc
    acc = duplicate_name(acc, state, full_name, line)
    if test, do: %{acc | tests: [test | acc.tests]}, else: acc
  end

  # ExUnit refuses a second test with the same name in a module.
  defp duplicate_name(acc, state, full_name, line) do
    key = {state.module, full_name}

    problem =
      if Map.has_key?(acc.seen, key),
        do:
          "#{full_name} is already defined in #{state.module} at line #{acc.seen[key]}; ExUnit rejects the duplicate"

    acc = %{acc | seen: Map.put_new(acc.seen, key, line)}

    if problem,
      do: %{acc | problems: [Error.new(state.file, line, problem) | acc.problems]},
      else: acc
  end

  # The sibling layout: a primitive's test names its obligations in `# Contract:` comments, its
  # tag, or both; anywhere else a `# Contract:` comment is a problem.
  defp contract_ids(:missing, [], primitive) when primitive != nil,
    do: {:error, "names no obligation; put `# Contract: #{primitive}/<id>` on the line above it"}

  defp contract_ids(:missing, commented, primitive) when primitive != nil, do: commented
  defp contract_ids(:unreadable, _commented, _primitive), do: :unreadable

  defp contract_ids(ids, commented, primitive) when primitive != nil,
    do: Enum.uniq(commented ++ ids)

  defp contract_ids(_ids, [_ | _], nil),
    do:
      {:error,
       "has a `# Contract:` comment, which only Contract tests in the sibling layout's " <>
         "contract/<primitive>/ directories carry; tag it `@tag obligation: ...` instead"}

  defp contract_ids(ids, [], nil), do: ids

  # ExUnit merges @moduletag, then @describetag, then @tag; within a level
  # the last value of a key wins.
  defp effective(tags) do
    Enum.reduce([:moduletag, :describetag, :tag], :missing, fn level, ids ->
      case Map.fetch!(tags, level) do
        [] -> ids
        values -> elem(List.last(values), 0)
      end
    end)
  end

  # ExUnit keeps the last `obligation:` of a keyword list; a bare `:obligation` sets it to `true`.
  defp obligation_value(:obligation), do: {:error, "true"}

  defp obligation_value(value) when is_list(value) do
    if Keyword.keyword?(value) and Keyword.has_key?(value, :obligation) do
      value |> Keyword.get_values(:obligation) |> List.last() |> literal_ids()
    else
      :none
    end
  end

  defp obligation_value(_value), do: :none

  defp repeated_obligation?(value) when is_list(value),
    do: Keyword.keyword?(value) and length(Keyword.get_values(value, :obligation)) > 1

  defp repeated_obligation?(_value), do: false

  defp literal_ids(id) when is_binary(id), do: {:ok, [id]}

  defp literal_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &is_binary/1), do: {:ok, ids}, else: {:error, Macro.to_string(ids)}
  end

  defp literal_ids(other), do: {:error, Macro.to_string(other)}

  defp literal_name(name) when is_binary(name), do: name
  defp literal_name(name), do: Macro.to_string(name)

  defp block({:__block__, _, exprs}), do: exprs
  defp block(nil), do: []
  defp block(expr), do: [expr]

  # -- checks against the Contract --------------------------------------------

  @doc """
  The compile-time checks of `Covenant.Case`, applied to a scan: unknown
  components, tags naming another component's obligation and tags naming
  retired obligations.
  """
  @spec problems(Contract.t(), scan()) :: [Error.t()]
  def problems(%Contract{} = contract, %{modules: modules, tests: tests}) do
    unknown_components =
      for %{component: component} = entry <- modules,
          Contract.component(contract, component) == nil do
        Error.new(
          entry.file,
          entry.line,
          "#{entry.module} uses unknown component `#{component}`; known components: " <>
            Enum.join(Contract.component_ids(contract), ", ")
        )
      end

    known =
      modules
      |> Enum.map(& &1.component)
      |> Enum.filter(&Contract.component(contract, &1))
      |> MapSet.new()

    misplaced =
      for %Test{} = test <- tests,
          MapSet.member?(known, test.component),
          id <- test.obligations,
          problem = misplaced(contract, test, id),
          problem != nil do
        problem
      end

    unknown_components ++ misplaced
  end

  defp misplaced(contract, test, id) do
    case Contract.obligation(contract, id) do
      nil ->
        nil

      %Obligation{component_id: other} when other != test.component ->
        Error.new(
          test.file,
          test.line,
          "#{test.name} is tagged with `#{id}`, which belongs to component `#{other}`, " <>
            "but this module tests `#{test.component}`; move the test to that component's contract test file"
        )

      %Obligation{status: :retired} = obligation ->
        Error.new(
          test.file,
          test.line,
          "#{test.name} is tagged with `#{id}`, which is retired (#{obligation.file}:#{obligation.line}); " <>
            "re-tag the test with the obligation that replaced it"
        )

      %Obligation{} ->
        nil
    end
  end
end
