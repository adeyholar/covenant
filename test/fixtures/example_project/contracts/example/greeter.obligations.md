# example.greeter

## Purpose

Greets people by name. The light-form example of the Covenant fixture: a
surface component with no incident history and one deliberate exception.

## Obligations

### example.greeter.I1 — Greetings name the person
- **scope:** `Example.Greeter.greet/1`
- **must:** return `"Hello, <name>!"` for a non-empty name and `"Hello, stranger!"` for `nil` or `""`
- **kind:** functional
- **status:** active

### example.greeter.I2 — The greeter keeps its own clamp
- **scope:** `Example.Greeter.clamp/1`
- **must:** keep a private copy of the counter's clamp-at-zero rule rather than depend on `Example.Counter`
- **why:** surface components depend on nothing; pulling the counter in would couple two components for one line
- **kind:** exception
- **target:** `Example.Greeter.clamp/1`
- **status:** active
