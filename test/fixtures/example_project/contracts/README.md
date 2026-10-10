# The Example Contract

The fixture Contract of Covenant's own test suite. It follows the Machina
contract convention (`contracts/README.md` in the machina-ex repo): heavy-form
intents (`<component>.intent.md`), light-form obligations files
(`<component>.obligations.md`), decision records (`<component>.decisions.yml`),
a system intent, system records and `system/scope.yml` ceilings.

Obligation ids are `<app>.<component>.I<n>`; every active obligation has a
tagged test under `test/contract/`.
