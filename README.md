# Covenant

The Contract layer of IMP (Impatient Programming) for
Elixir. A Contract is the team's versioned description of what a component
must do: an **intent** document, **decision records** with the reasons
behind every value that looks arbitrary, and **obligations** made executable
as tagged contract tests. Covenant parses the Contract, binds tests to
obligations at compile time, publishes contract coverage, re-checks the
premises of decisions and writes regeneration packs — so a component can be
deleted and rebuilt from its Contract alone.

Covenant implements the Machina contract convention (`contracts/README.md`
in machina-ex) and governs itself with it: see this project's own
[`contracts/`](contracts/) and `test/contract/`.

## Installation

```elixir
def deps do
  [{:covenant, "~> 0.1", only: [:dev, :test]}]
end
```

Elixir 1.18 or later. The only runtime dependency is `yaml_elixir`.

## Layout

```
contracts/
  README.md                      # your convention
  system/
    intent.md                    # whole-product intent (component "system")
    decisions.yml                # architecture decision records
    scope.yml                    # scope-budget ceilings
  <app>/
    <component>.intent.md        # heavy form: nine required sections
    <component>.obligations.md   # light form: Purpose + obligation blocks
    <component>.decisions.yml    # that component's records
test/contract/<app>/<component>_contract_test.exs
```

Component ids are `<app>.<component>`; obligation ids are `<component id>.I<n>`.

### Obligation blocks

```markdown
### example.counter.I1 — A counter never goes below zero
- **scope:** `Example.Counter.decrement/2`, every starting value
- **must:** stop at zero when `by` exceeds the value, instead of going negative
- **why:** v1 raised on underflow and every caller rescued it (incident #1)
- **kind:** functional
- **record:** clamp-at-zero
- **status:** active
```

`kind` is one of `functional`, `non-functional`, `persisted-format`,
`ordering`, `security` or `exception`; `status` is `active` or `retired`.
Heavy form requires `scope`, `must`, `why`, `kind`, `status`; light form
makes `why` optional. A `kind: exception` block declares intentional
duplication or a known gap and names the code with `target:`
(`Module.function/arity`, `Module` or a file path); it needs no test, and
the build fails when its target no longer exists.

### Decision records

```yaml
- id: clamp-at-zero
  date: "2026-10-09"
  decision: A decrement that would go below zero stops at zero instead of raising.
  driver: v1 raised on underflow and every caller rescued it (incident #1).
  alternatives:
    - option: Raise ArgumentError on underflow
      rejected: Every caller wrapped the call in rescue.
  evidence: Incident log #1.
  invariant: example.counter.I1
  approved_by: lead (2026-10-09)
  conditions:
    - text: Elixir is at least 1.18
      check: { kind: elixir, version: ">= 1.18.0" }
    - text: Callers treat the counter as a value
  expires: When callers need signed counters
  source: ["docs/incidents.md#1"]
  # optional: kind (fact | cross-system | known-gap), superseded_by, depends_on, notes
```

`id`, `date`, `decision`, `driver` and `approved_by` are required. Condition
`check`s are what `mix covenant.conditions` evaluates:

| kind     | fields                     | holds when                                   |
|----------|----------------------------|----------------------------------------------|
| `dep`    | `name`, optional `version` | the dependency is in `mix.lock` (and matches)|
| `env`    | `name`                     | the environment variable is set              |
| `file`   | `path`                     | the path exists                              |
| `otp`    | `version`                  | the running OTP release matches              |
| `elixir` | `version`                  | the running Elixir version matches           |
| `value`  | `call`, `equals`, optional `path` | the function returns the value the record says (below) |

A version requirement may leave out the minor or patch number after a comparison
operator: `>= 28.0` reads as `>= 28.0.0`. `~>` keeps the parts it was written with, so
`~> 28.0` still means below 29. The running version is compared as three numbers
(`28` and `28.5` are padded with zeros, the fourth number of `27.3.4.1` is dropped). A
requirement that does not parse is suspect, never skipped.

### `value` checks

The record that decides a value can verify it:

