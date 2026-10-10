# The Covenant Contract

Covenant is governed by its own Contract, in the convention it enforces
(the Machina contract convention: `contracts/README.md` in machina-ex).

- `system/intent.md` — what Covenant is for, its scope and environment facts.
- `system/decisions.yml` — the policy decisions behind the tool, with the
  alternatives that lost and the premises `mix covenant.conditions` re-checks.
- `system/scope.yml` — the scope budget.
- `covenant/<component>.obligations.md` — light-form obligations, one file per
  component: `contract`, `case`, `check`, `conditions`, `regen`, `results`, `tasks`.
- `test/contract/covenant/*_contract_test.exs` — the executable obligations.

`mix covenant.check` in this directory checks Covenant against itself and
writes `coverage.json` here.
