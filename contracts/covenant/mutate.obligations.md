---
modules: [Covenant.Mutate, Covenant.Mutate.Matrix, Covenant.Mutate.Modules, Covenant.Mutate.Mutant, Covenant.Mutate.Mutator, Covenant.Mutate.Operators, Covenant.Mutate.Survivors]
---
# covenant.mutate

## Purpose

Mutation testing against the Contract: `mix covenant.mutate <component>`
breaks the component's implementation one AST change at a time, runs its
contract tests against each break and credits every kill to the obligations
tagged on the tests that caught it, so a test that proves nothing is
visible. The modules listed above are the ones that can be mutated in the
VM that runs the suite; `Covenant.Mutate.Runner`, `Covenant.Mutate.Workdir`
and the Mix task run the worker itself and cannot be hot-swapped by their own
mutants, so their obligations are proved by the tests but not self-mutated.

## Obligations

### covenant.mutate.I1 — Thirteen operators, one change each
- **scope:** `Covenant.Mutate.Operators.variants/1`
- **must:** produce at a node every replacement the operators allow, each replacing that one node and carrying its operator and a one-line `from` and `to`: `boolean_flip` (`true` and `false` swap), `comparison_swap` (`==` and `!=`, `===` and `!==` swap; `<` becomes `<=` and `>=`, `<=` becomes `<` and `>`, `>` becomes `>=` and `<=`, `>=` becomes `>` and `<`), `arithmetic_swap` (`+` and `-`, `*` and `/`), `logical_swap` (`and` and `or`, `&&` and `||`), `condition_negate` (`if`/`unless` take the negated condition), `statement_removal` (a non-final call of a block of several expressions goes), `return_nil` (the last expression of a `def`/`defp` body becomes `nil`, unless it is `nil`), `integer_shift` (a written integer becomes one more and one less), `string_empty` (a non-empty string or interpolation becomes `""`), `guard_removal` (a `when` guard goes), `clause_removal` (one clause of a `case`, `cond` or multi-clause `fn` goes, when there are several), `element_removal` (one element of a bracketed list or one pair of a map goes, never where a `|` is involved) and `ecto_where_removal` (a `|> where(...)` stage or a `where:` key of `from` goes)
- **kind:** functional
- **status:** active

### covenant.mutate.I2 — Mutants are enumerated deterministically at reported locations
- **scope:** `Covenant.Mutate.Mutator.sites/2`, `Covenant.Mutate.Mutator.numbered/1`
- **must:** list the mutants of an AST in one walk, inside the target modules (every module when none is named), each with the file, line and column of the node it changes and the module and function it sits in; skip documentation, specs and types, compiler attributes, macro and guard definitions, `use`/`import`/`alias`/`require`, `quote` and sigils; number them `m001`, `m002`, ... in walk order (wider than three digits past `m999`); the same source always yields the same mutants in the same order with the same ids
- **kind:** functional
- **status:** active

### covenant.mutate.I3 — A mutant is one change, compiled in memory
- **scope:** `Covenant.Mutate.Mutator.parse/2`, `Covenant.Mutate.Mutator.apply/2`, `Covenant.Mutate.Mutator.compile/2`
- **must:** apply a mutant by replacing exactly the node at its index and no other; compile an AST into loaded modules without writing a file, replacing the loaded version, and answer a mutant that does not compile with an error message that names the line and column when the compiler gives them; answer a source that does not parse with an error that names the file and line
- **kind:** functional
- **status:** active

### covenant.mutate.I4 — An invalid mutant is neither a kill nor a survivor
- **scope:** `mix covenant.mutate`
- **must:** give a mutant that does not compile the verdict `invalid` with the compiler's reason; run no test against it, credit it to no obligation, list it among no survivors and leave it out of the score's denominator
- **kind:** functional
- **status:** active

### covenant.mutate.I5 — Verdicts follow the tests' outcomes
- **scope:** `Covenant.Mutate.Runner.verdict/2`, `Covenant.Mutate.Runner.entry/2`
- **must:** judge a mutant `killed` when any test failed or was invalid for a reason other than a timeout, `killed_by` naming exactly those tests; `timeout` when the only failures were test timeouts, which makes it a survivor and never a kill; `survived` when every test passed; report a finished test as `passed`, `failed`, `timeout` (every failure an `ExUnit.TimeoutError`), `invalid`, `skipped` or `excluded`, with its obligation tags, its `mutation_blind` reason and its file relative to the project root
- **kind:** functional
- **status:** active

### covenant.mutate.I6 — The baseline must be green
- **scope:** `mix covenant.mutate`
- **must:** run the contract tests unmutated first and mutate nothing when one fails, exiting 1 and naming the failing tests; exit 1 likewise when no contract test declares the component or the contract test modules define no test
- **kind:** functional
- **status:** active

