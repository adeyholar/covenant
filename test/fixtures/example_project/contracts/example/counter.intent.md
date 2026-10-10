# example.counter

## Purpose

A bounded, non-negative counter whose every change is recorded as an event.
It is the heavy-form example of the Covenant fixture: small, but with the
incident history that makes the heavy form worth its weight.

| Rev | Date | Change | Driver |
|---|---|---|---|
| 1 | 2026-10-09 | First intent: four active obligations, one retired | Covenant fixture |
| 2 | 2026-10-09 | I6 and I7 added: `mix covenant.mutate` showed that landing exactly on a bound and the default cap were promised in prose only | kill matrix survivors m023, m032, m001 |

## Scope

Owns: the value, the cap, the event log of one counter. Does not own:
persistence, concurrency (a counter is an immutable value passed around),
formatting for display.

## Environment facts

- Elixir 1.18 or later; checked by the `clamp-at-zero` record condition.
- `yaml_elixir ~> 2.12` is in `mix.lock` (the contract tooling reads records);
  checked by the `positive-steps` record condition.

## Public surface

- `Example.Counter.new(opts) :: t` — a counter at zero; `opts[:max]` sets the cap (default 100, record `configurable-max`, pinned by `example.counter.I7`).
- `Example.Counter.increment(counter, by) :: t` — adds `by`, clamped at `max`.
- `Example.Counter.decrement(counter, by) :: t` — subtracts `by`, clamped at zero.
- `Example.Counter.value/1` — the current value.
- `Example.Counter.events/1` — every event, oldest first.
- `Example.Counter.to_map(counter) :: map` — the persisted form.

Persisted format of `to_map/1`, pinned by `example.counter.I3`:

```elixir
%{"value" => non_neg_integer, "max" => pos_integer}
```

Event tuples, pinned by `example.counter.I4`:

```elixir
{:incremented, by} | {:decremented, by} | {:clamped, :max | :zero}
```

## Invariants

### example.counter.I1 — A counter never goes below zero
- **scope:** `Example.Counter.decrement/2`, every starting value
- **must:** stop at zero when `by` exceeds the value, instead of going negative or raising
- **why:** v1 raised on underflow and every caller rescued it, hiding real bugs (fixture incident #1)
- **kind:** functional
- **record:** clamp-at-zero
- **status:** active

### example.counter.I2 — Steps are positive integers
- **scope:** `Example.Counter.increment/2` and `Example.Counter.decrement/2`
- **must:** raise `ArgumentError` for a `by` that is zero, negative or not an integer, and leave no event
- **why:** a zero step recorded a no-op event in v1 and doubled the event log (fixture incident #2)
- **kind:** functional
- **record:** positive-steps
- **status:** active

### example.counter.I3 — The persisted form has exactly two keys
- **scope:** `Example.Counter.to_map/1`
- **must:** return a map with exactly the string keys `"value"` and `"max"`
- **why:** the map is stored by callers; a renamed key silently loses saved counters
- **kind:** persisted-format
- **status:** active

### example.counter.I4 — Events are recorded in call order
- **scope:** `Example.Counter.events/1`
- **must:** list events oldest first, one per successful call; a clamped call records `{:clamped, :max}` or `{:clamped, :zero}` instead of the step event
- **why:** readers replay the log; an out-of-order or duplicated event replays to the wrong value
- **kind:** ordering
- **status:** active

### example.counter.I5 — The cap is 100
- **scope:** `Example.Counter.increment/2`
- **must:** never exceed 100
- **why:** v1 counters were display widgets with a fixed width
- **kind:** functional
- **record:** fixed-max-100
- **status:** retired

### example.counter.I6 — Landing exactly on a bound is a step, not a clamp
- **scope:** `Example.Counter.increment/2` and `Example.Counter.decrement/2`, a step that ends exactly at `max` or at zero
- **must:** record `{:incremented, by}` or `{:decremented, by}`, never `{:clamped, _}`, when the result equals the bound
- **why:** the kill matrix showed `>` → `>=` and `<` → `<=` surviving: every test either missed the bound or asserted only the value (rev 2)
- **kind:** functional
- **status:** active

### example.counter.I7 — The default cap is 100
- **scope:** `Example.Counter.new/0` and `Example.Counter.new/1` without `max:`
- **must:** build a counter whose `max` is 100
- **why:** the regeneration brief promised the default and no test held it; the kill matrix showed `100` → `101` surviving (rev 2)
- **kind:** functional
- **record:** configurable-max
- **status:** active

## Decisions

| Decision | Value | Reason | Record |
|---|---|---|---|
| Underflow | clamp at zero | callers rescued the v1 exception | clamp-at-zero |
| Step validation | positive integers only | zero steps doubled the log | positive-steps |
| Cap | configurable, default 100 | widgets vary in width | configurable-max |

Worked example the decisions must reproduce exactly: `new(max: 3)`,
`increment(2)`, `increment(2)`, `decrement(5)` yields value `0` and events
`[{:incremented, 2}, {:clamped, :max}, {:clamped, :zero}]`.

## Orderings

- Validation of `by` happens before any state change: an invalid step leaves
  value and events untouched.
- The event is appended after the value is updated, in the same call; there
  is no event without its value change.

## Known limits

- The event log grows without bound; trimming is a caller concern.
- Counters are not safe to share between processes without a wrapper.

## Regeneration brief

A regenerator receives this intent, `counter.decisions.yml`, the contract
tests under `test/contract/example/` and the public-surface stubs. Questions
answered in earlier rounds:

- *Does `increment/2` with `by` larger than the remaining headroom clamp or
  raise?* Clamp (`{:clamped, :max}`); only invalid steps raise.
- *Is the default cap part of the public surface?* Yes: `new/0` gives `max: 100`.
