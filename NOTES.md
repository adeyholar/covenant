# Covenant build notes

Progress log for the initial build of Covenant (IMP Contract layer for Elixir).
Convention implemented: `/Users/obie/projects/machina-ex/contracts/README.md`.

## What was built

- `Covenant.Contract` (+ `Component`, `Obligation`, `Record`, `Condition`,
  `Ceiling`, `Section`, `Error`, `ContractError`) — loads a contracts dir;
  every problem is a `%Covenant.Error{file, line, message}`.
- Parsers: `Covenant.Parser.Markdown` (heavy/light/system forms, obligation
  blocks, fence-aware, continuation lines, required-heading order),
  `Covenant.Parser.Records` (decisions.yml, item-line provenance),
  `Covenant.Parser.Scope` (scope.yml ceilings: glob / module counters).
- `Covenant.Contract.Validate` — dangling record / invariant / superseded_by /
  depends_on / ceiling-record references (checked at check time, not compile time).
- `Covenant.Case` — wraps ExUnit.Case; own `@before_compile` reads
  `@ex_unit_tests` and raises `CompileError` at the test's file:line for an
  unknown id, retired id, other component's id, invalid tag, untagged test;
  module-level errors for unknown component / unparsable Contract. Adds
  `@moduletag :contract` and `covenant_component:`.
- `Covenant.Formatter` + `Covenant.Results` — per-app results JSON under
  `_build/covenant/results` (env `COVENANT_RESULTS_DIR` > config > default).
- `Covenant.Check` (pure) + `Covenant.Coverage` + `Covenant.JSON`
  (deterministic, sorted-key pretty printer; no timestamp in coverage.json).
- `Covenant.Conditions` — dep / env / file / otp / elixir checks; suspects.
- `Covenant.Regen` — pack with PROMPT.md, brief, convention copy, contract
  files, component tests (found by `use Covenant.Case, component:` declaration),
  public-surface stubs parsed from `## Public surface` code spans.
- `Covenant.Target` — exception targets `Module.fun/arity` | `Module` | path.
- Mix tasks: `covenant.check` (runs `mix test <paths>` as a MIX_ENV=test
  subprocess with the formatter; `--no-run`, `--contracts`, `--test-path`,
  `--results-dir`; exit 1 on problems), `covenant.conditions` (`--verbose`;
  exit 1 on suspects), `covenant.regen <component>` (`--out`).
- Fixture project `test/fixtures/example_project` (own mix.exs, shared
  `deps_path`, own mix.lock): `example.counter` heavy (I1–I4 active, I5
  retired, 4 records incl. superseded_by/depends_on/conditions),
  `example.greeter` light with a `kind: exception`, `system/` intent +
  records + scope.yml, implementation and contract tests.
- Covenant governs itself: `contracts/` (7 light components, 41 obligations,
  9 system records holding the policy decisions, 1 scope ceiling); the whole
  suite lives in `test/contract/covenant/**` as Covenant.Case modules.
  `mix covenant.check` on Covenant: 41/41, 100%. `mix covenant.conditions`:
  0 suspect. 120 tests, 0 failures. `mix format --check-formatted` clean,
  `--warnings-as-errors` clean, `mix docs` builds.

## Policy decisions (also recorded in contracts/system/decisions.yml)

- `kind: exception` blocks and `status: retired` obligations are excluded from
  the "needs a tagged test" rule and from coverage denominators.
- A test inside a `Covenant.Case` module without an `obligation` tag is a
  compile error; so is tagging an obligation of another component.
- Results are written per app so umbrella apps do not overwrite each other;
  the results dir is `_build/covenant/results`, independent of MIX_ENV.
- Exception targets must be public functions, modules or files
  (`function_exported?/3` cannot see private functions) — recorded as a known gap.
- `mix covenant.check` runs the suite as a subprocess, never in-process.
- Required record keys: id, date, decision, driver, approved_by (the rest
  optional but type-checked). Heavy intents must carry the `| Rev | Date |
  Change | Driver |` revision log in Purpose.

## Things the next person should know

- `test_load_filters` / `test_ignore_filters` in mix.exs (Elixir 1.19 options)
  keep the fixture project's tests out of Covenant's own `mix test`.
- The fixture shares `deps_path` with the parent; it has its own lockfile, so
  nothing run inside it touches the parent's mix.lock.
- The e2e contract tests (`test/contract/covenant/tasks`) spawn `mix` in the
  fixture; the first run compiles the fixture's `_build` (~10 s), cached after.
- `contracts/coverage.json` is a committed artefact of `mix covenant.check`;
  the fixture's copy is gitignored because the suite regenerates it.
