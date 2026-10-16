# Mutation testing during development

Use a small set of mutants while a design changes. Run the full component at
a stable checkpoint. The fast loop and the full run have different purposes.

## Fast loop

Run from the project that uses Covenant. Keep its normal module profile and
macro mode. Select IDs from a previous result for that profile:

```sh
mix covenant.mutate jido.agent --macros \
  --only m0684,m0985,m1034 --fail-fast \
  --prioritize tmp/covenant/agent-review-profile.json \
  --jobs 1 --seed 0 --timeout 5000 --max-runtime 60000 \
  --out tmp/covenant/agent-dev.json
```

The previous result is a scheduling hint. If it has no killing test for a
selected mutant, the whole suite runs. After a test catches that mutant, the
next loop can use the new result as its hint file:

```sh
mix covenant.mutate jido.agent --macros \
  --only m0684,m0985,m1034 --fail-fast \
  --prioritize tmp/covenant/agent-dev.json \
  --jobs 1 --seed 0 --timeout 5000 --max-runtime 60000 \
  --out tmp/covenant/agent-dev.json
```

Covenant loads the old hint file before it writes the new result. A hint names
an exact source site, operator, and change. The current passing baseline must
contain the hinted test. Covenant uses that baseline's durations to select one
cheap killing test. It first checks that test against the original code on its
own. A failed control disables the hint and requires a passing original suite
before mutation continues. It does not create atoms from saved module or test names.
If the test passes, disappears, is excluded, or only times out, Covenant falls
back to the full current suite. A real failure is required for a kill.

Each loop still compiles the targets, checks the full original baseline, uses
a private work directory, and verifies the full original suite at the end.
By default, macro callers and contract tests compile against each mutant.
Prioritization alone reuses no verdict. A stale hint can cost time; it cannot
prove a kill or a survivor. The separate opt-in checkpoint mode below can
reuse verified groups when all recorded inputs still match.

IDs are numbered before selection. They can change when source, modules, or
macro mode change. Unknown IDs fail, but a changed profile can assign an old
ID to another site. Check the printed sites and the report's `selection` field.
Use `--only` on the full module profile instead of changing `--module` to keep
the profile's IDs and survivor scope stable.

A focused result reports only selected mutants. It cannot establish the full
component gate. Known excluded annotations are counted as deferred. Unknown
annotations and selected stale entries still fail. Occurrence declarations
such as `#2` resolve against the full profile before selection. Raw checkpoints
record the selection, and results with different selections cannot merge.

Fail-fast kills have partial test attribution. Surviving mutants still require
the whole suite to pass. Invalid mutants receive no kill credit. Timeout-only
failures remain visible and do not become kills.

## Full verification

At a stable checkpoint, omit selection, prioritization, and fail-fast:

```sh
mix covenant.check
mix covenant.mutate jido.agent --macros --jobs 4 --seed 0 --timeout 5000 \
  --max-runtime 3600000 --out tmp/covenant/agent-mutations.json
```

Add the project's required `--recompile` sources in dependency order. The Jido
contract suite compiles its DSL fixtures inside tests, so it needs no extra
caller list. Its documented Spark provider exclusion still applies.

Review every survivor and stale annotation. Keep exact and partial attribution
separate. A focused result or a cancelled job is not a full mutation baseline.
The full command above was documented, not run again during this change.

## Progress and cancellation

Workers print the passing baseline before the first mutant. Each verdict
includes elapsed worker time. The existing rate and completion estimate appear
after each 25 mutants in a slice. A three-mutant loop is too short for a useful
estimate. With several workers, elapsed time and estimates are per worker.
Worker elapsed time includes its preparation; it starts again after replacement.

`--max-runtime` bounds the whole job, including worker replacement. Send SIGTERM
to the parent process to cancel it. The parent stops owned worker ports. Workers
remove their private copies and halt when their input closes. Completed verdicts
remain in the printed raw-results directory. Unsealed raw files are partial
evidence and cannot be imported by resume.

