---
modules: [Vm.Echo]
---
# vm.echo

## Purpose

A process that runs this module's own code, under a supervisor.

## Obligations

### vm.echo.I1 — Doubles
- **scope:** `Vm.Echo.double/1`
- **must:** double the input
- **kind:** functional
- **status:** active

### vm.echo.I2 — Adds
- **scope:** `Vm.Echo.add/1`
- **must:** return an integer running sum
- **kind:** functional
- **status:** active
