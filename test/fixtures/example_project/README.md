# Example project

The fixture of Covenant's own test suite: a real Mix project with a Contract
under `contracts/`, an implementation under `lib/` and contract tests under
`test/contract/`. Covenant's e2e tests run `mix covenant.check`,
`mix covenant.conditions` and `mix covenant.regen` here as subprocesses.

Dependencies are shared with the parent project through `deps_path`
(`../../../deps`), so `mix deps.get` in the parent is enough; this project
keeps its own `mix.lock`. Its `_build/` and `tmp/` are ignored by git.
