---
modules: [Shop.Catalog]
---
# shop.catalog

## Purpose

Prices the items of the shop.

## Obligations

### shop.catalog.I1 — Items have a price
- **scope:** `Shop.Catalog.price/1`
- **must:** return the price of a known item and `nil` for an unknown one
- **kind:** functional
- **status:** active