## Verified checkpoints and resume

Start a checkpoint run from the consumer project with `MIX_ENV=test`:

```sh
MIX_ENV=test mix covenant.mutate jido.agent --macros \
  --only m0684,m0985,m1034 --checkpoint --selective-recompile \
  --jobs 1 --seed 0 --timeout 5000 --max-runtime 120000 \
  --out tmp/covenant/agent-checkpoint.json
```

Use the directory printed as `raw results:` or saved in the report's
`checkpoint.directory`. Repeat the original semantic options when resuming:

```sh
MIX_ENV=test mix covenant.mutate jido.agent --macros \
  --only m0684,m0985,m1034 --resume tmp/covenant/mutate/jido.agent/run-EXAMPLE \
  --selective-recompile --jobs 1 --seed 0 --timeout 5000 \
  --max-runtime 120000 --out tmp/covenant/agent-resumed.json
```

Replace `run-EXAMPLE` with the actual directory. `--resume` implies
`--checkpoint`. Jobs, worker group size, output path, and total job budget can
change. Source profile, test paths, contracts, seed, test timeout, macro mode,
caller list, fail-fast mode, selective compilation mode, and hint contents
must match. Old raw files and matrices without checkpoint metadata cannot be
used. A changed fingerprint fails before workers start; it does not silently
accept old verdicts.

The fingerprint includes project and dependency files, untracked support and
fixture inputs, file modes, symlink targets, compiled dependency BEAMs,
configuration, runtime and compiler versions/options, and environment values.
The manifest stores a digest, not environment values. Build outputs, Git and
editor data, generated documentation and coverage directories, top-level
project `tmp`, and PLTs are excluded. Ebin and consolidated protocol contents
are hashed separately.
Equal Elixir checker terms have one stable hash even if their BEAM encoding
order changes during protocol consolidation. All executable and other metadata
chunks remain in the fingerprint; malformed BEAMs use their exact bytes.
Symlink targets are included. This mode is for deterministic local contract
tests. For tests that depend on external services or data outside these input
trees, use a fresh run.

The parent seals a group only after its worker exits zero and passes the final
original-code check. Each seal hashes the raw file. The parent checks the input
fingerprint again before sealing; a mismatch prevents reuse. Keep inputs fixed
during a checkpoint run. Partial per-mutant writes and watchdog-stopped
groups have no seal. A cancelled run therefore loses at most its unverified
groups. A smaller `--max-mutants-per-worker` saves groups more often, at the
cost of more VM starts and baselines.

Resume starts fresh workers and runs the current original baseline. It checks
test metadata against the saved groups before merging. Even a fully cached
selection needs this baseline. Corrupt, overlapping, or changed checkpoints
fail. Attribution remains exact or partial as originally measured; timeout
groups receive no reusable credit. The normal survivor and selection checks
still apply. A focused checkpoint remains a focused result.

Checkpoint directories remain after success. Without `--checkpoint`, completed
jobs remove their raw directory as before. The report records the checkpoint
directory, fingerprint, reused groups, and reused mutants.

## Selective caller compilation

`--selective-recompile` requires `--macros` and is off by default. The initial
caller pass records calls to mutation targets during compilation. Runtime
traces include ordinary and private functions called by macros. Compiler
events add macro, struct, and module-body references. Verification callbacks
finish before the measurement ends. A trace barrier collects pending calls.

For each runtime mutation, Covenant follows dependencies through the caller
files, preserves their declared order, and compiles the affected files.
Unrelated test modules retain their baseline binaries. It still runs the
selected suite. Survivors require that whole suite to pass. The original
binaries and compiler tracer configuration are restored.

