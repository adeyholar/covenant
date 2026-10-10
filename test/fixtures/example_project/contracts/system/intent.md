# Example — system intent

## Purpose

The example app exists to exercise Covenant end to end: one heavy-form
component with incident-style records (`example.counter`) and one light-form
surface component with a deliberate exception (`example.greeter`).

## Scope

Owns: the counter and the greeter. Does not own: persistence of counters, any
I/O.

## Environment facts

- Elixir 1.18 or later (`JSON` is in the standard library); checked by the
  `clamp-at-zero` record condition.
- The project is a single Mix app, not an umbrella.
