---
modules: [Covenant.Results, Covenant.Formatter]
---
# covenant.results

## Purpose

`Covenant.Formatter` records obligation-tagged tests as they finish and
`Covenant.Results` persists and reads them back.

## Obligations

### covenant.results.I1 — Only tagged tests are recorded, with their outcome
- **scope:** `Covenant.Formatter`, `Covenant.Results.from_ex_unit/1`
- **must:** record every finished test carrying an `obligation` tag with its module, name, file (relative to the project), line, component, obligations (a string tag becomes a one-element list) and state among `passed`, `failed`, `skipped`, `excluded`, `invalid`; ignore untagged tests
- **kind:** persisted-format
- **status:** active

### covenant.results.I2 — Results are written per app and merged back
- **scope:** `Covenant.Formatter`, `Covenant.Results.write/3`, `Covenant.Results.read_dir/1`, `Covenant.results_dir/0`
- **must:** write `<results_dir>/<app>.json` at suite end, where `results_dir` is `COVENANT_RESULTS_DIR`, then the `:covenant` `:results_dir` config, then `_build/covenant/results` next to the Mix build directory; read every file in the directory back in file order
- **kind:** persisted-format
- **record:** results-per-app
- **status:** active

### covenant.results.I3 — Bad results are reported, never guessed
- **scope:** `Covenant.Results.read_dir/1`, `Covenant.Results.read_file/1`
- **must:** report an empty results directory with what to do, a corrupt or foreign file with its path, and decode an unknown state as `invalid`
- **kind:** functional
- **status:** active

### covenant.results.I4 — Tests group under every obligation they carry
- **scope:** `Covenant.Results.by_obligation/1`
- **must:** list a test under each obligation it is tagged with, keeping file order
- **kind:** functional
- **status:** active
