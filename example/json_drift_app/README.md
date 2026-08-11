# json_drift_app

The scenario marineford was built for: the backend changed shape, the app in the
store parses the old shape, and the fix has to reach users today.

The app is version **1.4.0** and contains exactly one marked function — a
no-op normaliser sitting on the output of its HTTP client:

```dart
@patchable
Map<String, dynamic>? _normalizeResponse(String endpoint, Map<String, dynamic>? raw) => raw;
```

The function with the actual bug, `parseCollectDay`, is **not** marked and never
could be. That is the point of the example: you do not have to have predicted
which function would break, only to have put one marker somewhere above it.

## What the patch repairs

Every row below is a real change a backend can make without telling anyone.
[`test/drift_test.dart`](test/drift_test.dart) runs all of them through the same
unmodified build, first with no patch and then after fetching a real signed one.

| What the backend did | Shipped build | After the patch |
|---|---|---|
| nothing | Salı | Salı |
| `status: "ok"` became `"success"` | Belirlenmemiş | **Çarşamba** |
| `status` became the number `200` | Belirlenmemiş | **Perşembe** |
| `day` was renamed `collect_day` | Belirlenmemiş | **Cuma** |
| everything moved under `data` | Belirlenmemiş | **Cumartesi** |
| one day became a list of days | Belirlenmemiş | **Pazartesi, Perşembe** |
| the value became an integer | Belirlenmemiş | **3** |
| an error response | Belirlenmemiş | Belirlenmemiş |

## Running it

```bash
flutter test example/json_drift_app
```

The test does the whole pipeline for real. It compiles
[`patch/lib/normalize.dart`](patch/lib/normalize.dart) with dart_eval, gzips and
signs it into a `.mfp`, writes a signed manifest, and then points a genuine
`MarinefordClient` at the result. Only the network is faked.

To drive it by hand instead:

```bash
dart run marineford_cli:marineford build
```

```bash
dart run marineford_cli:marineford publish --to dist --app-versions '>=1.4.0 <1.5.0'
```

## The signing key

There isn't one in the repository, and there should never be one in yours
either. A private key in a public repo is a private key anyone can use to run
code inside every app that trusts it.

The test generates a throwaway key into `.marineford/` on first run. In a real
project `marineford init` creates it and adds it to `.gitignore`; in CI it comes
from `MARINEFORD_SIGNING_KEY`.

## Notes on the patch source

[`patch/lib/normalize.dart`](patch/lib/normalize.dart) is compiled by dart_eval,
not by the Dart SDK, which is why it looks slightly unusual:

- It declares `RuntimeOverride` itself rather than importing it. dart_eval
  matches the annotation by name and never resolves the import.
- It uses bare `Map` and `List`, because that is what crosses the boundary.
- It is excluded from `analysis_options.yaml`. Analysing it as ordinary Dart
  would report problems with code that is correct for its actual target.

The `version:` constraint is not optional in practice. Leave it off and
dart_eval defaults it to *its own* version, which no app satisfies — so the
override compiles, publishes, and silently never fires. `marineford build`
warns about this.
