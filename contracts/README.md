# The Covenant Contract

Covenant is governed by its own Contract, in the convention it enforces
([`docs/contract-convention.md`](../docs/contract-convention.md)).

- `system/intent.md` — what Covenant is for, its scope and environment facts.
- `system/decisions.yml` — the policy decisions behind the tool, with the
  alternatives that lost and the premises `mix covenant.conditions` re-checks.
- `system/scope.yml` — the scope budget.
- `covenant/<component>.obligations.md` — light-form obligations, one file per
  component: `contract`, `case`, `check`, `static`, `conditions`, `regen`,
  `results`, `tasks` and `mutate`.
- `covenant/<component>.survivors.yml` — the sorted survivors of
  `mix covenant.mutate` for `conditions` and `mutate`.
- `test/contract/covenant/**/*_contract_test.exs` — the executable obligations.

`mix covenant.check` in the project root checks Covenant against itself and
writes `coverage.json` here.