```yaml
conditions:
  - text: The claim batch is 20
    check: { kind: value, call: "Agora.Wake.limits/0", path: [claim_batch], equals: 20 }
  - text: A failed turn is retried after 60 s, then 300 s
    check: { kind: value, call: "Agora.Wake.limits/0", path: [backoff_s], equals: [60, 300] }
```

`call` is `Module.fun/0` (arity 0 only; any other shape is an incomplete check). It is
called in the running project's VM, so `mix covenant.conditions` compiles the project first.
`path` is an optional list of keys walked through maps; for each key the atom form is tried,
then the string form. `equals` is a YAML scalar or list, compared after normalising: atoms
compare as their string (`mode: fast` matches `:fast`), lists element by element, numbers by
value (`20` equals `20.0`); a boolean and `null` only equal themselves.

| Outcome | When |
|---|---|
| holds | the value equals `equals` |
| suspect | the value differs (`Agora.Wake.limits/0 [claim_batch] is 21, the record says 20`), a key is missing, or the call raises, throws or exits |
| unchecked | the module is not compiled in this VM (`module not compiled in this VM: Agora.Wake`); counted and listed by `--verbose`, never a failure |

### Scope ceilings (`system/scope.yml`)

```yaml
- name: core-modules
  ceiling: 60
  counter: { kind: glob, pattern: "apps/core/lib/**/*.ex" }
  why: The core stays small enough to regenerate in a day.
  record: six-tools                       # optional
- name: runtime-deps
  ceiling: 25
  counter: { kind: module, module: Machina.Scope, function: runtime_deps }
```

A `glob` counter counts matching files; a `module` counter calls
`module.function/0`. A count above the ceiling fails `mix covenant.check`. A module
counter that raises (a stub not implemented yet) leaves its ceiling unchecked: the check
warns (`scope ceiling `name` unchecked: Mod.fun/0 raised Mod.NotImplemented`), still
completes and writes `contracts/coverage.json`.

## Contract tests

```elixir
defmodule Example.CounterContractTest do
  use Covenant.Case, component: "example.counter", async: true

  @tag obligation: "example.counter.I1"
  test "decrementing past zero stops at zero" do
    ...
  end

  @tag obligation: ["example.counter.I1", "example.counter.I4"]
  test "the worked example: clamps record a clamped event in call order" do
    ...
  end
end
```

`Covenant.Case` wraps `ExUnit.Case`. At compile time every test must carry
an `obligation` tag naming an active obligation of the module's component; an
unknown or retired id, an id of another component, or an untagged test is a
compile error at the test's line:

```
** (CompileError) test/contract/example/counter_contract_test.exs:12: test x is
tagged with unknown obligation `example.counter.I99`; `example.counter` declares:
example.counter.I1, example.counter.I2, ...
```

Add the formatter to `test/test_helper.exs` so every `mix test` records which
obligations passed:

```elixir
ExUnit.start(formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
```

## Tasks

