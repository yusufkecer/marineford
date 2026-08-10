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
| crossing into the interpreter | how coarse a patch boundary has to be |
| interpreted loop iteration | why the linter warns about loops in patches |
| activation | whether a patch can be applied on the startup path |
| packed payload | whether shipping whole programs beats binary diffing |
