defmodule Covenant.RegenContractTest do
  use Covenant.Case, component: "covenant.regen", async: true

  alias Covenant.{Contract, Regen}
  alias Covenant.Regen.Ownership
  alias Covenant.ContractBuilder

  setup do
    {:ok, contract: Contract.load!(ContractBuilder.fixture_contracts())}
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I1"
  test "writes the full pack for a heavy component", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")

    assert {:ok, %{dir: ^out, files: files}} =
             Regen.write_pack(contract, "example.counter",
               out: out,
               root: ContractBuilder.fixture_project(),
               test_paths: ["test/contract"]
             )

    assert Enum.map(files, &Path.relative_to(&1, out)) == [
             "CONTRACT_CONVENTION.md",
             "PROMPT.md",
             "REGENERATION_BRIEF.md",
             "contracts/example/counter.decisions.yml",
             "contracts/example/counter.intent.md",
             "contracts/system/decisions.yml",
             "contracts/system/intent.md",
             "stubs/lib/example/counter.ex",
             "test/contract/example/counter_contract_test.exs"
           ]

    assert File.read!(Path.join(out, "contracts/example/counter.intent.md")) ==
             File.read!(
               Path.join(ContractBuilder.fixture_contracts(), "example/counter.intent.md")
             )

    assert File.read!(Path.join(out, "REGENERATION_BRIEF.md")) =~
             "Questions\nanswered in earlier rounds"

    refute File.exists?(Path.join(out, "lib/example/counter.ex"))

    prompt = File.read!(Path.join(out, "PROMPT.md"))
    assert prompt =~ "# Regenerate `example.counter`"
    assert prompt =~ "must not look for it"
    assert prompt =~ "- `example.counter.I1` — A counter never goes below zero"
    refute prompt =~ "example.counter.I5"
    assert prompt =~ "`test/contract/example/counter_contract_test.exs`"
    assert prompt =~ "`stubs/lib/example/counter.ex` (`Example.Counter`)"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I2"
  test "stubs compile and raise until implemented", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")

    {:ok, _} =
      Regen.write_pack(contract, "example.counter",
        out: out,
        root: ContractBuilder.fixture_project(),
        test_paths: ["test/contract"]
      )

    source = File.read!(Path.join(out, "stubs/lib/example/counter.ex"))

    assert source =~ "defmodule Example.Counter do"

    assert source =~
             ~s|@doc "new(opts) :: t — a counter at zero; `opts[:max]` sets the cap (default 100, record `configurable-max`, pinned by `example.counter.I7`)."|

    assert source =~ "def increment(_counter, _by) do"
    assert source =~ "def value(_arg1) do"
    assert source =~ ~s(raise "example.counter: Example.Counter.to_map/1 is not implemented yet")

    renamed =
      String.replace(
        source,
        "defmodule Example.Counter do",
        "defmodule Covenant.RegenTest.Stub do"
      )

    [{module, _}] = Code.compile_string(renamed)
    assert_raise RuntimeError, ~r/not implemented yet/, fn -> module.new([]) end
    assert function_exported?(module, :increment, 2)
    assert function_exported?(module, :to_map, 1)
  end

  @tag obligation: "covenant.regen.I2"
  test "reads signatures in both forms from the public surface", %{contract: contract} do
    sigs = Regen.signatures(Contract.component(contract, "example.counter"))

    assert Enum.map(sigs, &{&1.function, &1.args, &1.return}) == [
             {"new", ["opts"], "t"},
             {"increment", ["counter", "by"], "t"},
             {"decrement", ["counter", "by"], "t"},
             {"value", ["arg1"], nil},
             {"events", ["arg1"], nil},
             {"to_map", ["counter"], "map"}
           ]

    assert Enum.at(sigs, 1).doc == "adds `by`, clamped at `max`."
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I3"
  test "a light component without surface or brief still gets a pack that says so", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "pack")

    assert {:ok, %{files: files}} =
             Regen.write_pack(contract, "example.greeter",
               out: out,
               root: ContractBuilder.fixture_project(),
               test_paths: ["test/contract"]
             )

    relative = Enum.map(files, &Path.relative_to(&1, out))

    assert "contracts/example/greeter.obligations.md" in relative
    assert "test/contract/example/greeter_contract_test.exs" in relative
    refute Enum.any?(relative, &String.starts_with?(&1, "stubs/"))
    refute Enum.any?(relative, &String.contains?(&1, "greeter.decisions"))

    assert File.read!(Path.join(out, "REGENERATION_BRIEF.md")) =~
             "has no `## Regeneration brief` section"

    prompt = File.read!(Path.join(out, "PROMPT.md"))
    assert prompt =~ "lists no `Module.function/arity` signatures"
    assert prompt =~ "the component's obligations file"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I3"
  test "a component without tests says so in the prompt", %{contract: contract, tmp_dir: dir} do
    out = Path.join(dir, "pack")

    {:ok, _} =
      Regen.write_pack(contract, "example.greeter",
        out: out,
        root: dir,
        test_paths: ["test/contract"]
      )

    assert File.read!(Path.join(out, "PROMPT.md")) =~
             ~s(no contract test file declares `use Covenant.Case, component: "example.greeter"`)
  end

  @tag obligation: "covenant.regen.I4"
  test "an unknown component is an error listing the known ones", %{contract: contract} do
    assert {:error, message} =
             Regen.write_pack(contract, "example.nope", out: "/nonexistent/never-written")

    assert message ==
             "unknown component `example.nope`; known: example.counter, example.greeter, system"
  end

  @tag obligation: "covenant.regen.I4"
  test "find_tests matches on the component declaration, through globs" do
    root = ContractBuilder.fixture_project()

    assert Regen.find_tests("example.counter", ["test/contract"], root) == [
             "test/contract/example/counter_contract_test.exs"
           ]

    assert Regen.find_tests("example.counter", ["test/*"], root) == [
             "test/contract/example/counter_contract_test.exs"
           ]

    assert Regen.find_tests("example.nope", ["test/contract"], root) == []
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I5"
  test "an absolute glob finds tests under an umbrella app and the pack keeps their path", %{
    tmp_dir: dir
  } do
    contracts = ContractBuilder.copy_fixture_contracts(Path.join(dir, "contracts"))
    tests = Path.join(dir, "apps/shop/test/contract")
    File.mkdir_p!(tests)
    File.cp_r!(Path.join(ContractBuilder.fixture_project(), "test/contract"), tests)

    glob = Path.join(dir, "apps/*/test/contract")
    relative = "apps/shop/test/contract/example/counter_contract_test.exs"

    assert Regen.find_tests("example.counter", [glob], dir) == [relative]
    assert Regen.find_tests("example.counter", ["apps/*/test/contract"], dir) == [relative]

    out = Path.join(dir, "pack")
    contract = Contract.load!(contracts)

    # no :root — it is the directory that holds the contracts directory
    assert {:ok, %{files: files}} =
             Regen.write_pack(contract, "example.counter", out: out, test_paths: [glob])

    assert relative in Enum.map(files, &Path.relative_to(&1, out))

    assert File.read!(Path.join(out, relative)) ==
             File.read!(Path.join(tests, "example/counter_contract_test.exs"))

    assert File.read!(Path.join(out, "PROMPT.md")) =~ "- `#{relative}`"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I6"
  test "a listed set is authoritative: exactly those modules are stubbed", %{tmp_dir: dir} do
    surface =
      Enum.join(
        [
          "- `Demo.Widget.size/1` — its size.",
          "- `Demo.Widget.paint(widget, color)` — paints; at the end it calls `System.halt(1)`.",
          "- `Mix.raise/1` — mentioned in prose only.",
          "- `Widget.reset/1` — a short alias of `Demo.Widget`.",
          "- `Demo.Dial.read/0` — a dial.",
          "- `Other.Dial.tick/0` — another dial, not listed.",
          "- `Dial.turn/0` — an alias of the one listed dial.",
          "- `Ghost.vanish/0` — no listed module ends in `Ghost`.",
          "- `Ecto.UUID.cast/1` — not listed, and not loadable either.",
          "- `Covenant.Error.format/1` — loadable and in an app of this project, but not listed."
        ],
        "\n"
      )

    front_matter = "---\nmodules:\n  - Demo.Widget\n  - Demo.Dial\n---\n"
    contract = Contract.load!(ContractBuilder.demo_contracts(dir, surface, front_matter))
    component = Contract.component(contract, "demo.widget")

    assert Ownership.listed(component) == ["Demo.Widget", "Demo.Dial"]

    assert Enum.map(Regen.stubs(component), &elem(&1, 0)) == ["Demo.Dial", "Demo.Widget"]

    {_, widget} = List.keyfind(Regen.stubs(component), "Demo.Widget", 0)
    assert widget =~ "def reset(_arg1) do"
    assert widget =~ "def paint(_widget, _color) do"
    {_, dial} = List.keyfind(Regen.stubs(component), "Demo.Dial", 0)
    assert dial =~ "def turn() do"

    %{skipped: skipped, possibly_foreign: []} = Regen.surface(component)

    assert Enum.map(skipped, &{&1.module, &1.function}) ==
             [
               {"Other.Dial", "tick"},
               {"Ecto.UUID", "cast"},
               {"Covenant.Error", "format"},
               {"System", "halt"},
               {"Mix", "raise"},
               {"Ghost", "vanish"}
             ]

    out = Path.join(dir, "pack")

    assert {:ok, %{files: files, skipped: ^skipped, possibly_foreign: []}} =
             Regen.write_pack(contract, "demo.widget", out: out, root: dir, test_paths: [])

    assert for(
             file <- Enum.map(files, &Path.relative_to(&1, out)),
             String.starts_with?(file, "stubs/"),
             do: file
           ) == ["stubs/lib/demo/dial.ex", "stubs/lib/demo/widget.ex"]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I6"
  test "the Modules paragraph lists top-level names only and joins the front matter", %{
    tmp_dir: dir
  } do
    surface = """
    #### Modules

    `Demo.Widget`, `Demo.Gadget` (a behaviour, implemented by `Demo.Gadget.Impl`),
    `Demo.Dial` (called only by `Demo.Widget` through `caps().pool_size`; see `Other.Dial`).

    #### `Demo.Widget`

    - `Demo.Widget.size/1` — its size.
    - `Other.Dial.tick/0` — not listed.
    """

    front_matter = "---\nmodules: [Demo.Extra]\n---\n"
    contract = Contract.load!(ContractBuilder.demo_contracts(dir, surface, front_matter))
    component = Contract.component(contract, "demo.widget")

    assert Ownership.listed(component) ==
             ["Demo.Extra", "Demo.Widget", "Demo.Gadget", "Demo.Dial"]

    assert Enum.map(Regen.stubs(component), &elem(&1, 0)) == ["Demo.Widget"]
    assert [%{module: "Other.Dial"}] = Regen.surface(component).skipped
  end

  # A light component that lists `modules` in its front matter and so owns them.
  defp lister(id, modules) do
    """
    ---
    modules: #{inspect(modules)}
    ---
    # #{id}

    ## Purpose

    Owns modules.

    ## Obligations

    ### #{id}.I1 — Owns them
    - **scope:** `#{hd(modules)}.go/0`
    - **must:** exist
    - **kind:** functional
    - **status:** active
    """
  end

  defp with_listers(dir, surface, front_matter) do
    ContractBuilder.demo_contracts(dir, surface, front_matter)

    ContractBuilder.write(dir, %{
      "demo/gadget.obligations.md" =>
        lister("demo.gadget", [
          "Demo.Gadget",
          "Demo.Shared",
          "Demo.Shared.Deep",
          "Demo.Mine",
          "Covenant.Error"
        ]),
      "demo/aaa.obligations.md" => lister("demo.aaa", ["Demo.Shared"])
    })

    Contract.load!(dir)
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I9"
  test "a module another component lists is skipped and attributed to it, before any other rule",
       %{tmp_dir: dir} do
    surface =
      Enum.join(
        [
          "- `Demo.Widget.size/1` — its size; it reads `Demo.Shared.value/0` and `Covenant.Error.format/1`.",
          "- `Shared.read/0` — a bare alias of a module the others list.",
          "- `Shared.Deep.go/0` — a dotted fragment of a module the gadget lists.",
          "- `Demo.Mine.go/0` — listed by the gadget, not by the widget.",
          "- `Demo.Own.go/0` — listed by nobody, in the widget's namespace."
        ],
        "\n"
      )

    contract = with_listers(dir, surface, "")
    component = Contract.component(contract, "demo.widget")

    assert Ownership.listed(component) == []

    # a module two components list belongs to the first by component id; the component's own
    # listing never counts against it
    elsewhere = Ownership.declared_elsewhere(contract, component)
    assert elsewhere["Demo.Shared"] == "demo.aaa"
    assert elsewhere["Demo.Gadget"] == "demo.gadget"
    refute Map.has_key?(elsewhere, "Demo.Widget")

    pack = Regen.surface(component, declared_elsewhere: elsewhere)
    assert pack.stub |> Enum.map(& &1.module) |> Enum.uniq() == ["Demo.Widget", "Demo.Own"]
    assert pack.possibly_foreign == []

    assert Enum.map(pack.skipped, &{&1.module, &1.function, &1.owner}) == [
             {"Demo.Shared", "value", "demo.aaa"},
             {"Covenant.Error", "format", "demo.gadget"},
             {"Demo.Shared.Deep", "go", "demo.gadget"},
             {"Demo.Mine", "go", "demo.gadget"},
             {"Demo.Shared", "read", "demo.aaa"}
           ]

    # a loadable module of this project another component lists is attributed, not "implemented"
    refute Enum.any?(pack.skipped, &Map.has_key?(&1, :implemented))

    out = Path.join(dir, "pack")

    assert {:ok, %{skipped: skipped, files: files}} =
             Regen.write_pack(contract, "demo.widget", out: out, root: dir, test_paths: [])

    assert skipped == pack.skipped

    assert for(file <- files, String.contains?(file, "/stubs/"), do: Path.relative_to(file, out)) ==
             ["stubs/lib/demo/own.ex", "stubs/lib/demo/widget.ex"]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I9"
  test "a component that lists a module keeps it, and still skips the others' with their owner",
       %{tmp_dir: dir} do
    surface =
      Enum.join(
        [
          "- `Demo.Widget.size/1` — its size; it reads `Demo.Shared.value/0`.",
          "- `Demo.Mine.go/0` — listed by the widget and by the gadget."
        ],
        "\n"
      )

    contract = with_listers(dir, surface, "---\nmodules: [Demo.Widget, Demo.Mine]\n---\n")
    component = Contract.component(contract, "demo.widget")
    elsewhere = Ownership.declared_elsewhere(contract, component)

    pack = Regen.surface(component, declared_elsewhere: elsewhere)
    assert pack.stub |> Enum.map(& &1.module) |> Enum.uniq() == ["Demo.Widget", "Demo.Mine"]
    assert [%{module: "Demo.Shared", owner: "demo.aaa"}] = pack.skipped
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I8"
  test "without a list, ownership follows where a module lives", %{tmp_dir: dir} do
    surface =
      Enum.join(
        [
          "- `Demo.Widget.size/1` — its size.",
          "- `Demo.Widget.paint(widget, color)` — paints; at the end it calls `System.halt(1)`.",
          "- `Mix.raise/1` — Elixir, mentioned in prose only.",
          "- `Mix.Project.config/0` — Elixir, qualified.",
          "- `YamlElixir.Mapper.process/2` — a dependency, loadable.",
          "- `YamlElixir.read_from_string/1` — the dependency's top module, bare to the parser.",
          "- `YamlElixir.NotAModule.go/0` — a dependency's namespace, not loadable.",
          "- `Covenant.Error.format/1` — an app of this project, loadable: already implemented.",
          "- `Elsewhere.Thing.go/0` — a namespace the component does not use, not loadable.",
          "- `Spend.Policy.admit/3` — a dotted fragment of a module that is not in this Contract.",
          "- `Widget.reset/1` — a short alias of `Demo.Widget`.",
          "- `Ghost.vanish/0` — no module ends in `Ghost`."
        ],
        "\n"
      )

    contract = Contract.load!(ContractBuilder.demo_contracts(dir, surface, ""))
    component = Contract.component(contract, "demo.widget")

    assert Ownership.listed(component) == []

    assert Enum.map(Regen.stubs(component), &elem(&1, 0)) == ["Demo.Widget"]

    %{skipped: skipped, possibly_foreign: possibly_foreign} = Regen.surface(component)

    assert Enum.map(skipped, &{&1.module, &1.function}) ==
             [
               {"Mix.Project", "config"},
               {"YamlElixir.Mapper", "process"},
               {"YamlElixir.NotAModule", "go"},
               {"Covenant.Error", "format"},
               {"Elsewhere.Thing", "go"},
               {"Spend.Policy", "admit"},
               {"System", "halt"},
               {"Mix", "raise"},
               {"YamlElixir", "read_from_string"},
               {"Ghost", "vanish"}
             ]

    # only a module of the running project is "already implemented": the reason is on the entry
    assert for(%{implemented: true} = sig <- skipped, do: sig.module) == ["Covenant.Error"]
    assert possibly_foreign == []

    out = Path.join(dir, "pack")

    assert {:ok, %{skipped: ^skipped, possibly_foreign: []}} =
             Regen.write_pack(contract, "demo.widget", out: out, root: dir, test_paths: [])

    assert File.exists?(Path.join(out, "stubs/lib/demo/widget.ex"))
    refute File.exists?(Path.join(out, "stubs/lib/covenant/error.ex"))
    refute File.exists?(Path.join(out, "stubs/lib/elsewhere/thing.ex"))
    refute File.exists?(Path.join(out, "stubs/lib/spend/policy.ex"))
    refute File.exists?(Path.join(out, "stubs/lib/mix/project.ex"))
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I8"
  test "a loadable module whose beam lies anywhere else is stubbed and reported", %{tmp_dir: dir} do
    surface = "- `Demo.Widget.size/1` — its size; it calls `Covenant.Error.format/1`."
    contract = Contract.load!(ContractBuilder.demo_contracts(dir, surface, ""))
    component = Contract.component(contract, "demo.widget")

    # an environment in which no app, dependency or installation holds Covenant's own beams
    nowhere = Ownership.environment(%{app: :nowhere, build_path: Path.join(dir, "_build")})

    assert Ownership.classify_beam(:code.which(Covenant.Error), nowhere) == :unsure

    assert %{possibly_foreign: ["Covenant.Error"], skipped: []} =
             Regen.surface(component, environment: nowhere)

    assert Enum.map(Regen.stubs(component, environment: nowhere), &elem(&1, 0)) ==
             ["Covenant.Error", "Demo.Widget"]
  end

  @tag obligation: "covenant.regen.I8"
  test "a beam is classified by the directory it lies in, umbrella apps included" do
    env =
      Ownership.environment(%{
        app: :shop,
        apps: [:web],
        in_umbrella: [:core],
        deps: [:ecto, :core, :phoenix_pubsub],
        build_path: "/work/_build/dev"
      })

    beam = fn app -> ~c"/work/_build/dev/lib/#{app}/ebin/Elixir.X.beam" end

    assert Ownership.classify_beam(beam.(:shop), env) == :own
    assert Ownership.classify_beam(beam.(:web), env) == :own
    assert Ownership.classify_beam(beam.(:core), env) == :own
    assert Ownership.classify_beam(beam.(:ecto), env) == :foreign
    assert Ownership.classify_beam(beam.(:phoenix_pubsub), env) == :foreign

    otp = Path.join(to_string(:code.root_dir()), "lib/kernel-1.0/ebin/kernel.beam")
    assert Ownership.classify_beam(String.to_charlist(otp), env) == :foreign

    elixir = :elixir |> :code.lib_dir() |> to_string() |> Path.join("ebin/Elixir.Enum.beam")
    assert Ownership.classify_beam(String.to_charlist(elixir), env) == :foreign

    assert Ownership.classify_beam(:preloaded, env) == :foreign
    assert Ownership.classify_beam(~c"/elsewhere/Elixir.X.beam", env) == :unsure
    assert Ownership.classify_beam(~c"/work/_build/dev/lib/shopping/ebin/X.beam", env) == :unsure
    assert Ownership.classify_beam(:cover_compiled, env) == :unsure
    assert Ownership.classify_beam(~c"", env) == :unsure

    assert "Ecto" in env.dep_namespaces
    assert "PhoenixPubsub" in env.dep_namespaces
    refute Enum.any?(env.dep_namespaces, &(&1 in ["Core", "Web", "Shop"]))
  end

  @tag obligation: "covenant.regen.I8"
  test "the in_umbrella dependencies are read from a deps list" do
    deps = [
      {:ecto, "~> 3.0"},
      {:core, in_umbrella: true},
      {:web, "~> 1.0", [in_umbrella: true, only: :test]},
      {:oban, "~> 2.0", only: :prod},
      {:plain, git: "https://example.test/plain.git"},
      :not_a_tuple
    ]

    assert Ownership.in_umbrella(deps) == [:core, :web]
    assert Ownership.in_umbrella(nil) == []
  end

  @tag obligation: "covenant.regen.I8"
  test "a module that is not loadable is foreign in a dependency's namespace, else stubbed or unplaced" do
    env = Ownership.environment(%{app: :shop, deps: [:ecto], build_path: "/work/_build/dev"})

    assert Ownership.classify("Ecto.NotAModule", env) == :foreign
    assert Ownership.classify("Shop.NotAModule", env) == :own
    assert Ownership.classify("Shop.NotAModule", env, ["Shop"]) == :own
    assert Ownership.classify("Other.NotAModule", env) == :own
    assert Ownership.classify("Other.NotAModule", env, ["Shop"]) == :unplaced
    assert Ownership.classify("System", env) == :foreign

    # a loadable module is judged by its beam: Covenant's own is in an app of this project
    project = Ownership.environment(%{app: :covenant, build_path: Mix.Project.build_path()})
    assert Ownership.classify("Covenant.Error", project) == :implemented
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I7"
  test "stub docs keep inline code verbatim and compile whatever the line holds", %{tmp_dir: dir} do
    long = String.duplicate("word ", 1_000)

    surface =
      Enum.join(
        [
          "- `Demo.Widget.size/1` — its size.",
          "- `Demo.Widget.paint(widget, color)` — paints with `color`, then calls `System.halt(1)` when `\#{boom}` or \"\"\" shows.",
          "- `Demo.Widget.width/1`, `Demo.Widget.height/1` — the dimensions, also see `Demo.Widget.size/1`.",
          "- `Demo.Widget.note/0` — #{long}end."
        ],
        "\n"
      )

    contract = Contract.load!(ContractBuilder.demo_contracts(dir, surface, ""))
    component = Contract.component(contract, "demo.widget")

    sigs = Map.new(Regen.signatures(component), &{&1.function, &1.doc})

    assert sigs["paint"] ==
             "paints with `color`, then calls `System.halt(1)` when `\#{boom}` or \"\"\" shows."

    assert sigs["width"] == "the dimensions, also see `Demo.Widget.size/1`."
    assert sigs["height"] == sigs["width"]

    {"Demo.Widget", source} = List.keyfind(Regen.stubs(component), "Demo.Widget", 0)

    doc = fn function ->
      [_, literal] = Regex.run(~r/@doc (".*")\n  def #{function}\(/, source)
      {doc, _} = Code.eval_string(literal)
      doc
    end

    assert doc.("paint") ==
             "paint(widget, color) — " <> sigs["paint"]

    assert doc.("note") == "note() — " <> sigs["note"]
    assert String.ends_with?(doc.("note"), "end.")

    renamed =
      String.replace(
        source,
        "defmodule Demo.Widget do",
        "defmodule Covenant.RegenDocTest.Stub do"
      )

    assert [{module, _}] = Code.compile_string(renamed)
    assert_raise RuntimeError, ~r/not implemented yet/, fn -> module.paint(1, 2) end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.regen.I4"
  test "rewrites an existing pack directory, refusing files the marker does not list", %{
    contract: contract,
    tmp_dir: dir
  } do
    out = Path.join(dir, "pack")
    File.mkdir_p!(out)
    File.write!(Path.join(out, ".covenant-pack"), "example.greeter\nPROMPT.md\n")
    File.write!(Path.join(out, "PROMPT.md"), "old")
    {:ok, _} = Regen.write_pack(contract, "example.greeter", out: out, root: dir, test_paths: [])
    assert File.read!(Path.join(out, "PROMPT.md")) =~ "# Regenerate"

    File.write!(Path.join(out, "stale.txt"), "old")

    assert {:error, message} =
             Regen.write_pack(contract, "example.greeter", out: out, root: dir, test_paths: [])

    assert message =~ "stale.txt"
    assert File.read!(Path.join(out, "stale.txt")) == "old"
  end
end
