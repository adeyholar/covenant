# Mutants the calc Contract leaves alone

## At a bound, the bound is n

When `n` equals `lo`, the first clause returns `lo`, which is `n`, so `<` and
`<=` agree. The same holds for `hi`.

```equivalent
Calc.clamp/3: < -> <=
Calc.clamp/3: > -> >=
```
