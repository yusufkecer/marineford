## 0.1.0

First release. The `build_runner` generator that turns a marker into a dispatch
branch.

- Dispatch shims for `@patchable` and `@PatchableService`. Each one caches its
  slot against a generation counter, so a marked call stays a static field read
  whether or not a patch is live.
- The boxing rule applied for you — raw for a non-nullable `int`, `double` or
  `bool`, `MarinefordJson.wrap` for everything else. Getting it backwards throws
  inside the interpreter, which is not a mistake anyone should have to remember
  not to make.
- `Future<T>` and Flutter `Widget` returns, including `List<Widget>`.
- A build error naming the problem for anything the boundary cannot carry,
  rather than a shim that compiles and then silently falls back forever.
- The ABI fingerprint and the `marineford_ids.json` registry the CLI checks
  patches against.

Depends on no other marineford package. The annotations are matched by library
URL rather than by type, because they live in `marineford`, which is a Flutter
package a `build_runner` generator cannot depend on — the example app's
`marking_test.dart` guards that URL against drift.