| Task | Does |
|---|---|
| `mix covenant.check` | Parses the Contract, runs `test/contract` with the formatter, fails on malformed blocks, dangling `record`/`invariant`/`superseded_by`/`depends_on` references, an active obligation without a tagged test, a tag naming an unknown obligation, a failing tagged test, a stale exception, or a scope ceiling exceeded; prints coverage per component and per app; writes `contracts/coverage.json`. `--no-run` reuses the last results; `--contracts DIR`, `--test-path PATH` (repeatable), `--results-dir DIR`. Exit 1 on any problem. Warns, without failing, about the components that declare no modules (see [Declaring modules](#declaring-modules)). |
| `mix covenant.check --static` | Compiles and runs no test: parses the contract test files (`Code.string_to_quoted/2`), reads every `use Covenant.Case` module's `@tag`/`@describetag`/`@moduletag obligation:` values (strings and lists, merged as ExUnit merges them) and runs every check that needs no compiled code, plus `Covenant.Case`'s compile-time rules. Module/function exception targets and `module` ceiling counters are listed as skipped; file targets and `glob` counters are checked against `--root` (default `Covenant.root/0`). Writes `contracts/coverage.static.json` (`"mode": "static"`), never `coverage.json`. For a Contract written ahead of its implementation. |
| `mix covenant.conditions` | Evaluates every record condition with a `check` (a `value` check runs in the project's VM) and lists suspect records with the failing premise. `--verbose` prints every outcome and why a condition was not checked. Exit 1 when any record is suspect; a condition that cannot be checked in this VM is counted, not failed. |
| `mix covenant.regen <component>` | Writes a regeneration pack: `PROMPT.md`, the regeneration brief, the convention, the intent (or obligations file) and records, the system intent and records, the component's contract tests and public-surface stubs. The implementation is excluded. `--out DIR` (default `tmp/covenant/regen/<component>`). |
| `mix covenant.mutate <component>` | Mutates the component's implementation, runs its contract tests against every mutant and credits each kill to the obligations tagged on the tests that caught it; writes the kill matrix. See [Mutation testing](#mutation-testing). `--jobs N`, `--seed N`, `--timeout MS`, `--module MOD` (repeatable), `--out PATH`. Exit 1 on a red baseline, an unannotated survivor or a stale annotation. |

```
$ mix covenant.check
covenant.check: running mix test test/contract
......
6 tests, 0 failures

Contract coverage (obligations with a passing test / active obligations)

  example.counter      4/4  100.0%
  example.greeter      1/1  100.0%

  app example              5/5  100.0%

  total                    5/5  100.0%

wrote contracts/coverage.json
covenant.check: the Contract holds
```

Coverage counts obligations with at least one passing test over active
obligations. Retired obligations and `kind: exception` declarations are
reported but excluded from the denominators.

### Public-surface stubs

`mix covenant.regen` reads signatures from the intent's `## Public surface`
section and renders one stub module per public module:

```markdown
- `Example.Counter.new(opts) :: t` — a counter at zero; `opts[:max]` sets the cap.
- `Example.Counter.value/1` — the current value.
```

The doc keeps the line's inline code verbatim; only the signature spans that
open the line are removed.

A reference to a module the component does not own (`System.halt(1)` or
`Ecto.UUID.cast/1` in prose, or a collaborator's `Machina.Repo.Scoped.scoped/2`)
gets no stub. Which modules the component owns:

1. If the Public surface has a `#### Modules` paragraph (or the front matter a
   `modules:` list), that list is authoritative: exactly those modules are
   stubbed and every other reference is skipped. Only the backticked names
   outside parentheses count.
2. A module that another component of the Contract lists (in its own
   `#### Modules` paragraph or `modules:`) belongs to that component, whether or
   not it is implemented yet: it is skipped, and the task prints it on a
   `skipped (owned by <component>)` line.
3. Otherwise a loadable module is foreign when its beam lies under the OTP or
   Elixir installation or a dependency's build path, and *already implemented*
   when it lies in an app of the running Mix project (umbrella children and
   `in_umbrella` dependencies included): the component declared no modules, so
   nothing says the implementation is its own and a stub would shadow it. It is
   skipped, on a `skipped (already implemented in this project)` line. A module
   that is not loadable is foreign when its first segment is a dependency's
   namespace (`Ecto` for `:ecto`), stubbed when its first segment is a namespace
   the component's obligation scopes use (or when they name no module), and
   *unplaced* otherwise.
4. A loadable module whose beam is anywhere else is stubbed and printed on a
   `possibly_foreign:` line.

An alias is merged into the one known module whose name ends in it, the known
modules being the listed ones, the ones other components list and the ones the
surface stubs: the bare `Scope` (`Scope.put/1`), a dotted fragment such as
`Repo.Scoped`, and an unplaced name such as `Spend.Policy`. It is dropped when
none or several match. The task prints one more line with the number and modules
of the skipped references no other line accounts for.

### Declaring modules

Rule 3 is a guess, and it skips the component's *own* implemented modules too: a
component that lists no modules has claimed none. Declare them, in a
`#### Modules` paragraph of the Public surface or in the front matter:

```markdown
## Public surface

#### Modules

`Example.Counter`, `Example.Counter.Log`.
```

`mix covenant.check` (and `--static`) warns about every component that declares
none, as one line that never fails the check:

```
covenant.check: warning: 2 component(s) declare no modules: example.greeter, example.widget
```

The whole-product `system` intent is never listed. (`mix covenant.mutate` reads only the
front matter's `modules:`, then derives the modules from the Public surface and the scopes.)

## Mutation testing

Obligations say what must hold; the contract tests claim to prove it. `mix
covenant.mutate <component>` (for example `mix covenant.mutate example.counter`)
checks that claim by breaking the implementation on purpose and seeing which
tests notice (IMP R26: every test proves it is worth keeping).

**What it mutates.** The component's implementation modules, in this order of
precedence: the `--module` flags, the `modules:` list in the front matter of
its intent or obligations file, the modules named in its `## Public surface`
and in the `scope` of its obligations. The source is parsed to an AST
(`Code.string_to_quoted/2` with positions), one change is applied at a time and
the result is compiled **in memory**: no file is written. A change is made by an
operator; each mutant is one change at one place.

| Operator | Change |
|---|---|
| `boolean_flip` | `true` ↔ `false` |
| `comparison_swap` | `==` ↔ `!=`, `===` ↔ `!==`, `<` → `<=` and `>=`, and so on |
| `arithmetic_swap` | `+` ↔ `-`, `*` ↔ `/` |
| `logical_swap` | `and` ↔ `or`, `&&` ↔ `\|\|` |
| `condition_negate` | `if c` → `if !c`, `unless c` → `unless !c` |
| `statement_removal` | drop a non-final function call from a block |
| `return_nil` | the last expression of a `def`/`defp` body becomes `nil` |
| `integer_shift` | `n` → `n + 1` and `n - 1` |
| `string_empty` | a non-empty string becomes `""` |
| `guard_removal` | drop the `when` guard of a clause |
| `clause_removal` | drop one clause of a `case`, `cond` or multi-clause `fn` |
| `element_removal` | drop one element of a list or one pair of a map |
| `ecto_where_removal` | drop a `\|> where(...)` stage or a `where:` key of `from` |

Docs, specs, types, compiler attributes, `defmacro`/`defguard`, `use`/`import`/
`alias`/`require`, sigils and `quote` are never mutated. The set and order of
mutants (`m001`, `m002`, ...) is a pure function of the source.

**What it runs.** The component's contract tests: the files under the
configured test paths that declare `use Covenant.Case, component: "<id>"`. The
suite runs in a worker with `MIX_ENV=test`, which boots once and hot-swaps each
mutant. The baseline (the unmutated suite) must be green or nothing is mutated.

**Verdicts.**

| Verdict | Meaning |
|---|---|
| killed | at least one test failed, for a reason other than a timeout |
| survived | every test passed |
| timeout | the only failures were test timeouts: a **survivor**, never a kill |
| invalid | the mutant does not compile; excluded from the score |

The score is `killed / (killed + survived + timed out)`.

**Credit.** A kill is credited to the obligations tagged on *every* test that
failed. The kill matrix lists, per obligation, the mutants killed in total and
the mutants **only** that obligation's tests killed (the *unique* kills): an
obligation with no unique kill caught nothing the other obligations' tests did
not also catch. It does the same per test. A test no mutant needs, whose kills
are all shared with another test, is **mutation-blind**: it is listed as a
warning (never a failure) and is a candidate for deletion or sharpening. A test
that is deliberately redundant says why with `@tag mutation_blind: "reason"`,
and the warning then carries the reason.

```
Kill matrix — covenant.conditions (Covenant.Conditions)
  127 mutants: 106 killed, 2 survived, 0 timed out, 19 invalid — score 98.2%

  obligation              killed  unique
  covenant.conditions.I1      57      25
  covenant.conditions.I2      16      13
  ...
```

The matrix is also written as JSON (`--out PATH`, default
`tmp/covenant/mutate/<component>/kill_matrix.json`): the summary, one record
per mutant with its verdict and `killed_by`, per-obligation and per-test
credit, and the survivors with their sort.

### The survivors file

A survivor is either a test not yet written or a mutant that does not matter.
Telling them apart is a judgment, and it lives in
`contracts/<app>/<component>.survivors.yml`, one entry per survivor. The task
prints a skeleton for each unsorted survivor.

```yaml
- at: lib/example/counter.ex:29:17
  operator: element_removal
  mutation: "`value: 0` → `(removed)`"   # optional
  sort: equivalent
  reason: The struct default for value is already 0.
```

`at` is `file:line:column` and `operator` an operator from the table. Without
`mutation` the entry covers every mutant with that `at` and `operator`; give it
when two mutants share both and need different judgments. `reason` is required
and should say something specific. `sort` is one of:

| Sort | The survivor is |
|---|---|
| `equivalent` | a mutant that behaves exactly like the original |
| `log-only` | a change to a message or a log line nobody pins |
| `dead-code` | in code that is never reached, or whose value is never read |
| `timeout` | a mutant the tests only timed out against |
| `evaluation-gap` | a behaviour that matters but no test pins yet |
| `decision-hole` | a behaviour the Contract leaves deliberately undecided |

A mutant inside the target of an active `kind: exception` obligation is sorted
`decision-hole` without an entry. Prefer a test to an annotation: use a sort
only with a reason a reviewer can check, and never weaken the mutation or the
implementation to dodge a mutant.

### Exit status

0 when the baseline is green and every survivor has an annotation. 1 when the
baseline is red, a survivor has no annotation, an annotation is **stale** (it
matches no survivor, because the mutant is now killed or the code moved), the
Contract or the survivors file does not parse, or a worker fails.

### Options and `--jobs`

`--module MOD` (repeatable), `--timeout MS` (per test, default 10000),
`--seed N` (the ExUnit seed; the default 0 runs in definition order),
`--jobs N`, `--out PATH`, `--contracts DIR`, `--test-path PATH` (repeatable).

`--jobs N` splits the mutants round-robin over N worker OS processes. ExUnit
creates a test's `:tmp_dir` at `tmp/<module>/<test>` under the *process's*
working directory and offers no way to move it, so workers sharing the project
would clear and rewrite each other's files and the failures that follow would
be credited as kills. With N > 1 each worker therefore runs its tests from a
private directory under the system temp directory: a symlink to every entry of
the project root (relative paths in the tests resolve as usual) and a `tmp/` of
its own, removed when the worker ends. The kill credit is the same as with
`--jobs 1`, which the contract tests of `mix covenant.mutate` check.

Isolation covers `:tmp_dir` and anything a test writes below `tmp/`. What the
tests share otherwise stays shared between workers: a fixed path under the
system temp directory, a database, a port, a named process on a distributed
node. A suite that depends on such a resource must run with `--jobs 1`.

## Configuration

```elixir
config :covenant,
  contracts_dir: "contracts",               # default
  test_paths: ["test/contract"],            # default; globs allowed
  results_dir: "_build/covenant/results"    # default, next to the Mix build dir
```

`Covenant.root/0` is the directory holding the contracts directory
(`COVENANT_ROOT`, then `config :covenant, root:`, then the parent of
`contracts_dir`, found from the working directory upwards when relative).
Contract tests resolve paths from it so they never depend on the directory
`mix test` runs in.

In an umbrella, set `contracts_dir` to an absolute path
(`Path.expand("../contracts", __DIR__)` from `config/config.exs`) and
`test_paths: ["apps/*/test/contract"]`. Results are written per app
(`<results_dir>/<app>.json`) and merged by `mix covenant.check`, so each
app's suite contributes its own tests.

Configured `test_paths` are relative to `Covenant.root/0`, not to the directory a
task runs in: `mix covenant.regen`, `mix covenant.mutate` and `mix covenant.check`
(`--static` included) find the same contract tests from the umbrella root and from
`apps/<app>`, and `mix covenant.conditions` resolves `file` conditions and `mix.lock`
against that root. A `--test-path` typed on the command line is relative to the directory
you typed it in, and `--contracts DIR` redirects the Contract without moving the root.
(`mix covenant.check` hands `mix test` the paths relative to the working directory.)
`test/fixtures/umbrella_project` is an umbrella-shaped fixture that runs the tasks from
`apps/shop`.

## Example

`test/fixtures/example_project` is a complete small project: a heavy-form
`example.counter` with four active obligations, one retired obligation and
four decision records; a light-form `example.greeter` with a declared
exception; the implementation; and the contract tests. Covenant's own suite
runs `mix covenant.check`, `mix covenant.conditions` and
`mix covenant.regen` there.

## Development

```
mix deps.get
mix test              # unit tests plus the end-to-end runs in the fixture
mix covenant.check    # Covenant checked against its own Contract
```

## Licence

MIT.
