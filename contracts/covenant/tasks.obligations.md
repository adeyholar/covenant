# covenant.tasks

## Purpose

The Mix tasks a project runs: `mix covenant.check`, `mix covenant.conditions`
and `mix covenant.regen`. Their contract is what a CI step can rely on: what
they print and their exit status.

## Obligations

### covenant.tasks.I1 — covenant.check runs the suite and reports
- **scope:** `mix covenant.check`
- **must:** run the configured contract test paths as a `mix test` subprocess with `Covenant.Formatter`, print the coverage table, write `<contracts dir>/coverage.json`, and exit 0 when the Contract holds
- **kind:** functional
- **record:** suite-runs-as-subprocess
- **status:** active

### covenant.tasks.I2 — covenant.check fails precisely on a broken Contract
- **scope:** `mix covenant.check`
- **must:** exit 1 printing each problem as `file:line: message` for a Contract that does not parse or does not hold; honour `--no-run` (read the last results) and `--contracts DIR`
- **kind:** functional
- **status:** active

### covenant.tasks.I3 — covenant.check fails when a contract test fails
- **scope:** `mix covenant.check`
- **must:** exit 1 when the suite exits non-zero, naming the failing test and its obligation
- **kind:** functional
- **status:** active

### covenant.tasks.I4 — covenant.conditions lists suspects and exits accordingly
- **scope:** `mix covenant.conditions`
- **must:** exit 0 when every machine-checkable premise holds, printing the counts (and every outcome with `--verbose`); exit 1 naming each suspect record at its line with the failing premise and reason
- **kind:** functional
- **status:** active

### covenant.tasks.I5 — covenant.regen writes a pack
- **scope:** `mix covenant.regen <component>`
- **must:** write the pack to `--out DIR` (default `tmp/covenant/regen/<component>`), list the files written and exit 0; exit 1 naming the problem for an unknown component
- **kind:** functional
- **status:** active
