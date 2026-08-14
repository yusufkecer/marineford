## 0.1.0

First release. The `marineford` command: build a patch, sign it, publish it, and
take it back.

- `marineford init` — signing key pair, `marineford.yaml`, and the `.gitignore`
  entry that keeps the private key out of the repository on day one.
- `marineford abi` — prints this build's fingerprint.
- `marineford build` — compiles the patch package, lints it against the measured
  cost model, compresses and signs. Refuses a patch that imports a platform
  library or writes `catch` around an `await`, because both produce code that
  looks like it works and does not.
- `marineford publish` / `rollout` / `revoke` — publishing and manifest
  maintenance against a directory, which is all a static host needs.
- `marineford revoke --dry-run <app version>` — runs the real selection against
  a hypothetical manifest and prints where devices would land. Revocation is the
  one command with no undo, so it is also the one that can be rehearsed.
- `marineford doctor` — checks a project is ready to publish.

Compiles patches that import Flutter without depending on Flutter itself: the
bridge declarations are pure data and ship bundled, so the CLI stays pure Dart
and `dart pub global activate` keeps working.