- No URLs were invented: mix.exs has no `source_url`/links until the repo's
  public home is known. `mix covenant.mutate` (kill matrix) is not built yet.

## Log

- 22:31 scaffolded `mix new covenant`; NOTES.md written.
- 22:50 lib compiles: Contract/parsers/Case/Formatter/Results/Check/Coverage/Conditions/Regen + 3 mix tasks.
- 22:55 fixture project green end to end; compile-time tag errors verified with file:line.
- 23:20 own suite green (120 tests, unit + e2e subprocess runs in the fixture).
- 23:45 dogfood: Covenant's own contracts/ + tests moved to test/contract as Covenant.Case modules;
  the tool caught two real YAML defects in my own records file (unquoted `kind: exception`).
- 23:55 README, CHANGELOG, LICENSE; coverage.json made timestamp-free; final runs all green.
- 00:10 advisor review: results-dir tests now save/restore COVENANT_RESULTS_DIR (they passed by
  coincidence under the default dir); verified `mix covenant.check --results-dir tmp/x` and an
  empty Contract (`--contracts <empty dir>` + empty results dir) both exit 0. Stray /tmp probe removed.


# Phase 2 — `mix covenant.mutate` (kill matrix)

Started 2026-10-09. Baseline before any change: 120 tests, 0 failures.

## Design (decided before coding; probes in scratchpad confirmed the mechanics)

- **Module mapping (Contract terms).** The implementation of a component is the
  set of modules named in its `## Public surface` code spans (heavy form) and in
  the `scope` of its testable obligations (both forms). When that is not the
  whole implementation (private helper modules), the file declares it in YAML
  front matter: `---\nmodules: [Example.Counter, Example.Counter.Log]\n---`.
  `--module` flags override both. Precedence: flags > front matter > derived.
  A derived module that is not loadable is an error (a stale `scope` is caught).
- **Execution.** Parent task (any MIX_ENV) resolves the component, modules and
  contract test files, then spawns `MIX_ENV=test mix covenant.mutate.worker`
  (same subprocess policy as `covenant.check`). The worker boots the test env
  once, requires test_helper + the component's contract test files, recompiles
  the original AST (`Code.compile_quoted`) as the restore binary, runs the
  baseline (must be green), then per mutant: purge -> compile mutant in memory
  -> `ExUnit.run(modules)` with a collecting formatter -> purge -> reload
  original. No files are written by mutation. Jobs > 1 = N workers over
  index slices (default 1). Workers share the project, and ExUnit's `:tmp_dir` is
  `tmp/<module>/<test>` under the OS process's cwd with no setting to move it, so
  with N > 1 each worker runs the suite from a private cwd (`Mutate.Workdir`:
  symlinks to the root's entries + its own `tmp/`), entered after the suite is
  compiled (the collector reports files relative to the root, not the cwd). Other
  shared resources still make parallel runs lie — IMP E2.
- **AST level.** `Code.string_to_quoted(columns: true, token_metadata: true,
  literal_encoder: &{:ok, {:__block__, &2, [&1]}})` gives every literal a
  position; before compiling, every single-element `__block__` is unwrapped
  (the encoder also wraps `do:` keys, which would break `def`). Sites are
  enumerated with `Macro.traverse` and a node counter; applying mutant k
  re-walks and replaces the k-th node, so the set and order are a pure
  function of the source (deterministic). Skipped: docs/specs/types/compiler
  attributes, defmacro/defguard, use/import/alias/require, sigils, quote.
- **Verdicts.** killed = at least one test failed with a non-timeout failure;
  timeout = every failure is `ExUnit.TimeoutError` (a survivor, per IMP E2);
  survived = all green; invalid = the mutant does not compile (excluded from
  the denominator). Tests run with a fixed seed (default 0) and per-test
  timeout `--timeout` (default 10 s).
- **Credit.** A kill is credited to the obligations tagged on every failing
  test. Per obligation: total kills and unique kills (mutants only its tests
  caught). Per test: kills and unique kills; a test with no unique kill is
  `mutation_blind` (warn only; `@tag mutation_blind: "reason"` is printed with the warning, which stays).
- **Survivor sort.** `contracts/<app>/<component>.survivors.yml` annotates
  survivors by `at` (file:line:column) + `operator` (+ `mutation` when two
  mutants share a site) with `sort` in equivalent | log-only | dead-code |
  timeout | evaluation-gap | decision-hole and a `reason`. Unannotated
  survivors and stale annotations fail the task (exit 1), like stale exceptions.
- **Output.** Progress line per mutant, kill matrix table, survivors list,
  mutation-blind list; JSON at `--out` (default `tmp/covenant/mutate/<component>.json`).

## Log
