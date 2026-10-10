# Changelog

## Unreleased (2026-10-10)

- `mix covenant.check --static` checks a Contract without compiling or
  running its tests (`Covenant.Static`); static coverage goes to
  `contracts/coverage.static.json`.
- `Covenant.root/0`: the directory holding the contracts directory,
  independent of the working directory.
- `Covenant.Check.run/3` takes `mode: :static`; `Covenant.Coverage.compute/3`
  takes `covered: :tagged`.
- `mix covenant.regen`: `--test-path` globs and absolute paths now find the
  component's contract tests (`Covenant.Regen.find_tests/3` expands paths with
  `Covenant.Static.expand/1`, like static mode; an absolute path used to be
  joined onto the root). A test is laid out in the pack at its path relative
  to the root, which defaults to the directory holding the contracts
  directory (so `apps/<app>/test/contract/...` in an umbrella).
- `mix covenant.regen` no longer stubs modules the component does not own
  (`Covenant.Regen.Ownership`). A `#### Modules` paragraph in the Public
  surface (or the front matter's `modules:`) is authoritative: exactly those
  modules are stubbed. Without one, a loadable module is foreign when its beam
  lies under OTP, Elixir or a dependency's build path and owned when it lies
  in the running project's apps (umbrella children included), and a module
  that is not loadable is foreign when its first segment is a dependency's
  namespace. A module it cannot place is stubbed and returned as
  `:possibly_foreign`. A bare alias (`Scope`) is merged into the owned module
  whose last segment matches, or dropped. The pack map has `:skipped` and
  `:possibly_foreign` (`Covenant.Regen.surface/2`) and the task prints a
  count line and a `possibly_foreign:` line.
- `Covenant.Mutate.Modules.references/1` reads module names out of the code
  spans of any text.
- `mix covenant.regen` keeps inline code in stub `@doc` strings: only the
  signature spans that open the line are removed, where every signature span
  on the line used to be (`calls  when ...`). Docs longer than 4096 bytes are
  no longer truncated.
- Obligations `covenant.regen.I5`–`I8` pin these fixes.

## 0.1.0 (2026-10-09)

Initial release: the IMP Contract layer for Elixir.

- `Covenant.Contract` parses a contracts directory (heavy-form intents,
  light-form obligations files, decision records, system intent and scope
  ceilings) into structs with file and line provenance.
- `Covenant.Case` binds contract tests to obligations at compile time.
- `Covenant.Formatter` records obligation-tagged tests per app.
- `mix covenant.check` enforces the Contract and publishes contract coverage.
- `mix covenant.conditions` re-checks machine-checkable record premises.
- `mix covenant.regen` writes regeneration packs.
