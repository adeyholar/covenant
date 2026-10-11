---
modules: [Covenant.Contract, Covenant.Contract.Component, Covenant.Contract.Obligation, Covenant.Contract.Record, Covenant.Contract.Condition, Covenant.Contract.Section, Covenant.Contract.Ceiling, Covenant.Contract.Validate, Covenant.Parser.Markdown, Covenant.Parser.Records, Covenant.Parser.Scope, Covenant.Error, Covenant.ContractError]
---
# covenant.contract

## Purpose

Reads a contracts directory into a `Covenant.Contract`: components from
intent and obligations files, decision records, scope ceilings, every
problem anchored to a file and line.

## Obligations

### covenant.contract.I1 — Files map to components by path
- **scope:** `Covenant.Contract.load/1`, `Covenant.Contract.component_id/2`
- **must:** read `<app>/<name>.intent.md` as the heavy-form component `<app>.<name>`, `<app>/<name>.obligations.md` as the light form, `system/intent.md` as the component `system`; attach `<app>/<name>.decisions.yml` to its component and keep records whose component has no file; expose obligations by id
- **kind:** functional
- **status:** active

### covenant.contract.I2 — Obligation blocks are read in the convention's shape
- **scope:** `Covenant.Parser.Markdown`
- **must:** read `### <id> — <title>` (em dash, en dash or hyphen) followed by `- **field:** value` lines, joining indented continuation lines, keeping unknown fields, stripping backticks from `record` and `target`, ignoring headings and fields inside fenced code (a fence closes only with the same character and at least the same length), ignoring a leading byte-order mark, in every form
- **kind:** functional
- **status:** active

### covenant.contract.I3 — Required fields and headings are enforced per form, at a precise line
- **scope:** `Covenant.Parser.Markdown`
- **must:** fail a block missing `scope`, `must`, `kind` or `status` (and `why` in heavy form), an empty field, an exception without `target`, a heading that is not the block shape; fail a heavy intent missing a required `##` section, with sections out of order or duplicated, without the revision log, or with an empty Purpose; fail a light file without Purpose; each error names the file and the line of the block, field or heading
- **kind:** functional
- **status:** active

### covenant.contract.I4 — Ids and enumerations are validated and unique
- **scope:** `Covenant.Parser.Markdown`, `Covenant.Parser.Records`, `Covenant.Contract.load/1`
- **must:** reject an obligation id outside `<component id>.I<n>`, an unknown `kind` or `status`, a duplicated obligation id, a component declared in both forms, and a record id declared twice in one file or across files, pointing at the second declaration
- **kind:** functional
- **status:** active

### covenant.contract.I5 — Decision records are typed and anchored at their item line
- **scope:** `Covenant.Parser.Records`
- **must:** require `id` (kebab-case), `date` (`YYYY-MM-DD`), `decision`, `driver` and `approved_by`; type-check `kind`, `invariant`, `source`, `depends_on`, `superseded_by`, `alternatives` and `conditions` (plain strings or `text` with an optional `check` carrying a `kind`); anchor each error at the record's `- ` item line; treat an empty file as no records and a non-list as an error
- **kind:** persisted-format
- **status:** active

### covenant.contract.I6 — Scope ceilings parse with their counters
- **scope:** `Covenant.Parser.Scope`
- **must:** read `name`, a non-negative integer `ceiling`, a `glob` counter with `pattern` or a `module` counter with `module` and `function`, optional `why` and `record`, anchored at the item line; reject anything else precisely
- **kind:** persisted-format
- **status:** active

### covenant.contract.I7 — Every problem is reported; none hides another
- **scope:** `Covenant.Contract.load/1`, every parser
- **must:** collect every problem across every file, including unreadable files, and return them together instead of stopping at the first
- **kind:** functional
- **status:** active

### covenant.contract.I8 — An empty directory is a valid Contract; a missing one is not
- **scope:** `Covenant.Contract.load/1`
- **must:** return an empty Contract for a directory with no contract files, and an error naming the path for a directory that does not exist
- **kind:** functional
- **status:** active

### covenant.contract.I9 — Dangling references are found
- **scope:** `Covenant.Contract.Validate.dangling/1`
- **must:** report an obligation whose `record`, a record whose `invariant`, `superseded_by` or `depends_on`, and a ceiling whose `record` names something that does not exist, each at its own line, and report nothing for a consistent Contract
- **kind:** functional
- **record:** references-checked-at-check-time
- **status:** active

### covenant.contract.I10 — A malformed obligation block is rejected, never skipped
- **scope:** `Covenant.Parser.Markdown`
- **must:** fail, at the offending line, an obligation-shaped heading (`<id>.I<n> — <title>`) at any level but `###`, an obligation heading indented by one to three spaces, a code fence never closed, a field line outside an obligation block, and a field repeated within one block; an obligation must not vanish or change because of how its neighbours are written
- **kind:** functional
- **status:** active

### covenant.contract.I11 — A YAML Contract file is read whole or rejected
- **scope:** `Covenant.Parser.Records`, `Covenant.Parser.Scope`
- **must:** fail, at the offending line and without raising, a file holding more than one YAML document, a `<<` merge key, a mapping key repeated within one mapping, and a field whose value is a mapping or list where text is expected (`decision`, `driver`, `approved_by`, `evidence`, `expires`, `notes`, an alternative's `rejected`, a ceiling's `why` and `record`); a ceiling or record must not vanish or change because the YAML reader would drop, ignore or pick between values
- **kind:** functional
- **status:** active
