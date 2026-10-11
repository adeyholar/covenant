# covenant.regen

## Purpose

Writes a regeneration pack: everything a fresh agent needs to rebuild a
component from its Contract, with the implementation excluded.

## Obligations

### covenant.regen.I1 — The pack is the Contract without the implementation
- **scope:** `Covenant.Regen.write_pack/3`
- **must:** write `PROMPT.md`, `REGENERATION_BRIEF.md`, the contracts README as `CONTRACT_CONVENTION.md`, the component's intent or obligations file and records, the system intent and records, the component's contract tests and public-surface stubs, verbatim where copied, and never the implementation; the prompt names the component, forbids looking for the old implementation, lists the active obligations and the files in the pack
- **kind:** functional
- **status:** active

### covenant.regen.I2 — Stubs come from the Public surface
- **scope:** `Covenant.Regen.signatures/1`, `Covenant.Regen.stubs/1`
- **must:** read `Module.function(args) :: type` and `Module.function/arity` code spans from the `## Public surface` section, keep the line's prose as the doc, and render one compilable module per public module whose functions raise until implemented
- **kind:** functional
- **status:** active

### covenant.regen.I3 — A thin component still gets a complete pack
- **scope:** `Covenant.Regen.write_pack/3`
- **must:** for a component without a Public surface, a Regeneration brief, records or contract tests, write the pack anyway and say in the brief and prompt what is absent
- **kind:** functional
- **status:** active

### covenant.regen.I4 — Packs are found by declaration and rebuilt from scratch
- **scope:** `Covenant.Regen.write_pack/3`, `Covenant.Regen.find_tests/3`
- **must:** find contract tests by their `use Covenant.Case, component: "<id>"` declaration through the configured paths or globs, refuse an unknown component naming the known ones, and replace any existing pack directory entirely
- **kind:** functional
- **status:** active

### covenant.regen.I5 — Test paths are expanded as static mode expands them
- **scope:** `Covenant.Regen.find_tests/3`, `Covenant.Regen.write_pack/3`
- **must:** expand every test path, absolute or relative to the root, as `Covenant.Static.expand/1` does (files, directories and globs, never an absolute path joined onto the root), and lay each found test out in the pack at its path relative to the root, which defaults to the directory holding the contracts directory
- **kind:** functional
- **status:** active

### covenant.regen.I6 — A listed set of modules is authoritative
- **scope:** `Covenant.Regen.surface/2`, `Covenant.Regen.stubs/2`, `Covenant.Regen.Ownership.listed/1`, `Covenant.Regen.Ownership.partition/3`
- **must:** when the Public surface has a `#### Modules` paragraph, or the front matter has `modules:`, stub exactly those modules and skip every other reference, loadable or not; read from the paragraph only the backticked names outside parentheses; merge a bare alias (no dot) into the one listed module whose last segment matches and drop it when none or several match; return every dropped reference in the pack's `skipped` list; `mix covenant.regen` prints one line with the count and modules of those that I8 and I9 do not attribute
- **kind:** functional
- **status:** active

### covenant.regen.I7 — Stub docs keep the line's inline code
- **scope:** `Covenant.Regen.signatures/1`, `Covenant.Regen.stubs/1`
- **must:** keep every inline code span of the Public surface line verbatim, backticks included, in the stub's `@doc`, removing only the signature spans that open the line; write the doc as a string literal that compiles whatever it holds (quotes, `"""`, interpolation, lines of any length)
- **kind:** functional
- **status:** active

### covenant.regen.I8 — Without a list, ownership follows where a module lives
- **scope:** `Covenant.Regen.Ownership.classify/3`, `Covenant.Regen.Ownership.classify_beam/2`, `Covenant.Regen.Ownership.environment/1`, `Covenant.Regen.surface/2`, `Covenant.Regen.write_pack/3`
- **must:** treat a loadable module as foreign when its beam lies under the OTP or Elixir installation or a dependency's build path, and as already implemented when it lies in an app of the running Mix project (umbrella children and `in_umbrella` dependencies included): skip it, marking the skipped signature `implemented: true`, and have `mix covenant.regen` print a `skipped (already implemented in this project)` line with their modules; treat a module that is not loadable as foreign when its first segment is a dependency's namespace, as owned (stub it) when its first segment is a namespace the component's obligation scopes use or when those scopes name no module, and as unplaced otherwise; stub a loadable module whose beam lies anywhere else and return it in the pack's `possibly_foreign` list, which `mix covenant.regen` prints on a `possibly_foreign:` line; resolve an alias (a bare name, a dotted fragment such as `Repo.Scoped` or an unplaced name such as `Spend.Policy`) to the one known module whose name ends in it, the known modules being the listed ones, the ones other components list and the ones the surface stubs, and drop it into `skipped` when none or several match; never treat a bare name that is a loadable module (`System`) as an alias
- **why:** a component that lists no modules has claimed none, so a module of the running project is somebody's finished work and a stub of it would shadow it; an unplaced name is far likelier a collaborator's module or a fragment of one than the component's own
- **kind:** functional
- **record:** declared-elsewhere-is-foreign
- **status:** active

### covenant.regen.I9 — A module another component lists is foreign
- **scope:** `Covenant.Regen.Ownership.declared_elsewhere/2`, `Covenant.Regen.Ownership.partition/4`, `Covenant.Regen.surface/2`, `Covenant.Regen.write_pack/3`
- **must:** ahead of every other ownership rule, skip a reference to a module that the `#### Modules` paragraph or the `modules:` front matter of another component of the Contract lists, unless this component lists it too, and attribute it to that component (the skipped signature carries `owner: "<component id>"`; a module two components list belongs to the first by component id), whether or not the module is loadable or implemented, with or without a list of its own; resolve aliases against those modules too; `mix covenant.regen` prints one `skipped (owned by <component id>): <modules>` line per owner
- **why:** a pack for `billing.invoices` stubbed the `core.tenancy` modules it only calls
- **kind:** functional
- **record:** declared-elsewhere-is-foreign
- **status:** active
