# Changelog

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
