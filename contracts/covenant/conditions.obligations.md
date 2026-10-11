---
modules: [Covenant.Conditions]
---
# covenant.conditions

## Purpose

Re-checks the machine-checkable premises of decision records against the
running system, so an expired premise is noticed before the decision it
supports is relied on.

## Obligations

### covenant.conditions.I1 — The five check kinds evaluate against the context
- **scope:** `Covenant.Conditions.evaluate/2`
- **must:** evaluate `dep` (present in the lock, optionally matching a version requirement; a dep without a version cannot satisfy a requirement), `env` (variable set), `file` (path exists under the root), `otp` and `elixir` (running version matches the requirement); each outcome says what was found. A version is compared as three numbers: `28` and `28.5` are padded with zeros and a fourth number (`27.3.4.1`) is dropped. A requirement may leave out the minor or patch number after a comparison operator (`>= 28.0` is `>= 28.0.0`, `>= 28` too) but `~>` keeps the parts it was written with (`~> 28.0` means below 29)
- **kind:** functional
- **status:** active

### covenant.conditions.I2 — Nothing is silently fine
- **scope:** `Covenant.Conditions.evaluate/2`
- **must:** mark an unknown check kind, an incomplete check (a `value` check whose `call` is not `Module.fun/0` of arity 0, that lacks `equals`, or whose `path` is not a list of atoms or strings, included), a malformed check, an invalid version requirement or a version that cannot be compared as suspect, whatever other fields the check carries (only `kind` selects how a check is evaluated; another kind's fields never rescue it); leave a condition without a `check` unchecked
- **kind:** functional
- **status:** active

### covenant.conditions.I3 — mix.lock is read as name to version
- **scope:** `Covenant.Conditions.read_lock/1`
- **must:** map every locked dependency to its hex version (the third element of the hex entry; a hex entry too short to carry one maps to `nil`), non-hex dependencies to `nil`, and a missing, unparseable or non-map lock to an empty map; read the lock without emitting compiler warnings
- **kind:** functional
- **status:** active

### covenant.conditions.I4 — Suspects are the records with a failing premise
- **scope:** `Covenant.Conditions.suspects/2`
- **must:** return only records with at least one suspect condition, with only their suspect conditions and reasons, and nothing for a Contract whose premises hold
- **kind:** functional
- **status:** active

### covenant.conditions.I5 — The context reflects the running system
- **scope:** `Covenant.Conditions.context/1`
- **must:** read the project's lock from the root, the environment, the running Elixir and OTP versions; the OTP version is the full version from the release's `OTP_VERSION` file (the major release only when that file is absent)
- **kind:** functional
- **status:** active

### covenant.conditions.I6 — A value check compares what the running code returns with what the record says
- **scope:** `Covenant.Conditions.evaluate/2`
- **must:** evaluate `value` by calling `call` (`Module.fun/0`, arity 0 only) in the running VM and comparing the result, at `path` when given, with `equals`. `path` is a list of keys walked through maps, the atom form of a key tried before its string form. Atoms compare as their string, a list compares element by element, numbers compare by value, a boolean and nil only equal themselves. An equal value holds and the outcome says what was found (`Mod.fun/0 [key] is 20`); a different value (`Mod.fun/0 [key] is 21, the record says 20`), a key that is not there (also under a value that is not a map), or a call that raises, throws or exits is suspect and says which. A module that is not loadable (`Code.ensure_loaded?/1`) leaves the condition unchecked with the reason `module not compiled in this VM: <Module>`, never a failure
- **why:** a limit that a record decides but nothing verifies drifts: a kill matrix showed a mutated `claim_batch: 20` → `21` survive in a project's `limits/0` because no test read the value against its record; the record that decides a value should verify it
- **kind:** functional
- **status:** active

### covenant.conditions.I7 — Contract data does not call into Elixir or OTP
- **scope:** `Covenant.Conditions.evaluate/2`, `Covenant.Contract.Ceiling.count/2`
- **must:** refuse a `value` call whose module is part of Elixir or OTP (its beam, `:code.which/1`, lies under the OTP root or Elixir's install) as suspect, and a `module` counter of a scope ceiling whose module is part of Elixir or OTP as an error, each naming the call and saying the module is part of Elixir or OTP; the function is not called. `System.halt/0` ends the VM with a status the caller reads as success and `rescue` cannot stop it. This is a mitigation, not a sandbox: a project function can still halt, because `contracts/` runs project code and is trusted input, like `mix.exs`
- **kind:** functional
- **status:** active

### covenant.conditions.I8 — A file check stays under the project root
- **scope:** `Covenant.Conditions.evaluate/2`
- **must:** mark a `file` check suspect, saying the path is outside the project root, when the path expanded against the root (`..`, an absolute path and `~` included) is neither the root nor under it, whether or not the file exists there; a symlink inside the root that points outside it is not resolved and is followed
- **kind:** functional
- **status:** active

### covenant.conditions.I9 — Names from a record never become atoms
- **scope:** `Covenant.Conditions.evaluate/2`, `Covenant.Contract.Ceiling.count/2`
- **must:** keep the module and function of a `value` call, and of a scope ceiling's `module` counter, as strings: the module (a leading `Elixir.` is dropped) is looked up as an atom only when that atom already exists, and a module with no atom is unchecked as a module that is not compiled in this VM; the function is found by comparing its name with the loaded module's exports, and one that is not exported is suspect as a call that raises `UndefinedFunctionError` (an error for a counter, which is never called when its module is not loaded, so `--static` still skips it). A Contract cannot grow the atom table, and a name written ahead of its implementation is never a crash
- **kind:** functional
- **status:** active
