# Changelog

## Unreleased (2026-10-10)

- `mix covenant.check --static` checks a Contract without compiling or
  running its tests (`Covenant.Static`); static coverage goes to
  `contracts/coverage.static.json`.
- `Covenant.root/0`: the directory holding the contracts directory,
  independent of the working directory.
- `Covenant.Check.run/3` takes `mode: :static`; `Covenant.Coverage.compute/3`
  takes `covered: :tagged`.

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
