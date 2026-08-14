## 0.1.0

First release. The runtime half: what a marked app carries, and what it does
with a patch once it has one.

- `@patchable` and `@PatchableService`. They live here rather than in a package
  of their own because anything marking a function already depends on this one —
  the generated shim calls `Patch` and `MarinefordJson`. The patch-side
  `@RuntimeOverride` is deliberately *not* exported: a patch is compiled by
  dart_eval from source the CLI collects, so importing it could never work.
- Dispatch: arity-specialised `invoke0..3`, a guarded hot path that costs a
  static field read when no patch is live, `bridgeCall` routing for re-entrancy,
  failure isolation, and automatic deactivation once a patch keeps throwing.
- Async patches. A `Future`-returning function is patchable, and a failure after
  the await falls back to the original like a synchronous one.
- Flutter widgets. A function returning a `Widget` is patchable, so a screen
  that renders the wrong thing is repairable. Needs `flutter_eval` registered as
  a plugin; nothing here depends on it, so an app patching only logic never
  links it.
- `MarinefordJson`: the boundary conversion. Payloads cross as lazy
  copy-on-write views rather than deep copies, so handing a fifty-row response
  to a patch costs about 0.06µs instead of 35µs, and a patch still cannot reach
  back into the caller's data.
- `PatchStore`: atomic writes, serialised state updates, retention, and recovery
  from a state file that cannot be read.
- `MarinefordClient`: manifest check, signature → hash → ABI verification,
  download, activation, crash-loop guard, rollback. `manifestUrl` must be https,
  and a patch URL must sit on the manifest's own origin.
- A sandbox that closes the `dart:io` entry points dart_eval leaves ungated, so
  a patch cannot reach the filesystem, the network, a process or DNS.
- `PatchObserver` event stream, because static hosting reports nothing back.
