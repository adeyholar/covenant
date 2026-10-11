# Covenant — system intent

## Purpose

Covenant is the Contract layer of IMP for Elixir: it parses a `contracts/`
directory (intents, obligations files, decision records, scope ceilings),
binds contract tests to obligations at compile time, measures contract
coverage, re-checks record premises, writes regeneration packs and mutates
a component to show which obligations its tests hold. It is a library plus
Mix tasks, with no runtime process of its own.

## Scope

Owns: the contract file formats it reads, the obligation tag protocol of
contract tests, the results and coverage formats it writes, the regeneration
pack layout, the kill matrix and the survivors file. Does not own: the
convention reviewers, anything about how a project runs its suite beyond
`mix test <paths>`.

## Environment facts

- Elixir 1.18 or later: the standard `JSON` module encodes results and
  coverage; checked by the `results-per-app` record condition.
- `yaml_elixir ~> 2.12` is the only runtime dependency; checked by the
  `yaml-via-yaml-elixir` record condition.
- `mix` is found through `PATH` when `mix covenant.check` runs the suite;
  checked by the `suite-runs-as-subprocess` record condition.
