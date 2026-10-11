---
modules: [Covenant.Parser.Primitive, Covenant.Covers]
---
# covenant.primitive

## Purpose

The sibling layout: Covenant reads the Contract the way flinch, qualm and
exhale read it, `contract/<primitive>/README.md` with `- **A1**` obligations
and a `covers` block, Contract tests beside each README that name their
obligations in `# Contract: calc/A1` comments, and an optional `mutants.md`
of declared survivors. A primitive is a component of form `:primitive`, so
check, coverage, regen and mutate treat both layouts alike.

## Obligations

### covenant.primitive.I1 — A primitive is a directory with a README, and its obligations are the README's `- **A1**` lines
- **scope:** `Covenant.Parser.Primitive.parse_dir/1`, `Covenant.Parser.Primitive.parse_readme/3`, `Covenant.Contract.load/2`
- **must:** read every direct subdirectory of the sibling directory that holds a README.md as a primitive named after the directory (component id `<name>`, form `:primitive`, app `contract`), skipping names that start with `.` or `_` and subdirectories without a README.md, and failing on a name that is not snake_case; read each line outside a fence of exactly the form `- **A1** text` (a dash, one space, uppercase letters then digits in bold, then the text) as an active functional obligation with the full id `<primitive>/<id>`, its text as title, at its line; fail on any other line that holds a bold id (another bullet, extra spaces, a colon, an indented or numbered item, a lowercase id, an id with no text), on a fence that is never closed, and on a full id declared twice; load a Contract from the sibling directory alone, from the contracts directory alone, or from both; only a list item (`- `, `* `, `+ ` or `1. `) that opens with a bold id is a candidate obligation line, so bold words in prose ("stored in **S3** buckets") are prose; a list item is never a Setext heading and a `---` or `===` line right after one (or after a paragraph holding one) is a thematic break, so the obligation above it stays
- **kind:** functional
- **status:** active