### covenant.mutate.I7 — Kills are credited to obligations, uniquely and in total
- **scope:** `Covenant.Mutate.Matrix.build/2`
- **must:** credit a killed mutant to the obligations tagged on every test that failed against it; count per testable obligation the mutants killed and the mutants only that obligation's tests killed (its unique kills), listing an obligation with no kill too, and count the same per test, counting only the mutants whose credit is exact (a mutant a `--fail-fast` run killed has partial credit, I17); list a passing test with no unique kill as mutation-blind, with its declared reason when it has one, as a warning and never a failure; score `killed / (killed + survived + timed out)` with invalid mutants excluded, and no score for no mutants
- **kind:** functional
- **status:** active

### covenant.mutate.I8 — The survivors file is read strictly
- **scope:** `Covenant.Mutate.Survivors.parse/2`, `Covenant.Mutate.Survivors.load/1`, `Covenant.Mutate.Survivors.path/2`, `Covenant.Parser.Primitive.declarations/2`
- **must:** read a YAML list of mappings with `at` (`file:line:column`), `operator` (one of the thirteen), `sort` (one of the seven: `equivalent`, `log-only`, `dead-code`, `timeout`, `evaluation-gap`, `decision-hole` or `unpromised`) `mutation` (the change as the run prints it) and `reason`, all required; report every bad entry as `file:line: message` (a missing or empty key, a key of the wrong type, an unknown operator or sort, a malformed `at`, an entry that is not a mapping, a document that is not a list, invalid YAML); read a missing or empty file as no annotations; keep the file at `<contracts>/<app>/<component>.survivors.yml` (`<contracts>/system/survivors.yml` for the system component); keep a sibling-layout primitive's survivors in the `mutants.md` beside its README, read by its extension: each line of an `equivalent` or `unpromised` block is `Module.function/arity: from -> to`, optionally `#k`, sorted as its block says, or, in an `unpromised` block only, `Module.function/arity: *`, and a wildcard in an `equivalent` block is an error
- **kind:** functional
- **status:** active

### covenant.mutate.I9 — Every survivor is sorted and every key names one mutant
- **scope:** `Covenant.Mutate.Survivors.find/2`, `Covenant.Mutate.Survivors.matches?/2`, `Covenant.Mutate.Survivors.resolve/2`, `Covenant.Mutate.Survivors.unit/1`, `Covenant.Mutate.Survivors.template/2`, `Covenant.Mutate.Matrix.build/2`
- **must:** match a survivors-file entry to the one survivor with its `at`, `operator` and `mutation`; pin each `mutants.md` declaration with a change to the one mutant of its unit (`Module.function/arity`, or the module for code outside a function) with that change, `#k` picking the k-th in source order among all of them, killed or not, and report a line that several share without `#k`, or whose `#k` is past the last, as an error (`ambiguous: N mutants in Unit share from -> to`) that sorts nothing; let a wildcard sort every survivor of its unit; sort an unannotated survivor inside the target of an active exception `decision-hole`; report every other unannotated survivor or timeout as a problem naming the mutant; judge staleness per line: an entry or declaration that names no surviving mutant is moved or unmatched, one that names only a killed mutant is stale or contradicted, and a wildcard needs at least one survivor in its unit; print an unsorted primitive survivor as a `mutants.md` line, with `#k` when its unit has others with the same change; fail on nothing else
- **kind:** functional
- **status:** active

### covenant.mutate.I10 — The modules to mutate come from the flags, the front matter or the Contract
- **scope:** `Covenant.Mutate.Modules.resolve/2`, `Covenant.Mutate.Modules.derive/1`, `Covenant.Mutate.Modules.references/1`, `Covenant.Mutate.Modules.locate/3`
- **must:** take the `--module` flags first, then the front matter's `modules:` (for a sibling-layout primitive, the modules its `covers` name, a tree as `Module.*`), then the module names in the inline code spans of the Public surface and of the obligation scopes (fenced blocks ignored), sorted and unique; expand a `Module.*` name to the project's modules under it; find each module's source file, skipping a derived module that is not loaded or whose source lies outside the project root and listing it with the reason, and refusing an explicit one
- **kind:** functional
- **status:** active

