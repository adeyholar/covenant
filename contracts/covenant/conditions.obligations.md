# covenant.conditions

## Purpose

Re-checks the machine-checkable premises of decision records against the
running system, so an expired premise is noticed before the decision it
supports is relied on.

## Obligations

### covenant.conditions.I1 — The five check kinds evaluate against the context
- **scope:** `Covenant.Conditions.evaluate/2`
- **must:** evaluate `dep` (present in the lock, optionally matching a version requirement; a dep without a version cannot satisfy a requirement), `env` (variable set), `file` (path exists under the root), `otp` and `elixir` (running version matches the requirement, short OTP versions normalised); each outcome says what was found
- **kind:** functional
- **status:** active

### covenant.conditions.I2 — Nothing is silently fine
- **scope:** `Covenant.Conditions.evaluate/2`
- **must:** mark an unknown check kind, an incomplete check, a malformed check or an invalid version requirement as suspect, whatever other fields the check carries (only `kind` selects how a check is evaluated; another kind's fields never rescue it); leave a condition without a `check` unchecked
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
