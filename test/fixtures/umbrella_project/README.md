# Umbrella project

The umbrella-shaped fixture of Covenant's own test suite: the Contract and the
config live at the root (`contracts/`, `config/config.exs`) while the code and
its contract tests live in `apps/shop`, where `mix` runs from, so a task run
there is *not* in the directory that holds the contracts. `config/config.exs`
is the machina-ex one: an absolute `contracts_dir` and
`test_paths: ["apps/*/test/contract"]`.

Covenant's e2e tests run `mix covenant.*` in `apps/shop` as subprocesses.
Dependencies are shared with the parent project through `deps_path`; the
lockfile is this project's own. Its `_build/`, `tmp/` and coverage files are
ignored by git.
