# bench

Reproduces the cost model marineford's design rests on.

```bash
dart compile exe bench/bin/run.dart -o bench/run && ./bench/run
```

```bash
./bench/run --check
```

**Build it AOT.** Under `dart run` the JIT is still warming up the analyzer and
the same measurements come out several times worse — compiling a patch reads
246ms against 2ms. Shipped apps are AOT, so JIT numbers describe nothing anyone
experiences, and `--check` refuses to run under them.

`--check` exits non-zero when a measurement drifts past its budget. The budgets
are deliberately loose — they catch an order-of-magnitude regression, not a slow
runner.

Each number justifies a decision that would be wrong if it moved:

| Measurement | What it decides |
|---|---|
| marked call, no patch | whether marking liberally is affordable |
| marked call, another patch live | whether shims must cache their slot |
| crossing into the interpreter | how coarse a patch boundary has to be |
| interpreted loop iteration | why the linter warns about loops in patches |
| activation | whether a patch can be applied on the startup path |
| wrap / unwrap | how large a JSON payload can cross the boundary |
| packed payload | whether shipping whole programs beats binary diffing |

Two of these exist because the measurement contradicted the assumption.

**Marked call, another patch live.** The "marked calls are ~4ns" claim was only
ever measured with *no* patch anywhere in the app, where the shim short-circuits
on a null table. Once anything is patched, an unpatched marked function was
paying a full string hash and map probe — 8.9ns — and a code-push system spends
most of its life with something patched. Generated shims now cache the lookup
against a generation counter, which brings it back to 4.5ns and makes it
independent of how long the id is and how many functions are marked.

**Wrap / unwrap.** Eagerly deep-wrapping a JSON argument is fine next to the
2.5µs it costs to enter the interpreter at all — 389ns for a 5-key map — which
is the argument against building a lazy view. It stops being fine somewhere
around a few hundred fields: 50 rows of 8 fields costs 34µs, well past the
crossing it is paying for. If you are handing a patch a large payload, hand it
the part it needs. The same measurement is why `unwrap` no longer routes through
`$reified`, which built the whole structure and then rebuilt it: 69µs → 39µs.
