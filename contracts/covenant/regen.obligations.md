# covenant.regen

## Purpose

Writes a regeneration pack: everything a fresh agent needs to rebuild a
component from its Contract, with the implementation excluded.

## Obligations

### covenant.regen.I1 — The pack is the Contract without the implementation
- **scope:** `Covenant.Regen.write_pack/3`
- **must:** write `PROMPT.md`, `REGENERATION_BRIEF.md`, the contracts README as `CONTRACT_CONVENTION.md`, the component's intent or obligations file and records, the system intent and records, the component's contract tests and public-surface stubs, verbatim where copied, and never the implementation; the prompt names the component, forbids looking for the old implementation, lists the active obligations and the files in the pack
- **kind:** functional
- **status:** active

### covenant.regen.I2 — Stubs come from the Public surface
- **scope:** `Covenant.Regen.signatures/1`, `Covenant.Regen.stubs/1`
- **must:** read `Module.function(args) :: type` and `Module.function/arity` code spans from the `## Public surface` section, keep the line's prose as the doc, and render one compilable module per public module whose functions raise until implemented
- **kind:** functional
- **status:** active

### covenant.regen.I3 — A thin component still gets a complete pack
- **scope:** `Covenant.Regen.write_pack/3`
- **must:** for a component without a Public surface, a Regeneration brief, records or contract tests, write the pack anyway and say in the brief and prompt what is absent
- **kind:** functional
- **status:** active

### covenant.regen.I4 — Packs are found by declaration and rebuilt from scratch
- **scope:** `Covenant.Regen.write_pack/3`, `Covenant.Regen.find_tests/3`
- **must:** find contract tests by their `use Covenant.Case, component: "<id>"` declaration through the configured paths or globs, refuse an unknown component naming the known ones, and replace any existing pack directory entirely
- **kind:** functional
- **status:** active
