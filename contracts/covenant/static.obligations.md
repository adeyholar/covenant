---
modules: [Covenant.Static, Covenant]
---
# covenant.static

## Purpose

`Covenant.Static` reads contract test files without compiling or running
them, so `mix covenant.check --static` can hold a Contract written ahead of
its implementation (or checked where the code cannot be built) to the same
tag rules as a real run. It also provides `Covenant.root/0`, the directory
contract tests resolve paths from.

## Obligations

### covenant.static.I1 — Tags are read as ExUnit merges them
- **scope:** `Covenant.Static.scan/2`, `Covenant.Static.scan_source/2`
- **must:** read every `test` and `property` with a body in a module that has `use Covenant.Case, component: "<literal>"`, including those inside `describe` blocks, with the `obligation` tag ExUnit would give it: a literal string or list of strings from `@tag` over `@describetag` over `@moduletag`, the last value winning within a level and within one keyword list, and a later tag overriding an earlier one (`@tag :obligation` after `@tag obligation: "x"` leaves `obligation: true`, which is not a literal string); name each test as ExUnit does (`test <describe> <name>`); return each as a `Covenant.Results.Test` with state `:tagged`
- **kind:** functional
- **record:** static-reads-literals
- **status:** active

### covenant.static.I2 — Only Covenant.Case modules count, each on its own
- **scope:** `Covenant.Static.scan_source/2`
- **must:** ignore modules without `use Covenant.Case` (helper modules in the same file included) and read a nested `defmodule` as its own module with its own component and tags; treat `use <wrapper>, component: "<literal>"` exactly like `use Covenant.Case` for each wrapper module listed in `config :covenant, case_modules: [...]`; a module that has an `obligation` tag but no `use` it can read is a problem at the module's file and line saying that static mode reads only a literal `use Covenant.Case, component: "..."` (or a listed wrapper), instead of silently ignoring its tests
- **kind:** functional
- **status:** active

### covenant.static.I3 — What only a reader can see is a problem at the line
- **scope:** `Covenant.Static.scan_source/2`
- **must:** report at file and line: a file that does not parse; a `component:` or `obligation` tag that is not a literal; a test with no obligation tag; a second `obligation:` tag at one level (ExUnit keeps the last, so the first is silently lost); a `@tag` before `describe` or at the end of a module; a `test` or `property` with no body; a `@describetag` outside a `describe` block (ExUnit raises); a test name used twice in one module (a compile error in ExUnit); a `test` or `property` inside `for`, `Enum.each`, `if`, `unless`, `case`, `cond` or any other expression that can define zero or many of them, which is never credited and is not a problem but is returned by `scan/2` and `scan_source/3` in `generated` (file, line, name); and never raise on any of these
- **kind:** functional
- **record:** static-reads-literals
- **status:** active

### covenant.static.I4 — The compile-time rules of Covenant.Case hold statically
- **scope:** `Covenant.Static.problems/2`
- **must:** report a module naming an unknown component, a test tagged with another component's obligation and a test tagged with a retired obligation, each at the test's (or module's) file and line; leave unknown obligation ids to `Covenant.Check.run/3`
- **kind:** functional
- **record:** same-component-tags
- **status:** active

### covenant.static.I5 — Covenant.root/0 does not depend on the working directory
- **scope:** `Covenant.root/0`
- **must:** return, as an absolute path, `COVENANT_ROOT` when set, else `config :covenant, root:`, else the parent of an absolute `contracts_dir`, else the parent of `contracts_dir` resolved from the nearest of the working directory and its ancestors where it is a directory, else the working directory; the same answer from any directory under the root
- **kind:** functional
- **record:** root-is-contracts-parent
- **status:** active

### covenant.static.I6 — Test paths resolve against the root
- **scope:** `Covenant.test_paths/0`, `Covenant.test_paths/1`
- **must:** return the configured `:test_paths` (default `["test/contract"]`) as absolute paths, each relative entry resolved against `Covenant.root/0` and never against the working directory, an absolute entry and a glob left as they are; with `--test-path` values typed on the command line, return them resolved against the working directory, and with none, the configured ones; the same answer from any directory under the root
- **kind:** functional
- **record:** test-paths-resolve-against-root
- **status:** active

### covenant.static.I7 — Test files are the ones the project's test pattern names
- **scope:** `Covenant.Static.expand/1`
- **must:** expand files, directories and globs to the files whose name matches the project's `test_pattern` from `Mix.Project.config/0` (default `*_test.exs`; `*` and `?` are wildcards and `{a,b}` is an alternation, so `*_{test,spec}.exs` matches both suffixes), so a project with `test_pattern: "*_check.exs"` is scanned for those files and not for `*_test.exs`
- **kind:** functional
- **status:** active
