# Sibling project

The sibling-layout fixture of Covenant's own test suite: the Contract lives in
`contract/<primitive>/`, the layout flinch, qualm and exhale read, with each
primitive's Contract tests beside its README. `mix.exs` adds `contract` to
`test_paths`, and `contract/test_helper.exs` exists because Mix requires a helper
in every test path.

Covenant's e2e tests run `mix covenant.*` here as subprocesses. Dependencies are
shared with the parent project through `deps_path`; the lockfile is this
project's own. Its `_build/`, `tmp/` and coverage files are ignored by git.
