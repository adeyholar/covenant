---
modules: [Covenant.Case]
---
# covenant.case

## Purpose

`use Covenant.Case, component: "<id>"` wraps `ExUnit.Case` and binds every
test in the module to the Contract at compile time.

## Obligations

### covenant.case.I1 — Tags name active obligations of the module's component
- **scope:** `Covenant.Case`
- **must:** compile a module whose tests carry `@tag obligation:` with a string or a list of strings naming active obligations of the declared component; fail compilation for an unknown id, a retired id, an id of another component, or a tag that is not a string or list of strings
- **kind:** functional
- **record:** same-component-tags
- **status:** active

### covenant.case.I2 — An untagged test is a compile error
- **scope:** `Covenant.Case`
- **must:** fail compilation of any `test` without an `obligation` tag, including tests inside `describe`, with a message that shows the expected tag
- **kind:** functional
- **record:** untagged-test-is-compile-error
- **status:** active

### covenant.case.I3 — Compile errors name the test's file and line
- **scope:** `Covenant.Case`
- **must:** raise a `CompileError` whose `file` and `line` are those of the offending `test`
- **kind:** functional
- **status:** active

### covenant.case.I4 — Module-level problems are compile errors too
- **scope:** `Covenant.Case.__using__/1`
- **must:** fail compilation when `component:` is missing, names an unknown component (listing the known ones), or when the Contract itself cannot be parsed (listing its problems)
- **kind:** functional
- **status:** active

### covenant.case.I5 — Contract test modules are marked
- **scope:** `Covenant.Case`
- **must:** give the module `@moduletag :contract` and `@moduletag covenant_component: <id>` so filters and `Covenant.Formatter` can tell contract tests apart
- **kind:** persisted-format
- **status:** active
