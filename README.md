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
`module.function/0`. A count above the ceiling fails `mix covenant.check`.

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
| `mix covenant.check` | Parses the Contract, runs `test/contract` with the formatter, fails on malformed blocks, dangling `record`/`invariant`/`superseded_by`/`depends_on` references, an active obligation without a tagged test, a tag naming an unknown obligation, a failing tagged test, a stale exception, or a scope ceiling exceeded; prints coverage per component and per app; writes `contracts/coverage.json`. `--no-run` reuses the last results; `--contracts DIR`, `--test-path PATH` (repeatable), `--results-dir DIR`. Exit 1 on any problem. |
| `mix covenant.conditions` | Evaluates every record condition with a `check` and lists suspect records with the failing premise. `--verbose` prints every outcome. Exit 1 when any record is suspect. |
| `mix covenant.regen <component>` | Writes a regeneration pack: `PROMPT.md`, the regeneration brief, the convention, the intent (or obligations file) and records, the system intent and records, the component's contract tests and public-surface stubs. The implementation is excluded. `--out DIR` (default `tmp/covenant/regen/<component>`). |

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

## Configuration

```elixir
config :covenant,
  contracts_dir: "contracts",               # default
  test_paths: ["test/contract"],            # default; globs allowed
  results_dir: "_build/covenant/results"    # default, next to the Mix build dir
```

In an umbrella, set `contracts_dir` to an absolute path
(`Path.expand("../contracts", __DIR__)` from `config/config.exs`) and
`test_paths: ["apps/*/test/contract"]`. Results are written per app
(`<results_dir>/<app>.json`) and merged by `mix covenant.check`, so each
app's suite contributes its own tests.

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
