---
modules: [Covenant.Check, Covenant.Coverage, Covenant.Target, Covenant.JSON]
---
# covenant.check

## Purpose

`Covenant.Check.run/3` is the pure core of `mix covenant.check`: given the
Contract and a test run it returns every problem and the coverage table.

## Obligations

### covenant.check.I1 — An active obligation without a tagged test fails
- **scope:** `Covenant.Check.run/3`
- **must:** report every active, non-exception obligation with no tagged test at the obligation's line; retired obligations and `kind: exception` blocks need no test
- **kind:** functional
- **record:** exceptions-need-no-test
- **status:** active

### covenant.check.I2 — A tag naming an unknown obligation fails at the test
- **scope:** `Covenant.Check.run/3`
- **must:** report every test tagged with an id the Contract does not declare, at the test's file and line
- **kind:** functional
- **status:** active

### covenant.check.I3 — Failed tests fail the check; an obligation needs a passing test
- **scope:** `Covenant.Check.run/3`
- **must:** report every tagged test result that failed or was invalid, each of the results a parameterized test (`parameterize:`) produces under one module and name included (a passing result never hides a failed one, so a `--no-run` over such results cannot hold); in a run, report an active obligation none of whose tagged tests passed because some were skipped or excluded (`@tag :skip`, `--exclude`, `ExUnit.configure(exclude:)`) as an `active obligation <id> has no passing test: N tagged test(s) were skipped or excluded: <names>` problem, so a skipped or excluded test is never coverage (a proof that lives elsewhere is declared a `kind: exception`); in `mode: :static`, where nothing runs, a tagged test is enough
- **kind:** functional
- **status:** active

### covenant.check.I4 — Stale exceptions fail
- **scope:** `Covenant.Check.run/3`, `Covenant.Target`
- **must:** resolve an active exception's `target` as `Module.function/arity` (public function or macro; a leading `Elixir.` is accepted), `Module` or a file path relative to the root and report it when it no longer exists or cannot be read; accept targets that exist; skip retired exceptions. Targets are relative: an absolute or `~` path is an error saying it must be relative to the project root, and a relative path that expands outside the root (`..`) is reported as outside the project root; neither is ever resolved (a symlink inside the root pointing outside it is followed). The names in a target never become atoms: a module is looked up only when its atom already exists, a function is matched by name against the loaded module's exports, and a target whose names are unknown is reported as no longer existing
- **kind:** functional
- **record:** targets-are-public-code
- **status:** active

### covenant.check.I5 — Scope ceilings are counted and enforced
- **scope:** `Covenant.Check.run/3`, `Covenant.Contract.Ceiling.count/2`
- **must:** count a `glob` ceiling as the files matching its pattern under the root (a pattern that is absolute or has a `..` segment is a `cannot be counted` problem naming it, never a count of files outside the root; a malformed pattern such as `{a,b` is the same problem, `glob pattern ... is malformed`, never a crash) and a `module` ceiling by calling `module.function/0`; report a count above the ceiling and a counter that cannot be called (module not loaded, function not exported, a return that is not a non-negative integer); a count at the ceiling passes. A `module` counter that raises, throws or exits leaves its ceiling unchecked: a `scope ceiling `<name>` unchecked: <exception module>` warning in `Report.warnings`, never a problem, and the check still completes and writes `coverage.json`; a glob pattern that is malformed, holds a null byte or is not valid UTF-8 is a `cannot be counted` problem naming it, never a crash
- **kind:** functional
- **status:** active

### covenant.check.I6 — Dangling references are problems, and problems are sorted
- **scope:** `Covenant.Check.run/3`
- **must:** include every dangling reference in the report and return problems sorted by file then line
- **kind:** functional
- **record:** references-checked-at-check-time
- **status:** active

### covenant.check.I7 — Coverage is passing obligations over active ones
- **scope:** `Covenant.Coverage`
- **must:** count, per component, per app and overall, the active non-exception obligations with at least one passing test over the active non-exception obligations; report retired and exception obligations without counting them; render the table with percentages and `n/a` for empty denominators
- **kind:** functional
- **record:** exceptions-need-no-test
- **status:** active

### covenant.check.I8 — coverage.json is deterministic
- **scope:** `Covenant.Coverage.to_map/1`, `Covenant.JSON`
- **must:** produce string-keyed, JSON-ready data carrying the Covenant version, totals, apps and components with per-obligation status, kind, counts and test names; encode with sorted keys so equal inputs give equal bytes
- **kind:** persisted-format
- **status:** active

### covenant.check.I9 — A fully tested Contract holds
- **scope:** `Covenant.Check.run/3`
- **must:** return no problems and 100% coverage when every active obligation has a passing test, every exception target exists and no ceiling is exceeded
- **kind:** functional
- **status:** active

### covenant.check.I10 — Static mode skips only what needs compiled code
- **scope:** `Covenant.Check.run/3` with `mode: :static`, `Covenant.Coverage.compute/3`
- **must:** list exception targets naming a module or function and `module` ceiling counters in `Report.skipped` instead of reporting them; still check file targets, `glob` ceilings, dangling references, untested obligations and unknown tags; count an obligation as covered when a test is tagged with it and mark the coverage `mode: :static`
- **kind:** functional
- **record:** static-skips-compiled-checks
- **status:** active

### covenant.check.I11 — A component that declares no modules is a warning, never a failure
- **scope:** `Covenant.Check.run/3`, `mix covenant.check`
- **must:** list, in `Report.warnings` as one `N component(s) declare no modules: <ids>` line with the ids sorted, every component other than the whole-product `system` whose Public surface has no `#### Modules` paragraph and whose front matter has no `modules:`; leave `Report.ok?/1` and the coverage as they are; `mix covenant.check` and `mix covenant.check --static` print the line as `covenant.check: warning: ...`
- **why:** regeneration and mutation can only guess which modules a component without a list owns
- **kind:** functional
- **record:** undeclared-modules-warn-only
- **status:** active