### covenant.mutate.I11 — The plan and the worker results
- **scope:** `Covenant.Mutate.plan/3`, `Covenant.Mutate.covered_by?/3`, `Covenant.Mutate.encode_raw/2`, `Covenant.Mutate.decode_raw/1`, `Covenant.Mutate.merge/1`
- **must:** resolve a component to its module names and its contract test files (a primitive's are the `*_test.exs` files beside its README), or fail naming the problem (an unknown component, with the known ones; no module, or covers naming no code; no contract test file); tell whether a primitive owns a mutant by the most specific covers reference; carry a worker's results, the per-test timeout it used (`timeout_ms`) and each mutant's credit through JSON and back unchanged; merge the workers' results by concatenating their mutants sorted by id and keeping the largest `timeout_ms`, refusing results that overlap or leave a mutant without a verdict
- **kind:** functional
- **status:** active

### covenant.mutate.I12 — The kill matrix is JSON of a fixed shape
- **scope:** `Covenant.Mutate.Matrix.to_map/1`, `mix covenant.mutate`
- **must:** write to `--out` a JSON object with the covenant version, `component`, `modules`, `files`, `seed`, `timeout_ms`, `jobs`, `fail_fast`, `baseline` (`tests`, `ms`), `summary` (`mutants`, `killed`, `survived`, `timeouts`, `invalid`, `partial`, `score`, `annotated`, `unsorted`), `mutants` (each with `id`, `at`, `file`, `line`, `column`, `operator`, `from`, `to`, `module`, `function`, `verdict`, `killed_by`, `timeouts`, `reason`, `credit`, `obligations`), `obligations` (`killed`, `unique`, `mutants`, `unique_mutants`), `tests` (`kills`, `unique_kills`, `mutants`, `unique_mutants`, `mutation_blind`, with the test's identity and tags), `survivors` (`id`, `at`, `operator`, `mutation`, `verdict`, `sort`, `reason`) and `problems`; print the table of the same numbers
- **kind:** functional
- **status:** active

### covenant.mutate.I13 — The exit status says whether the sort is complete
- **scope:** `mix covenant.mutate`
- **must:** exit 0 when the baseline is green and every survivor is annotated; exit 1 for a red baseline, an unannotated survivor, a stale or unmatched annotation, or a Contract or survivors file that does not parse, printing each problem as `file:line: message` and a ready-to-fill skeleton for every unannotated survivor
- **kind:** functional
- **status:** active

### covenant.mutate.I14 — The same sources and seed give the same matrix
- **scope:** `mix covenant.mutate`
- **must:** give two runs over unchanged sources with the same seed the same mutants, ids, verdicts and `killed_by` lists (with `--fail-fast` the same mutants, ids and verdicts: which test fails first is not pinned)
- **kind:** functional
- **status:** active

### covenant.mutate.I15 — Parallel workers get a directory of their own
- **scope:** `Covenant.Mutate.Workdir.build/2`, `Covenant.Mutate.Workdir.remove/1`, `Covenant.Mutate.Workdir.within/2`
- **must:** build, under the given base directory (the system temp directory by default), a directory named after the OS process that holds a symlink to every entry of the project root except `tmp`, and a real empty `tmp`; remove it with the symlinks, never what they point at; run a function with it as the working directory and restore the previous one even when the function raises
- **kind:** functional
- **status:** active

### covenant.mutate.I16 — The per-test timeout of a mutant run is measured from the baseline
- **scope:** `Covenant.Mutate.default_timeout/1`, `mix covenant.mutate`
- **must:** without `--timeout` give the mutants' tests a timeout of five times the slowest baseline test, in milliseconds, and never under 1000 (`default_timeout/1`; a baseline of no test measures 1000), each worker measuring its own baseline and the matrix recording the largest as `timeout_ms`, and run the baseline itself under the ExUnit default of 60 seconds; with `--timeout MS` give them exactly MS; leave a test that sets its own `@tag timeout:` with it
- **why:** a flat ceiling holds every test a mutant that loops forever reaches for the whole ceiling, so a database-backed suite spent about a minute per mutant (half a day for a module of 700), and it is too short for a suite whose tests are slow
- **kind:** functional
- **status:** active

### covenant.mutate.I17 — --fail-fast stops a run at its first failure and says the credit is partial
- **scope:** `mix covenant.mutate`, `Covenant.Mutate.Matrix.build/2`
- **must:** with `--fail-fast` stop each mutant's run at its first failing test (ExUnit `max_failures: 1`) and give every mutant the verdict a full run gives; mark a mutant such a run killed `credit: partial` (its `killed_by` names only the tests that failed before the stop) and every other mutant `exact` (a survivor ran every test, an invalid mutant none); run a mutant again in full when its fail-fast run failed on timeouts alone, since a timeout is a failure to ExUnit and ends the run before a test that would kill the mutant; count in an obligation's `killed` and `unique` and a test's `kills` and `unique_kills` the mutants with exact credit only; judge no test mutation-blind (`mutation_blind` is null unless the test declares a reason); write `fail_fast` and the number of partial kills (`summary.partial`) to the JSON and say in the table's header that the credit is partial; document in `mix help covenant.mutate` that a fail-fast matrix proves kills, not obligation credit
- **why:** the verdict of a kill does not depend on which test caught it, but its credit does: a unique kill cannot be told from a test that merely ran first, so a fast run that credited it would reward the order of the tests
- **kind:** functional
- **status:** active

### covenant.mutate.I18 — Progress reports its pace and its ETA
- **scope:** `Covenant.Mutate.progress_due?/2`, `Covenant.Mutate.progress_line/3`, `mix covenant.mutate`
- **must:** after every 25th mutant of a worker's slice, but not after its last, print `progress: <done>/<total> mutants (<percent>%), <rate> mutants/min, ETA <time>`, the rate being the mutants done over the time since the first of them started and the time left the mutants remaining at that rate, written as hours and minutes from an hour, minutes and seconds from a minute and seconds below; with `--jobs N` each worker prints its own, prefixed `[i/N]`
- **kind:** functional
- **status:** active
