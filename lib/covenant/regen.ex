defmodule Covenant.Regen do
  @moduledoc """
  Writes a regeneration pack for one component: everything a fresh agent
  needs to rebuild the implementation from the Contract, and nothing else.

  ```
  <out>/
    PROMPT.md                         # the brief for the regenerating agent
    REGENERATION_BRIEF.md             # the intent's "Regeneration brief" section
    CONTRACT_CONVENTION.md            # contracts/README.md, when present
    contracts/<app>/<name>.intent.md  # or .obligations.md, verbatim
    contracts/<app>/<name>.decisions.yml
    contracts/system/intent.md        # when present
    contracts/system/decisions.yml    # when present
    <test path relative to the root>  # the component's contract tests, verbatim
                                      # (e.g. test/contract/... or apps/<app>/test/contract/...)
    stubs/lib/<module path>.ex        # public-surface stubs (heavy form)
  ```

  A `.covenant-pack` file in the pack root marks the directory as a pack Covenant wrote; writing
  a pack into an existing `--out` directory clears it only when that marker is there (or the
  directory is empty), and refuses any other non-empty directory without deleting anything.

  The old implementation is deliberately excluded: if the rebuilt
  component diverges, the Contract was missing a sentence.

  ## Modules the component does not own

  A Public surface line may mention `System.halt(1)` or `Scope.put/1` in
  prose, or the collaborators the component calls, and a stub for a module the
  component does not own would shadow the real one. `Covenant.Regen.Ownership`
  decides: a `#### Modules` paragraph in the Public surface (or the front
  matter's `modules:`) is the authoritative list; a module another component
  of the Contract lists belongs to that one; without a list, a module is
  foreign when it lives in OTP, Elixir or a dependency, already implemented
  when it lives in one of the running project's apps, and stubbed when it is
  not loadable and in a namespace the component's obligations use. What it
  cannot tell (a beam anywhere else) is stubbed and reported as
  `:possibly_foreign`; references it dropped come back in `:skipped`, each
  carrying `owner: "<component id>"` when another component lists the module
  and `implemented: true` when the running project already has it. An alias
  (`Scope`, `Repo.Scoped`) is merged into the one known module whose name ends
  in it (`MyApp.Scope`) and dropped when none or several match.
  """

  alias Covenant.Contract
  alias Covenant.Contract.Component
  alias Covenant.Covers
  alias Covenant.Regen.Ownership
  alias Covenant.Static

  # Written into every pack: the component id on the first line, then every file Covenant wrote
  # (relative to the pack). A later run clears only those files, and only in a directory holding it.
  @marker ".covenant-pack"

  @type pack :: %{
          dir: Path.t(),
          files: [Path.t()],
          skipped: [signature()],
          possibly_foreign: [String.t()]
        }

  @doc """
  Writes the pack for `component_id`. Options:

  * `:out` — the pack directory (default `tmp/covenant/regen/<component id>`);
  * `:test_paths` — contract test paths or globs to search, absolute or relative to `:root`
    (default `Covenant.test_paths/0`);
  * `:root` — the project root the test paths are relative to, and the root the tests' paths in
    the pack are relative to (default: the directory that holds the contracts directory);
  * `:environment` — where OTP, Elixir, the dependencies and the project's apps live, to tell
    which modules the component owns (default `Covenant.Regen.Ownership.environment/0`, the
    running VM).

  The modules the other components of `contract` list are foreign to this one and are skipped.
  """
  @spec write_pack(Contract.t(), String.t(), keyword()) :: {:ok, pack()} | {:error, String.t()}
  def write_pack(%Contract{} = contract, component_id, opts \\ []) do
    case Contract.component(contract, component_id) do
      nil ->
        {:error,
         "unknown component `#{component_id}`; known: #{Enum.join(Contract.component_ids(contract), ", ")}"}

      %Component{} = component ->
        root = Path.expand(Keyword.get(opts, :root) || Path.dirname(contract.dir))
        out = Keyword.get(opts, :out, Path.join(["tmp", "covenant", "regen", component_id]))

        if contains?(Path.expand(out), root) do
          {:error,
           "refusing to write the pack to #{out}: it would replace #{root}, which holds the project"}
        else
          pack(contract, component, root, out, opts)
        end
    end
  end

  defp contains?(dir, path), do: path == dir or String.starts_with?(path, dir <> "/")

  # Everything that can fail is computed before the pack directory is replaced.
  defp pack(contract, component, root, out, opts) do
    test_paths = Keyword.get(opts, :test_paths, Covenant.test_paths())
    layout = layout(component, root)

    tests =
      for test <- find_tests(component, test_paths, root) do
        source = Path.expand(test, root)
        {source, in_pack(Path.relative_to(source, layout))}
      end

    stub_opts =
      Keyword.take(opts, [:environment]) ++
        [declared_elsewhere: Ownership.declared_elsewhere(contract, component)]

    %{skipped: skipped, possibly_foreign: possibly_foreign} = surface(component, stub_opts)
    stub_opts = stub_opts ++ [root: root, layout: layout, contract: contract]

    writes =
      Enum.map(contract_files(contract, component, layout) ++ tests, fn {source, target} ->
        {:copy, source, target}
      end) ++
        Enum.map(stubs(component, stub_opts), fn {module, source} ->
          {:write, Path.join(["stubs", "lib", Macro.underscore(module) <> ".ex"]), source}
        end) ++
        [
          {:write, "REGENERATION_BRIEF.md", brief(component)},
          {:write, "PROMPT.md", prompt(component, Enum.map(tests, &elem(&1, 1)), stub_opts)}
        ]

    manifest =
      writes
      |> Enum.map(fn
        {:copy, _source, target} -> target
        {:write, target, _text} -> target
      end)
      |> Enum.sort()

    with :ok <- prepare(out, component.id) do
      write(Path.join(out, @marker), Enum.join([component.id | manifest], "\n") <> "\n")

      files =
        Enum.map(writes, fn
          {:copy, source, target} -> copy(source, Path.join(out, target))
          {:write, target, text} -> write(Path.join(out, target), text)
        end)

      {:ok,
       %{
         dir: out,
         files: Enum.sort(files),
         skipped: skipped,
         possibly_foreign: possibly_foreign
       }}
    end
  end

  # An existing output directory is cleared only when it is a pack Covenant wrote (it holds the
  # marker) and holds nothing but the files the marker lists; an empty or missing one is fine;
  # anything else is refused with nothing deleted.
  defp prepare(out, component_id) do
    marker = Path.join(out, @marker)

    case File.lstat(out) do
      {:error, :enoent} ->
        File.mkdir_p!(out)

      {:ok, %File.Stat{type: :directory}} ->
        cond do
          pack_marker?(marker) ->
            clear_pack(out, marker)

          File.ls!(out) == [] ->
            :ok

          true ->
            {:error,
             "refusing to write the pack to #{out}: it is not empty and holds no #{@marker} " <>
               "marker, so it is not a pack Covenant wrote (nothing was deleted); " <>
               "choose a new or empty directory for `#{component_id}`"}
        end

      {:ok, _} ->
        {:error, "refusing to write the pack to #{out}: it exists and is not a directory"}

      {:error, reason} ->
        {:error, "cannot write the pack to #{out}: #{:file.format_error(reason)}"}
    end
  end

  # A marker is a pack's when it names a component on its first line; an empty or blank one is not.
  defp pack_marker?(marker) do
    File.regular?(marker) and
      match?([_ | _], marker |> File.read!() |> String.split("\n", trim: true))
  end

  defp clear_pack(out, marker) do
    manifest = marker |> File.read!() |> String.split("\n", trim: true) |> tl() |> MapSet.new()
    present = out |> files_under() |> Enum.map(&Path.relative_to(&1, out))
    foreign = Enum.reject(present, &(&1 == @marker or &1 in manifest))

    if foreign == [] do
      # only files found under `out` are deleted: a marker entry such as `../lib/x.ex` names nothing here
      for entry <- present, entry != @marker, do: File.rm(Path.join(out, entry))
      File.rm!(marker)
      prune_empty(out)
      :ok
    else
      {:error,
       "refusing to write the pack to #{out}: the pack directory holds files Covenant didn't " <>
         "write: #{Enum.join(Enum.sort(foreign), ", ")}; move them or choose another --out " <>
         "(nothing was deleted)"}
    end
  end

  # Every file and symlink under `dir`, never following a symlink.
  defp files_under(dir) do
    Enum.flat_map(File.ls!(dir), fn entry ->
      path = Path.join(dir, entry)

      case File.lstat!(path) do
        %File.Stat{type: :directory} -> files_under(path)
        _ -> [path]
      end
    end)
  end

  # Removes the directories under `dir` that are empty, keeping `dir` itself.
  defp prune_empty(dir) do
    for entry <- File.ls!(dir), path = Path.join(dir, entry), File.dir?(path) do
      if match?(%File.Stat{type: :directory}, File.lstat!(path)) do
        prune_empty(path)
        File.rmdir(path)
      end
    end

    :ok
  end

  # Where the pack lays files out from: the root, or for a primitive the directory that holds
  # the sibling layout, so its files land at `contract/<primitive>/...` wherever the root is.
  defp layout(%Component{form: :primitive, file: readme}, _root),
    do: readme |> Path.expand() |> Path.dirname() |> Path.dirname() |> Path.dirname()

  defp layout(_component, root), do: root

  @doc """
  Contract test files that declare `use Covenant.Case, component: "<id>"` (read from the syntax
  tree by `Covenant.Static.scan_source/3`, so any layout of the call counts and a comment or a
  string does not), as paths relative to `root`. `test_paths` entries (files, directories or globs, absolute or relative to `root`) are
  expanded as `Covenant.Static.expand/1` does for `mix covenant.check --static`. A primitive of
  the sibling layout's tests are the test files beside its README and in its subdirectories.
  """
  @spec find_tests(String.t() | Component.t(), [Path.t()], Path.t()) :: [Path.t()]
  def find_tests(%Component{form: :primitive, file: readme}, _test_paths, root) do
    root = Path.expand(root)

    [Path.dirname(readme)]
    |> Static.expand()
    |> Enum.map(&Path.relative_to(Path.expand(&1), root))
    |> Enum.sort()
  end

  def find_tests(%Component{id: id}, test_paths, root), do: find_tests(id, test_paths, root)

  def find_tests(component_id, test_paths, root) do
    root = Path.expand(root)

    test_paths
    |> List.wrap()
    |> Enum.map(&Path.expand(&1, root))
    |> Static.expand()
    |> Enum.filter(fn file ->
      case File.read(file) do
        {:ok, source} ->
          %{modules: modules} = Static.scan_source(source, file)
          Enum.any?(modules, &(&1.component == component_id))

        _ ->
          false
      end
    end)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  # -- contract files ---------------------------------------------------------

  # A path outside the layout stays absolute; the pack holds and records it as `<path without the root slash>`.
  defp in_pack(path), do: String.trim_leading(path, "/")

  # The sibling layout's helper sits in the sibling directory, whatever `sibling_dir` names it:
  # two levels above the primitive's README (`<sibling dir>/<primitive>/README.md`).
  defp primitive_helper(readme),
    do: readme |> Path.dirname() |> Path.dirname() |> Path.join("test_helper.exs")

  # `{source, target}` pairs, the target relative to the pack.
  defp contract_files(contract, %Component{form: :primitive, file: readme}, layout) do
    # `mutants.md` stays out: the survivors it lists describe the implementation.
    helper = primitive_helper(readme)
    convention = Path.join(contract.dir, "README.md")

    primitive =
      for source <- [readme, helper],
          File.exists?(source),
          do: {source, Path.relative_to(Path.expand(source), layout)}

    convention =
      if File.exists?(convention), do: [{convention, "CONTRACT_CONVENTION.md"}], else: []

    primitive ++ system_files(contract) ++ convention
  end

  defp contract_files(contract, component, _layout) do
    sources =
      [component.file, component.records_file] ++
        Enum.map(system_files(contract), &elem(&1, 0)) ++
        [Path.join([contract.dir, "system", "decisions.yml"])]

    copies =
      sources
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(&{&1, Path.join("contracts", Path.relative_to(&1, contract.dir))})

    convention = Path.join(contract.dir, "README.md")

    if File.exists?(convention),
      do: copies ++ [{convention, "CONTRACT_CONVENTION.md"}],
      else: copies
  end

  defp system_files(contract) do
    system = Contract.component(contract, "system")

    for source <- [system && system.file, system && system.records_file],
        source != nil,
        File.exists?(source),
        do: {source, Path.join("contracts", Path.relative_to(source, contract.dir))}
  end

  defp copy(source, target) do
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
    target
  end

  defp write(target, text) do
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, text)
    target
  end

  # -- stubs ------------------------------------------------------------------

  @signature ~r/`([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_]*[?!]?)(?:\(([^)`]*)\)|\/(\d+))(?:\s*::\s*([^`]+))?`/

  @typedoc """
  A public-surface signature read from the intent. A skipped one may also carry `owner` (the
  component that lists its module) or `implemented: true` (the running project has the module).
  """
  @type signature :: %{
          required(:module) => String.t(),
          required(:function) => String.t(),
          required(:args) => [String.t()],
          required(:return) => String.t() | nil,
          required(:doc) => String.t(),
          optional(:owner) => String.t(),
          optional(:implemented) => true
        }

  @doc """
  Reads `Module.function(args) :: type` and `Module.function/arity` signatures from the Public
  surface section. A primitive of the sibling layout has none: its stubs come from its `covers`
  block (`covered/2`).
  """
  @spec signatures(Component.t()) :: [signature()]
  def signatures(%Component{form: :primitive}), do: []

  def signatures(%Component{} = component) do
    case Component.section(component, "Public surface") do
      nil ->
        []

      section ->
        section.body
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          doc = line_doc(line)

          @signature
          |> Regex.scan(line)
          |> Enum.map(fn match ->
            [_, module, function, args, arity, return] = pad(match, 6)

            %{
              module: module,
              function: function,
              args: args(args, arity),
              return: if(return == "", do: nil, else: String.trim(return)),
              doc: doc
            }
          end)
        end)
        |> Enum.uniq_by(&{&1.module, &1.function, length(&1.args)})
    end
  end

  # Regex.scan omits trailing optional groups that did not match.
  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  # The doc is the line's prose with the signature spans that open the line
  # (the ones it defines) removed; every other code span, signature-shaped or
  # not, stays verbatim.
  defp line_doc(line) do
    line
    |> strip_leading_signatures()
    |> String.replace(~r/^[\s\-—–:*]+|[\s\-—–:*]+$/u, "")
  end

  defp strip_leading_signatures(line) do
    rest = String.replace(line, ~r/^[\s\-*|>]+/, "")

    case Regex.run(@signature, rest, return: :index) do
      [{0, length} | _] ->
        rest
        |> binary_part(length, byte_size(rest) - length)
        |> String.replace(~r/^(?:[\s,&\/]|and\b)+/, "")
        |> strip_leading_signatures()

      _ ->
        line
    end
  end

  defp args("", ""), do: []
  defp args("", arity), do: Enum.map(1..String.to_integer(arity)//1, &"arg#{&1}")

  # An argument keeps its `\\ default`; a name that is not a plain variable becomes `argN`.
  defp args(args, _arity) do
    args
    |> split_args()
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {arg, i} ->
      name = arg |> String.split("::") |> hd() |> String.trim()
      if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*(\s*\\\\.*)?$/s, name), do: name, else: "arg#{i}"
    end)
  end

  # Splits on the commas outside brackets, so a default such as `opts \\ [a: 1, b: 2]` stays whole.
  defp split_args(args) do
    {parts, current, _depth} =
      args
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {parts, current, 0} ->
          {[String.trim(current) | parts], "", 0}

        char, {parts, current, depth} when char in ["(", "[", "{"] ->
          {parts, current <> char, depth + 1}

        char, {parts, current, depth} when char in [")", "]", "}"] ->
          {parts, current <> char, max(depth - 1, 0)}

        char, {parts, current, depth} ->
          {parts, current <> char, depth}
      end)

    Enum.reverse([String.trim(current) | parts])
  end

  @doc """
  Splits `signatures/1` into the ones to stub and the references to skip: modules the component
  does not own (see "Modules the component does not own" in the module docs), plus the modules
  it stubbed but could not be sure it owns (`:possibly_foreign`). A stubbed alias has its
  module rewritten to the one it resolves to. Options: `:environment` replaces the running VM
  (`Covenant.Regen.Ownership.environment/0`); `:declared_elsewhere` is the modules the other
  components list, `%{module => component id}` (`Covenant.Regen.Ownership.declared_elsewhere/2`).
  """
  @spec surface(Component.t(), keyword()) :: %{
          stub: [signature()],
          skipped: [signature()],
          possibly_foreign: [String.t()]
        }
  def surface(component, opts \\ [])

  def surface(%Component{form: :primitive} = component, opts),
    do: %{stub: covered(component, opts), skipped: [], possibly_foreign: []}

  def surface(%Component{} = component, opts) do
    environment = Keyword.get_lazy(opts, :environment, &Ownership.environment/0)
    elsewhere = Keyword.get(opts, :declared_elsewhere, %{})

    %{stub: stub} =
      parts = Ownership.partition(component, signatures(component), environment, elsewhere)

    %{parts | stub: Enum.uniq_by(stub, &{&1.module, &1.function, length(&1.args)})}
  end

  @doc """
  The signatures a primitive's `covers` block names: each function it names, and the public
  functions of each module it names (a tree's modules among the project's), as far as the running
  VM can load them, minus the functions another primitive covers more specifically. Options:
  `:contract` (the other primitives; default none), `:modules` (the project's modules a tree may
  name; default `Covenant.Covers.project_modules/0`).
  """
  @spec covered(Component.t(), keyword()) :: [signature()]
  def covered(%Component{form: :primitive, id: id, covers: covers}, opts \\ []) do
    modules = Keyword.get_lazy(opts, :modules, &Covers.project_modules/0)

    primitives =
      case opts[:contract] do
        %Contract{components: components} ->
          for {pid, %Component{form: :primitive, covers: c}} <- components,
              into: %{},
              do: {pid, c}

        nil ->
          %{id => covers}
      end

    covers
    |> Enum.flat_map(&functions(&1.ref, modules))
    |> Enum.uniq()
    |> Enum.filter(fn {module, function, arity} ->
      id in Covers.owners(primitives, module, "#{function}/#{arity}")
    end)
    |> Enum.sort()
    |> Enum.map(fn {module, function, arity} ->
      %{
        module: module,
        function: function,
        args: args("", Integer.to_string(arity)),
        return: nil,
        doc: ""
      }
    end)
  end

  defp functions({:function, module, function, arity}, _modules), do: [{module, function, arity}]
  defp functions({:module, module}, _modules), do: exports(module)

  defp functions({:tree, root}, modules),
    do: Enum.flat_map(Covers.expand(root <> ".*", modules), &exports/1)

  defp exports(module) do
    mod = Ownership.module_atom(module)

    if mod != nil and Code.ensure_loaded?(mod) and function_exported?(mod, :__info__, 1) do
      for {function, arity} <- mod.__info__(:functions),
          name = Atom.to_string(function),
          not String.starts_with?(name, "__"),
          do: {module, name, arity}
    else
      []
    end
  end

  @doc "Renders one stub module per public-surface module the component owns."
  @spec stubs(Component.t(), keyword()) :: [{String.t(), String.t()}]
  def stubs(%Component{} = component, opts \\ []) do
    render_all(component, surface(component, opts).stub)
  end

  defp render_all(component, signatures) do
    signatures
    |> Enum.group_by(& &1.module)
    |> Enum.sort()
    |> Enum.map(fn {module, sigs} -> {module, render_stub(component, module, sigs)} end)
  end

  defp render_stub(component, module, sigs) do
    functions =
      sigs
      |> drop_covered_by_defaults()
      |> Enum.map_join("\n", fn sig ->
        arity = length(sig.args)
        signature = "#{sig.function}(#{Enum.join(sig.args, ", ")})"
        head = "#{sig.function}(#{Enum.map_join(sig.args, ", ", &stub_arg/1)})"
        spec = if sig.return, do: " :: #{sig.return}", else: ""
        doc = if sig.doc == "", do: signature <> spec, else: "#{signature}#{spec} — #{sig.doc}"

        """
          @doc #{inspect(doc, printable_limit: :infinity)}
          def #{head} do
            raise "#{component.id}: #{module}.#{sig.function}/#{arity} is not implemented yet"
          end
        """
      end)

    """
    defmodule #{module} do
      @moduledoc \"\"\"
      Public surface of component `#{component.id}` (regeneration stub).

      Generated by `mix covenant.regen` from #{Path.basename(component.file)}.
      #{stub_source(component)}
      replace the bodies until the contract tests pass.
      \"\"\"

    #{functions}end
    """
  end

  # `limit \\ 10` becomes `_limit \\ 10`.
  defp stub_arg(arg) do
    case String.split(arg, "\\\\", parts: 2) do
      [name, default] -> "_#{String.trim(name)} \\\\ #{String.trim(default)}"
      [name] -> "_" <> name
    end
  end

  # One head with the defaults defines every arity from the required ones up to the full one; a
  # second signature for an arity in that range would conflict with it.
  defp drop_covered_by_defaults(sigs) do
    ranges =
      for sig <- sigs,
          required = Enum.count(sig.args, &(not String.contains?(&1, "\\\\"))),
          required < length(sig.args),
          do: {sig.function, required, length(sig.args)}

    Enum.reject(sigs, fn sig ->
      arity = length(sig.args)

      Enum.any?(ranges, fn {function, required, full} ->
        function == sig.function and arity != full and arity >= required and arity < full
      end)
    end)
  end

  defp stub_source(%Component{form: :primitive}),
    do: "Every function here is code the README's covers block names;"

  defp stub_source(%Component{}),
    do: "Every function here is named in the intent's Public surface section;"

  # -- brief and prompt -------------------------------------------------------

  defp brief(component) do
    body =
      case Component.section(component, "Regeneration brief") do
        nil ->
          "_The #{form_name(component)} for `#{component.id}` has no `## Regeneration brief` section; the obligations and the contract tests are the whole brief._\n"

        section ->
          section.body <> "\n"
      end

    "# Regeneration brief — #{component.id}\n\n" <> body
  end

  @doc "The brief handed to the regenerating agent."
  @spec prompt(Component.t(), [Path.t()], keyword()) :: String.t()
  def prompt(%Component{} = component, tests, opts \\ []) do
    contract_file =
      if component.form == :primitive do
        Path.relative_to(Path.expand(component.file), opts[:layout] || layout(component, nil))
      else
        Path.join(
          "contracts",
          Path.relative_to(component.file, Path.dirname(Path.dirname(component.file)))
        )
      end

    %{stub: signatures, skipped: skipped} = surface(component, opts)
    stubs = render_all(component, signatures)
    obligations = Component.testable_obligations(component)

    test_list =
      case tests do
        [] ->
          "  - _no contract test file declares `use Covenant.Case, component: \"#{component.id}\"` — write them from the obligations first_"

        tests ->
          Enum.map_join(tests, "\n", &"  - `#{&1}`")
      end

    stub_list =
      case stubs do
        [] ->
          none_stubs(component, skipped, opts)

        stubs ->
          Enum.map_join(stubs, "\n", fn {module, _} ->
            "  - `stubs/lib/#{Macro.underscore(module)}.ex` (`#{module}`)"
          end)
      end

    obligation_list =
      Enum.map_join(obligations, "\n", fn o -> "- `#{o.id}` — #{o.title}" end)

    """
    # Regenerate `#{component.id}`

    You are rebuilding the implementation of the component `#{component.id}`
    from its Contract. **You do not have the previous implementation and you
    must not look for it**: no git history, no sibling worktrees, no deployed
    artefacts. If the Contract leaves a question open, record the question
    (see "Questions" below) and make the most conservative choice.

    ## What you have

    - `#{contract_file}` — #{describe_file(component)} Read it in full first.
    #{if component.records_file, do: "- `contracts/#{Path.relative_to(component.records_file, Path.dirname(Path.dirname(component.records_file)))}` — its decision records: the reasons behind every value that looks arbitrary.\n", else: ""}- `contracts/system/` — the whole-product intent and records, when present.
    - `REGENERATION_BRIEF.md` — the questions previous regenerations asked, answered.
    #{convention_line(component, opts)}#{helper_line(component, opts)}- Contract tests (they are the executable obligations; do not edit them):
    #{test_list}
    - Public-surface stubs to start from:
    #{stub_list}

    ## Obligations to satisfy

    #{obligation_list}

    ## How to work

    1. Copy the stubs into `lib/` and the contract tests, at the paths listed
       above, into a fresh project that depends on `covenant`.
    2. Implement until those contract tests are green (`mix test` over their
       paths), then run `mix covenant.check`: every active obligation must have
       a passing test and every `kind: exception` target must exist.
    3. Keep the public surface exactly as listed; persisted formats are pinned
       literally by the tests and must not be renamed.
    4. Code comments cite decision records by id (`record <id>`) instead of
       restating their values.

    ## Questions

    Every question you had to answer by guessing is a missing sentence in the
    intent. Write them to `QUESTIONS.md` in this directory, one per line, with
    the choice you made. They become the next revision of the intent.
    """
  end

  defp none_stubs(%Component{form: :primitive} = component, _skipped, opts) do
    if unavailable(component, opts) == [] do
      "  - _none: the #{form_name(component)}'s covers block names no function_"
    else
      "  - _none: signatures are unavailable; the covers block names code that could not be loaded when " <>
        "this pack was written (#{Enum.join(unavailable(component, opts), ", ")}), so take the " <>
        "public surface from the README and the contract tests_"
    end
  end

  defp none_stubs(_component, [_ | _] = skipped, _opts) do
    modules = skipped |> Enum.map(& &1.module) |> Enum.uniq() |> Enum.sort()

    "  - _none: the signatures in the `## Public surface` section name modules the component " <>
      "does not own or that this project already implements (#{Enum.join(modules, ", ")}), " <>
      "so no stub was written for them_"
  end

  defp none_stubs(component, [], _opts),
    do:
      "  - _none: the #{form_name(component)} lists no `Module.function/arity` signatures in a `## Public surface` section_"

  # The module and tree references of a primitive's covers block that gave no signature: the
  # code was not loadable here, so the stubs do not depend on it being the same everywhere.
  defp unavailable(%Component{covers: covers}, opts) do
    modules = Keyword.get_lazy(opts, :modules, &Covers.project_modules/0)

    for %{ref: ref} <- covers,
        match?({tag, _} when tag in [:module, :tree], ref),
        functions(ref, modules) == [] do
      case ref do
        {:module, module} -> module
        {:tree, root} -> root <> ".*"
      end
    end
  end

  defp describe_file(%Component{form: :primitive}),
    do: "the primitive's Contract README: its obligations and the code its covers block names."

  defp describe_file(component),
    do:
      "the component's #{form_name(component)}: purpose, scope,\n  environment facts, public surface, obligations, decisions, orderings and\n  known limits."

  defp helper_line(%Component{form: :primitive, file: readme}, opts) do
    helper = primitive_helper(readme)

    if opts[:layout] && File.exists?(helper),
      do:
        "- `#{Path.relative_to(Path.expand(helper), Path.expand(opts[:layout]))}` — " <>
          "the helper the contract tests start with.\n",
      else: ""
  end

  defp helper_line(_component, _opts), do: ""

  # A sibling-layout project may have no contracts/README.md to copy.
  defp convention_line(%Component{form: :primitive}, opts) do
    case opts[:contract] do
      %Contract{dir: dir} ->
        if File.exists?(Path.join(dir, "README.md")), do: convention_line(nil, []), else: ""

      _ ->
        convention_line(nil, [])
    end
  end

  defp convention_line(_component, _opts),
    do: "- `CONTRACT_CONVENTION.md` — how obligation blocks and records are written.\n"

  defp form_name(%Component{form: :heavy}), do: "intent"
  defp form_name(%Component{form: :light}), do: "obligations file"
  defp form_name(%Component{form: :system}), do: "system intent"
  defp form_name(%Component{form: :primitive}), do: "Contract README"
end
