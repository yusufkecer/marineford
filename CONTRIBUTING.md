# Contributing

Thanks for looking. This is a pre-release project, so the most useful
contributions right now are bug reports from actually trying it and fixes to
things that surprised you.

## Setting up

A [pub workspace](https://dart.dev/tools/pub/workspaces): one lockfile, one
`.dart_tool`, no melos. Resolve everything from the root.

```bash
flutter pub get
```

```bash
flutter analyze && dart format --set-exit-if-changed .
```

## Running the tests

They are split, and not arbitrarily:

```bash
dart test packages/marineford_core packages/marineford_annotation packages/marineford_gen packages/marineford_cli
```

```bash
flutter test packages/marineford example/json_drift_app
```

`marineford_gen` **cannot** run under `flutter test`. Its tests drive
`build_runner` through `build_test`, which needs the Dart VM's own package
resolution and cannot write assets inside the Flutter test harness. If you see
`Builder failed to write asset`, that is what happened.

## Running the benchmarks

```bash
dart compile exe bench/bin/run.dart -o bench/run && ./bench/run
```

Build it AOT. Under `dart run` the JIT is still warming up the analyzer and the
same measurements come out several times worse — compiling a patch reads 246 ms
against 2 ms. Shipped apps are AOT, so JIT numbers describe nothing anyone
experiences, and `--check` refuses to run under them.

## Working on the example

The example generates code, so it needs a build after any change to a
`@patchable` function:

```bash
cd example/json_drift_app && dart run build_runner build
```

Its test builds and publishes a real signed patch, then points a real client at
it. If you have never run it, it generates a throwaway signing key into
`.marineford/` first. That key is gitignored and disposable — there is
deliberately no committed key anywhere in this repository.

## Things that will surprise you

These cost real time to discover, so they are worth knowing up front. Each one
has a test pinning it down.

**dart_eval boxes parameters inconsistently.** Non-nullable `int`, `double` and
`bool` are passed raw; everything else — including `int?` — must be wrapped.
Adding a `?` to a patch parameter flips the rule. Pinned by
`packages/marineford/test/boxing_test.dart`.

**A test whose patch function ignores its parameter proves nothing.** With an
unused parameter dart_eval never emits the box/unbox opcode, every argument form
appears to work, and the test is measuring nothing. Always use the parameter.

**Nested patch calls must go through `bridgeCall`, not `execute`.** A patched
method calling another patched method re-enters the interpreter;
`Runtime.execute` resets the program counter and corrupts the frame you are
already inside. The dispatcher's depth counter handles this. Pinned by the
re-entrancy test in `dispatch_test.dart`.

**An `@RuntimeOverride` without `version:` never fires.** dart_eval defaults the
constraint to its own package version, which no app satisfies. The patch
compiles, publishes and silently does nothing. `marineford build` warns.

**dart_eval's compiler sometimes crashes rather than reporting an error.** A
`RangeError` from `Variable.boxIfNeeded` is a dart_eval bug, not your code. It
is sensitive to how much a single function does; splitting the function usually
clears it. `marineford build` translates it into that advice.

## Code style

The analyzer is configured strictly on purpose — `strict-casts`,
`strict-inference`, `strict-raw-types`, and `public_member_api_docs` as a
warning. Two lints are errors rather than warnings and should stay that way:

- `empty_catches` — a swallowed error in the patch path is undiagnosable in the
  field
- `unawaited_futures` — the client does real I/O and a dropped future means a
  patch silently never installs

Comments should say *why*, not *what*. Most of the non-obvious code here exists
because of a specific measurement or a specific bug; if you change such a place,
keep the reason attached to it.

## What is most useful right now

- Trying it against a real app and reporting what broke
- Anything in `packages/marineford_core` — the selection rules are where a
  mistake reaches every device, and they are pure functions, so tests are cheap
- An S3-compatible `PublishTarget` (only `DirectoryTarget` exists today)
- Reducing what `dart_eval` pulls into a shipped binary

Before starting anything large, open an issue. Most of the architecture is
argued from measurements rather than taste, so it is worth asking what a change
would do to the numbers in `bench/` before writing it.
