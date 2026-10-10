# Changelog

## Unreleased (2026-10-10)

- `mix covenant.mutate --fail-fast` stops a mutant's run at its first failing test
  (ExUnit `max_failures: 1`). Killed/survived verdicts are exact, so the survivors, their
  sort and the exit status are those of a full run; the credit is partial: a killed mutant is
  marked `credit: partial` (`Covenant.Mutate.Mutant` has a `credit` field, in the JSON and
  the raw worker results), the obligation and test totals (`killed`, `unique`, `kills`,
  `unique_kills`) count only exact-credit mutants, no test is judged mutation-blind
  (`mutation_blind` is `null`), and the JSON has `fail_fast` and `summary.partial`. A mutant
  whose fail-fast run failed on timeouts alone is run again in full, since a timeout counts
  as a failure and can end the run before the test that kills. A fail-fast matrix proves
  kills, not obligation credit. Obligation `covenant.mutate.I17`.
- The default per-test timeout of a mutant run is measured from the baseline: five times
  the slowest baseline test, never under 1000 ms (`Covenant.Mutate.default_timeout/1`),
  where it was a flat 10 s, so a mutant that loops forever dies quickly. `--timeout MS` still overrides it; `timeout_ms` in the matrix is the
  timeout used (the largest of the workers'). `Covenant.Mutate.default_timeout/0` is gone.
  Obligation `covenant.mutate.I16`.
- `mix covenant.mutate` prints a progress line with the mutants done, the rate and an ETA after
  every 25th mutant (per worker with `--jobs`). Obligation `covenant.mutate.I18`.
- `Covenant.Mutate.Runner.entry/2` reports the test's duration as `ms`.

- `mix covenant.conditions` resolves `file` conditions and `mix.lock` against
  `Covenant.root/0` instead of the working directory (as the other tasks resolve
  their paths, covenant.tasks.I9). Run from `apps/<app>` of an umbrella it used to
  report every root-relative file and the umbrella lock as missing. The library
  default of `Conditions.context/1` stays the working directory.
- Condition kind `value`: `check: {kind: value, call: "Module.fun/0", path: [key], equals: v}`
  calls a function of the running project and compares what it returns (at `path`) with the
  record, so the record that decides a value verifies it. Atoms compare as strings, lists
  element by element, numbers by value. A different value, a missing key or a raising call
  is suspect; a module that is not compiled in the VM is `{:unchecked, reason}`, counted by
  `mix covenant.conditions` (`--verbose` says why), never a failure. Any `call` that is not
  `Module.fun/0` is an incomplete check. Obligation `covenant.conditions.I6`.
- `Covenant.Conditions.outcome` has a fourth shape, `{:unchecked, reason}`; the bare
  `:unchecked` stays for a condition without a `check`.
- `otp`, `elixir` and `dep` requirements: a comparison may leave out the minor and patch
  numbers (`>= 28.0` is `>= 28.0.0`; `~>` is left as written), a four-number OTP version
  (`27.3.4.1`) is compared as `27.3.4`, and a version that is not numeric is a suspect
  "cannot be compared" instead of an exception. Records that wrote `>= 28.0` were reported
  suspect without the premise ever being evaluated.
- A `kind: module` scope ceiling whose counter raises, throws or exits is unchecked:
  `Covenant.Contract.Ceiling.count/2` returns `{:unchecked, reason}` and `Check.run/3`
  adds a `scope ceiling ... unchecked` entry to `Report.warnings` instead of crashing
  before `coverage.json` is written.
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
  lies under OTP, Elixir or a dependency's build path and already implemented
  when it lies in the running project's apps (umbrella children included), and
  a module that is not loadable is foreign when its first segment is a
  dependency's namespace (see the entries below for what a pack skips and
  why). A loadable module whose beam lies anywhere else is stubbed and
  returned as `:possibly_foreign`. A bare alias (`Scope`) is merged into the
  one known module whose name ends in it, or dropped. The pack map has
  `:skipped` and `:possibly_foreign` (`Covenant.Regen.surface/2`) and the task
  prints a count line and a `possibly_foreign:` line.
- `Covenant.Mutate.Modules.references/1` reads module names out of the code
  spans of any text.
- `mix covenant.regen` keeps inline code in stub `@doc` strings: only the
  signature spans that open the line are removed, where every signature span
  on the line used to be (`calls  when ...`). Docs longer than 4096 bytes are
  no longer truncated.
- Obligations `covenant.regen.I5`–`I8` pin these fixes.
- Configured test paths resolve against `Covenant.root/0`, for every task. In an
  umbrella `config :covenant, test_paths: ["apps/*/test/contract"]` used to be
  expanded relative to the directory `mix` ran in, so `mix covenant.regen
  agora.wake_ingest` run from `apps/agora` and `mix covenant.mutate core.tenancy`
  run from `apps/machina_core` found no contract test. `Covenant.test_paths/0`
  now returns absolute paths (a relative entry resolved against the root, a glob
  kept) and `Covenant.test_paths/1` takes the task's `--test-path` values, which
  stay relative to the working directory where they were typed. `--contracts`
  redirects the Contract without moving the root. `mix covenant.check` hands
  `mix test` the paths relative to the working directory, as before; the static
  summary prints them relative to the root. Obligations `covenant.static.I6` and
  `covenant.tasks.I9`, with an umbrella-shaped fixture
  (`test/fixtures/umbrella_project`, tasks run from `apps/shop`).
- `mix covenant.regen` no longer stubs another component's modules. A module
  that the `#### Modules` paragraph or `modules:` of another component lists is
  foreign, ahead of every other rule: skipped, attributed in the pack's
  `:skipped` entries (`owner: "<component id>"`) and printed on a `skipped (owned
  by <component>)` line (`Covenant.Regen.Ownership.declared_elsewhere/2`; a
  module two components list belongs to the first by id). Without a list, a
  loadable module of the running project is now *already implemented* and
  skipped (`implemented: true`, a `skipped (already implemented in this
  project)` line) instead of being stubbed as the component's own: a component
  that wants its own implemented modules stubbed lists them. A module that is
  not loadable and whose namespace the component's obligation scopes do not use
  is no longer stubbed and reported as `possibly_foreign`; it is resolved as an
  alias or dropped. An alias resolves to the one known module whose name ends in
  it (the listed modules, the other components' modules and the modules the
  surface stubs), so a dotted fragment such as `Repo.Scoped` or `Spend.Policy`
  never becomes a stub. `possibly_foreign` now means a loadable module whose beam
  lies nowhere known. `Ownership.partition/3` gained a fourth argument (the
  other components' modules; default none) and `Ownership.classify/3` the
  verdicts `:implemented` and `:unplaced`. Obligation `covenant.regen.I9`;
  `covenant.regen.I8` rewritten. In the fixture the counter's intent now has a
  `#### Modules` paragraph, which moved its obligations four lines down.
- `mix covenant.check` and `mix covenant.check --static` warn, without failing,
  about the components that declare no modules (no `#### Modules` paragraph, no
  `modules:` front matter; the `system` intent is exempt): `covenant.check:
  warning: N component(s) declare no modules: ...`. `Covenant.Check.Report` has a
  `:warnings` field. Obligation `covenant.check.I11`.
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