Macro-provider files keep full caller compilation, including mutations of
ordinary functions in those files. Nested dynamic compilation, unresolved
module queries, and other uncertain file dependencies also keep the full
path. Selective mode does not discover missing `--recompile` sources. Supply
the same direct and transitive caller list required by normal macro mode.
Workers print the number of selected caller files; the report and checkpoint
fingerprint record selective mode.

## Local measurements: 2026-10-15

Environment: Elixir 1.20.4, OTP 29.1. The same nine Jido sites were checked with
76 contract tests, one worker, seed 0, macros enabled, and a 5,000 ms timeout.
The set contained seven killed mutants, one reviewed survivor, and one invalid
mutant. It included the three recent test gaps.

| Probe | Time | Result |
| --- | ---: | --- |
| Direct runner, full attribution | 69.5 s | Exact attribution |
| Direct runner, existing fail-fast | 59.2 s | Partial kill attribution |
| Public focused command, fail-fast | 64.1 s | 9 selected, same verdicts |
| Trial: prioritize a whole killing module | 62.2 s | Small change; replaced by one test |
| Public focused command, one killing test first, with original-code control | 35.9 s | Same 9 verdicts; 44% less time than 64.1 s |
| Three known test gaps, with original-code control | 23.2 s | All 3 killed; full original baseline and final verification passed |

The two public nine-mutant commands are the direct timing comparison. The
direct-runner timings exclude parent task overhead. These are short local
measurements, not an estimate of the speed of the full 1,302-mutant profile.

The complete local probe matrices are saved as ignored artifacts in
`tmp/development-mutation/jido-nine.json` and `jido-three.json` in this fork.
From the sibling Jido checkout, `--prioritize
../covenant/tmp/development-mutation/jido-nine.json` can start a warm loop.
These files are local evidence, not a full mutation baseline.

Separate probes measured compilation of the four contract files at 1.2–1.8 s,
one runtime target at 27–58 ms, and an empty cleanup pass at 56–65 ms.
These first probes kept full recompilation. Ordinary functions can run during
macro expansion, so the selective mode added later measures those calls. It
does not infer safety from `def` versus `defmacro` alone.

Covenant process tests cover selected IDs across slices and worker retirement,
invalid mutants, excluded and stale annotations, occurrence references, wrong
and missing hints, a hint that only times out, order-dependent tests, and restoration of test filters.
The existing suite covers macro callers, cleanup, deadlines, cancellation, and
worker isolation. Jido source files were not edited for these probes.

## Validation

Before the checkpoint and selective compilation changes, the full Covenant
suite passed 504 tests. After the control-test check was
added, the 12 focused tests passed in a separate sequential run. The contract
gate passed 103/103 obligations, including the two new mutation obligations,
and retained the existing 40-file source ceiling. Format, compilation with
warnings as errors, and documentation checks passed. The nine-site comparison
kept all verdicts unchanged: seven killed, one survivor, one invalid, and no
timeout verdicts. The final three-site run detected all three test gaps.

The task changed only Covenant. A hash check of 1,246 Jido source and contract
files found no edits or new source files. No full Jido mutation run was started
after the cancelled run.

The two existing survivor annotations whose lines moved were checked again
with exact attribution. Both remained equivalent survivors. No other survivor
judgment was changed.

For checkpoint resume and selective compilation, all 184 mutation subsystem
tests passed, with passing tests for 32/32 mutation obligations. After the
protocol fingerprint fix, all seven new focused tests passed again. They cover
real SIGTERM cancellation, worker retirement, fresh baselines for fully cached
selections, changed inputs, corrupt and overlapping groups, unchanged exact
verdicts, runtime calls inside macros, structs, transitive callers, generated
modules, and verification callbacks. Equal protocol checker data has a stable
fingerprint; changed checker data or executable chunks invalidate it.

The static gate checks all 105 obligations and the existing 40-file source
ceiling. This is static validation of the full contract, not a new full-suite
run. Jido checks use its 76 contract tests and only the three mutants for the
fixed test gaps. No full 1,302-mutant profile is required for these checks.