### covenant.primitive.I2 — A covers block names modules, trees and functions, and each block kind lives in its own file
- **scope:** `Covenant.Covers.parse/1`, `Covenant.Parser.Primitive.parse_readme/3`
- **must:** read each line of a fenced `covers` block in a README as a module (`MyApp.Calc`), a tree (`MyApp.Calc.*`) or a function (`MyApp.Calc.add/2`), ignoring blank lines and `#` comments; fail on any other line at its line; fail on a `covers` block in any other `.md` file of the primitive and on an `equivalent` or `unpromised` block outside `mutants.md`, naming the file it belongs in; follow CommonMark fences (three or more backticks or tildes, closed by the same character at least as many times); a `covers` reference is resolved without creating atoms (the module's atom if it exists, else an atom only when a beam of that name is on the code path, else it is not loaded), and a function reference is satisfied by a public function or a public macro of that name and arity
- **kind:** functional
- **status:** active

### covenant.primitive.I3 — The most specific covers reference owns the code
- **scope:** `Covenant.Covers.owners/3`, `Covenant.Covers.specificity/3`, `Covenant.Covers.expand/2`
- **must:** give the code at a module and function to the primitive whose reference names it most specifically: a function over a module, a module over a tree, a deeper tree over a shallower one; give code outside a function only to module and tree references; return every primitive tied at the best specificity and none when no reference names the code; expand `Module.*` to the module and every module under it, and nothing else
- **kind:** functional
- **status:** active

### covenant.primitive.I4 — A Contract test names its obligations in comments that Covenant.Case reads at compile time
- **scope:** `Covenant.Case`, `Covenant.Parser.Primitive.comment_ids/2`, `Covenant.Parser.Primitive.primitive_of/2`
- **must:** in a file under `contract/<primitive>/`, take the primitive as the component when `component:` is left out and refuse another component; read the ids of the `# Contract:` comments in the contiguous comment and attribute lines directly above each test (several ids per line separated by commas, or several lines) and merge them with its `@tag obligation:`, so the test's `obligation` tag holds them all; raise a compile error at the test's line for a test that names no obligation, an unknown id and another primitive's id; outside the sibling layout, raise a compile error for a module that tests a primitive and for a test with a `# Contract:` comment naming a primitive id (`calc/A1`), and compile one whose `# Contract:` comment is prose; ids on a `# Contract:` line are split on commas only and trimmed, so trailing prose is never an id; in the sibling layout a `# Contract:` comment that is not directly above a test (above a `setup`, a `defp`, or after a blank line) is a compile error at the comment's line, judged only within the module's own lines (a file holding two `Covenant.Case` modules checks each against its own) and counting only real comments (`# Contract:` text inside a heredoc or a string is not one), also for a module that has no test
- **kind:** functional
- **status:** active

### covenant.primitive.I5 — mutants.md declares survivors under a heading that gives the reason
- **scope:** `Covenant.Parser.Primitive.declarations/2`, `Covenant.Parser.Primitive.change?/3`, `Covenant.Mutate.Survivors.load/1`, `Covenant.Mutate.Survivors.matches?/2`, `Covenant.Mutate.Survivors.path/2`
- **must:** read each line of an `equivalent` or `unpromised` block in `contract/<primitive>/mutants.md` as `Module.function/arity: from -> to` (a mutation outside any function is declared against the bare module: `Module: from -> to`), optionally followed by an occurrence `#k`, keeping the change as written so a change with arrows of its own (`fn x -> x end`) still names its mutant (`->` or `→` between `from` and `to`, backticks around them accepted), or, in an `unpromised` block only, `Module.function/arity: *` (or `Module: *`); give it the sort of its block and, as its reason, the nearest heading above the block plus the prose between them; fail on a block with no heading above it, a fence that is never closed, a wildcard in an `equivalent` block, a line of another shape, and a line declaring what another already does
- **kind:** functional
- **status:** active

### covenant.primitive.I6 — mix covenant.check holds the sibling layout to flinch's rules
- **scope:** `mix covenant.check`, `mix covenant.check --static`, `Covenant.Check.run/3`, `Covenant.Check.strays/2`
- **must:** run the sibling directory's Contract tests with the rest and report the primitives' coverage under the app `contract`, writing the coverage file into the sibling directory when there is no contracts directory; fail on an obligation no Contract test names, a `covers` line that names no loadable module or public function, two primitives naming the same code, and a `# Contract:` comment or a primitive obligation tag in a test file outside the sibling directory that `mix test` would load (its `test_load_filters` and `test_ignore_filters` honoured); in `--static`, read the comments from the source and list the covers checks as skipped
- **kind:** functional
- **status:** active

### covenant.primitive.I7 — mix covenant.mutate and mix covenant.regen take a primitive by its name
- **scope:** `mix covenant.mutate`, `mix covenant.regen`, `Covenant.Mutate.covered_by?/3`, `Covenant.Regen.covered/2`, `Covenant.Mutate.Modules.resolve/2`
- **must:** mutate the modules a primitive's covers name (a tree expanded to the project's modules under it), keeping only the mutants whose code the primitive owns by the most specific reference; run the Contract tests beside its README; sort its survivors from its `mutants.md` and fail on an unsorted survivor or a declaration that a test contradicts or that matches nothing, printing the unsorted ones as a block to paste into `mutants.md`; write a regeneration pack with its README, its `mutants.md` and its Contract tests at their paths from the directory that holds the sibling layout (`contract/<primitive>/...`, wherever the root is), and one stub per module its covers name, holding the public functions it owns; compute the whole pack before replacing the output directory, and refuse an output directory that holds the project root
- **kind:** functional
- **status:** active

### covenant.primitive.I8 — The root is the nearest directory that holds either layout
- **scope:** `Covenant.root/0`, `Covenant.sibling_dir/0`
- **must:** take the root to be `COVENANT_ROOT`, else `config :covenant, root:`, else the Mix project's directory (the umbrella's, for an app); only outside any Mix project find it as the nearest of the working directory and its ancestors that holds the contracts directory, or the sibling directory with a primitive in it, so a project with only the sibling layout has a root and a project nested in another finds its own; `contracts_dir` (absolute, or relative with `..`) locates the Contract, relative to the root, and never defines the root; resolve `sibling_dir/0` against the root
- **why:** a classic project's `test/contract` directory has no README.md in its subdirectories; without the primitive rule it passed for a sibling directory when a task ran from `test/`
- **kind:** functional
- **status:** active
