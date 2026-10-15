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
Macro callers and contract tests still compile against each mutant. There is
no cached verdict and no source, dependency, fixture, or tool-version cache to
invalidate. A stale hint can cost time; it cannot prove a kill or a survivor.

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
remain in the printed raw-results directory. These files are partial evidence;
there is no persistent resume or cross-run verdict reuse in this change.

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
Skipping test recompilation was considered but left out: ordinary functions
can run during macro expansion, so a runtime function mutation does not by
itself prove that callers can remain compiled. The current macro checks remain
in place. Test priority gives a useful loop without making that assumption.

Covenant process tests cover selected IDs across slices and worker retirement,
invalid mutants, excluded and stale annotations, occurrence references, wrong
and missing hints, a hint that only times out, order-dependent tests, and restoration of test filters.
The existing suite covers macro callers, cleanup, deadlines, cancellation, and
worker isolation. Jido source files were not edited for these probes.

## Validation

The full Covenant suite passed 504 tests. After the control-test check was
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
