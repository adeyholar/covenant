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

### covenant.check.I3 — Failed tests fail the check; skipped tests do not count as coverage
- **scope:** `Covenant.Check.run/3`
- **must:** report a tagged test that failed or was invalid; count skipped and excluded tests as tagged (no "untested" problem) but not as coverage
- **kind:** functional
- **status:** active

### covenant.check.I4 — Stale exceptions fail
- **scope:** `Covenant.Check.run/3`, `Covenant.Target`
- **must:** resolve an active exception's `target` as `Module.function/arity` (public function or macro), `Module` or a file path relative to the root and report it when it no longer exists or cannot be read; accept targets that exist; skip retired exceptions
- **kind:** functional
- **record:** targets-are-public-code
- **status:** active

### covenant.check.I5 — Scope ceilings are counted and enforced
- **scope:** `Covenant.Check.run/3`, `Covenant.Contract.Ceiling.count/2`
- **must:** count a `glob` ceiling as the files matching its pattern under the root and a `module` ceiling by calling `module.function/0`; report a count above the ceiling and a counter that cannot be called; a count at the ceiling passes
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
