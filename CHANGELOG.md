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
- `mix covenant.mutate --jobs N` no longer corrupts the kill credit. ExUnit
  creates a test's `:tmp_dir` at `tmp/<module>/<test>` under the OS process's
  working directory, so N workers shared it, cleared and rewrote each other's
  files, and the spurious failures were credited as kills (up to a dozen
  mutants credited differently from the serial run, and a red baseline in a
  worker). With N > 1 each worker now runs its tests from a private directory
  (`Covenant.Mutate.Workdir`: symlinks to every entry of the project root and a
  `tmp/` of its own, removed at the end); the credit equals `--jobs 1`.
  `Covenant.Mutate.Runner.run/1` takes `isolate: true` for it and
  `Runner.entry/2` takes the root files are reported relative to.
- `mix help covenant.mutate` documents the survivors file (location, entry keys,
  every sort and its meaning), the exit status and what `--jobs` isolates.
- README: a "Mutation testing" section (operators, verdicts, credit, unique and
  mutation-blind, the survivors file, exit status, `--jobs`).
- Obligations `covenant.tasks.I7` (credit independent of `--jobs`) and `I8`
  (the help documents the survivors file); the fixture counter's persisted-form
  test goes through a `:tmp_dir` so the contract test of I7 can observe workers.
- `covenant.mutate` has a Contract of its own (`contracts/covenant/mutate.obligations.md`,
  obligations `I1`–`I15`: the operators, deterministic enumeration at reported
  locations, mutants compiled in memory, invalid mutants, verdicts, the green
  baseline, credit and unique kills, the survivors file, module resolution, the
  plan and worker results, the JSON matrix, the exit status, determinism and
  the worker directory) and tests in `test/contract/covenant/mutate/`: unit
  tests that call the mutate modules directly, a golden corpus
  (`test/fixtures/mutate/`, re-recorded with `COVENANT_UPDATE_GOLDEN=1`) and
  end-to-end tests that run the task in the fixture project.
- `mix covenant.mutate covenant.mutate --test-path test/contract/covenant/mutate/mutate_contract_test.exs`
  mutates the module list declared in the obligations' front matter (the
  Runner, Workdir and Mix task are left out: the worker executes them while it
  swaps mutants). 1286 mutants, 1090 killed, 60 survivors sorted in
  `mutate.survivors.yml` (equivalent, dead-code, log-only, timeout,
  evaluation-gap), score 94.8% over the 1150 compiled mutants.
- `Covenant.Mutate.Workdir.build/2` takes the directory the worker directory
  is made under (the system temp directory by default).

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
