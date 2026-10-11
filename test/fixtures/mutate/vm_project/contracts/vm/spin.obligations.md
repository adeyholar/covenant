---
modules: [Vm.Spin]
---
# vm.spin

## Purpose

A module whose suite loops in `setup_all` when a mutant breaks it.

## Obligations

### vm.spin.I1 — Steps
- **scope:** `Vm.Spin.step/1`
- **must:** step up to ten, then be done
- **kind:** functional
- **status:** active
