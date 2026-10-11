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
        test_paths = Keyword.get(opts, :test_paths, Covenant.test_paths())
        tests = find_tests(component, test_paths, root)

        stub_opts =
          Keyword.take(opts, [:environment]) ++
            [declared_elsewhere: Ownership.declared_elsewhere(contract, component)]

        %{skipped: skipped, possibly_foreign: possibly_foreign} = surface(component, stub_opts)

        File.rm_rf!(out)
        File.mkdir_p!(out)

        stub_opts = stub_opts ++ [root: root, contract: contract]

        files =
          contract_files(contract, component, out, root) ++
            test_files(tests, root, out) ++
            stub_files(component, out, stub_opts) ++
            [brief_file(component, out), prompt_file(component, tests, out, stub_opts)]

        {:ok,
         %{
           dir: out,
           files: files |> Enum.reject(&is_nil/1) |> Enum.sort(),
           skipped: skipped,
           possibly_foreign: possibly_foreign
         }}
    end
  end

  @doc """
  Contract test files that declare `use Covenant.Case, component: "<id>"`, as paths relative to
  `root`. `test_paths` entries (files, directories or globs, absolute or relative to `root`) are
  expanded as `Covenant.Static.expand/1` does for `mix covenant.check --static`. A primitive of
  the sibling layout's tests are the `*_test.exs` files beside its README.
  """
  @spec find_tests(String.t() | Component.t(), [Path.t()], Path.t()) :: [Path.t()]
  def find_tests(%Component{form: :primitive, file: readme}, _test_paths, root) do
    root = Path.expand(root)

    readme
    |> Path.dirname()
    |> Path.join("*_test.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(Path.expand(&1), root))
    |> Enum.sort()
  end

  def find_tests(%Component{id: id}, test_paths, root), do: find_tests(id, test_paths, root)

  def find_tests(component_id, test_paths, root) do
    pattern = ~r/use\s+Covenant\.Case\s*,[^\n]*component:\s*"#{Regex.escape(component_id)}"/
    root = Path.expand(root)

    test_paths
    |> List.wrap()
    |> Enum.map(&Path.expand(&1, root))
    |> Static.expand()
    |> Enum.filter(fn file ->
      case File.read(file) do
        {:ok, source} -> Regex.match?(pattern, source)
        _ -> false
      end
    end)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  # -- contract files ---------------------------------------------------------

  defp contract_files(contract, %Component{form: :primitive, file: readme}, out, root) do
    primitive =
      for source <- [readme, Path.join(Path.dirname(readme), "mutants.md")],
          File.exists?(source) do
        copy(source, Path.join(out, Path.relative_to(Path.expand(source), root)))
      end

    system = Contract.component(contract, "system")

    system_files =
      for source <- [system && system.file, system && system.records_file],
          source != nil,
          File.exists?(source) do
        copy(source, Path.join([out, "contracts", Path.relative_to(source, contract.dir)]))
      end

    primitive ++ system_files
  end

  defp contract_files(contract, component, out, _root) do
    system = Contract.component(contract, "system")

    sources =
      [
        component.file,
        component.records_file,
        system && system.file,
        system && system.records_file
      ] ++
        [Path.join([contract.dir, "system", "decisions.yml"])]

    copies =
      sources
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(fn source ->
        target = Path.join([out, "contracts", Path.relative_to(source, contract.dir)])
        copy(source, target)
      end)

    convention = Path.join(contract.dir, "README.md")

    convention_copy =
      if File.exists?(convention), do: copy(convention, Path.join(out, "CONTRACT_CONVENTION.md"))

    copies ++ List.wrap(convention_copy)
  end

  defp test_files(tests, root, out) do
    Enum.map(tests, fn relative -> copy(Path.expand(relative, root), Path.join(out, relative)) end)
  end

  defp copy(source, target) do
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
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

  defp args(args, _arity) do
    args
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {arg, i} ->
      name = arg |> String.split("::") |> hd() |> String.trim()
      if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*(\s*\\\\.*)?$/, name), do: name, else: "arg#{i}"
    end)
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
    mod = Module.concat([module])

    if Code.ensure_loaded?(mod) and function_exported?(mod, :__info__, 1) do
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
    component
    |> surface(opts)
    |> Map.fetch!(:stub)
    |> Enum.group_by(& &1.module)
    |> Enum.sort()
    |> Enum.map(fn {module, sigs} -> {module, render_stub(component, module, sigs)} end)
  end

  defp render_stub(component, module, sigs) do
    functions =
      Enum.map_join(sigs, "\n", fn sig ->
        arity = length(sig.args)
        signature = "#{sig.function}(#{Enum.join(sig.args, ", ")})"
        head = "#{sig.function}(#{Enum.map_join(sig.args, ", ", &("_" <> &1))})"
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

  defp stub_source(%Component{form: :primitive}),
    do: "Every function here is code the README's covers block names;"

  defp stub_source(%Component{}),
    do: "Every function here is named in the intent's Public surface section;"

  defp stub_files(component, out, opts) do
    component
    |> stubs(opts)
    |> Enum.map(fn {module, source} ->
      path = Path.join([out, "stubs", "lib", Macro.underscore(module) <> ".ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
      path
    end)
  end

  # -- brief and prompt -------------------------------------------------------

  defp brief_file(component, out) do
    body =
      case Component.section(component, "Regeneration brief") do
        nil ->
          "_The #{form_name(component)} for `#{component.id}` has no `## Regeneration brief` section; the obligations and the contract tests are the whole brief._\n"

        section ->
          section.body <> "\n"
      end

    path = Path.join(out, "REGENERATION_BRIEF.md")
    File.write!(path, "# Regeneration brief — #{component.id}\n\n" <> body)
    path
  end

  defp prompt_file(component, tests, out, opts) do
    path = Path.join(out, "PROMPT.md")
    File.write!(path, prompt(component, tests, opts))
    path
  end

  @doc "The brief handed to the regenerating agent."
  @spec prompt(Component.t(), [Path.t()], keyword()) :: String.t()
  def prompt(%Component{} = component, tests, opts \\ []) do
    contract_file =
      if component.form == :primitive do
        Path.relative_to(Path.expand(component.file), Path.expand(opts[:root] || File.cwd!()))
      else
        Path.join(
          "contracts",
          Path.relative_to(component.file, Path.dirname(Path.dirname(component.file)))
        )
      end

    stubs = stubs(component, opts)
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
          "  - _none: the #{form_name(component)} lists no `Module.function/arity` signatures in a `## Public surface` section_"

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
    #{convention_line(component, opts)}- Contract tests (they are the executable obligations; do not edit them):
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

  defp describe_file(%Component{form: :primitive}),
    do:
      "the primitive's Contract README: its obligations, the code its covers block names and,\n  in `mutants.md` beside it when present, the survivors it declares."

  defp describe_file(component),
    do:
      "the component's #{form_name(component)}: purpose, scope,\n  environment facts, public surface, obligations, decisions, orderings and\n  known limits."

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
