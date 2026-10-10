---
modules: [Shop.Cart]
---
# shop.cart — intent

## Purpose

A cart adds up prices.

| Rev | Date | Change | Driver |
|---|---|---|---|
| 1 | 2026-10-10 | First | the umbrella fixture |

## Scope

Owns the cart total. Does not own prices (`shop.catalog`).

## Environment facts

- None.

## Public surface

- `Shop.Cart.total(prices) :: integer` — the sum of the prices; each one comes from `Shop.Catalog.price/1`, and an empty cart never calls `System.halt(1)`.

## Invariants

### shop.cart.I1 — The total is the sum
- **scope:** `Shop.Cart.total/1`
- **must:** return the sum of the prices, `0` for none
- **why:** the fixture needs one obligation that a mutant can break
- **kind:** functional
- **status:** active

## Decisions

| Decision | Value | Reason | Record |
|---|---|---|---|
| Empty cart | 0 | a sum of nothing | none |

## Orderings

- None.

## Known limits

- None.

## Regeneration brief

Rebuild from this intent and the tests.
