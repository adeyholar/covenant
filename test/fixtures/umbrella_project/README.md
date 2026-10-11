# Umbrella project

The umbrella-shaped fixture of Covenant's own test suite: the Contract and the
config live at the root (`contracts/`, `config/config.exs`) while the code and
its contract tests live in the two apps `apps/shop` and `apps/other`, where `mix` runs from, so a task run
there is *not* in the directory that holds the contracts. `config/config.exs`
is the usual umbrella one: an absolute `contracts_dir` and
`test_paths: ["apps/*/test/contract"]`.

Covenant's e2e tests run `mix covenant.*` in `apps/shop` as subprocesses.
Dependencies are shared with the parent project through `deps_path`; the
lockfile is this project's own. Its `_build/`, `tmp/` and coverage files are
ignored by git.

The root `mix.exs` makes it a real umbrella: `mix covenant.check` run from an app runs
`mix test` from the root, so each app's contract tests run in that app's own VM
(`Other.Thing` exists only in `apps/other`).
