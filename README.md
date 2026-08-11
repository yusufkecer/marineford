# marineford

Code push for Flutter, without forking the engine.

Mark the functions you want to be able to fix later. Ship a signed patch to any
static host. Repair broken logic on apps that are already installed, without a
store release.

```dart
@patchable
Map<String, dynamic>? _normalizeResponse(String endpoint, Map<String, dynamic>? raw) => raw;
```

That one line, shipped in v1.4.0, is enough to absorb almost any change your
backend makes afterwards.

> **Status: pre-release.** Not on pub.dev yet. The pipeline works end to end and
> is covered by 336 tests; the API may still move before 0.1.0.

---

## Read this before anything else

**Code that was not marked before it shipped can never be patched.**

marineford does not fork the Dart compiler, so it cannot add a branch to machine
code that is already compiled. `@patchable` inserts that branch at build time
and nowhere else. If you ship v1.4.0 without marking a function, fixing that
function means a store release — and only builds from that release onward will
be patchable.

This is the whole trade for not forking the engine. Three things make it
workable, and understanding them is most of understanding the library:

1. **Mark above the bug, not on it.** A patch replaces the marked function's
   entire body, so it can also repair bugs in the unmarked helpers that function
   calls — it simply stops calling them. You never have to predict which leaf
   will break, only which entry point sits above it.

2. **Marking is close to free.** A marked call measures **~4 ns** against
   **~2 ns** unmarked, and stays there whether or not a patch is live — every
   shim caches its dispatch slot against a generation counter rather than
   looking it up by name. Mark whole categories, not individual suspects.

3. **One chokepoint covers an enormous amount.** A single marked normaliser on
   your HTTP client's output can absorb renamed fields, changed status values,
   new envelopes, and changed types — all without any of the code downstream
   being marked at all.

If pre-marking is unacceptable to you, [Shorebird](https://shorebird.dev)
patches everything with no annotations. It forks the Flutter engine and the Dart
compiler to do it. See [Compared with Shorebird](#compared-with-shorebird).

---

## How it fits together

```
  YOUR APP                    YOUR CI                    ANY STATIC HOST
  ────────                    ───────                    ───────────────
  @patchable                  marineford build           manifest.json
       │                            │                    (self-signed)
  build_runner                 dart_eval                 7.mfp
       │                       + gzip                          │
       ▼                       + Ed25519                       │
  api_client.marineford.dart        │                          │
  marineford.g.dart  ───ABI───► marineford publish ────────────┘
  (kMarinefordAbi)                                             │
                                                               ▼
                                                          THE DEVICE
                                                          ──────────
                                                    manifest (ETag → 304)
                                                          │
                                                    ABI match? version?
                                                    revoked? in rollout?
                                                          │
                                                    signature → hash →
                                                    decompress
                                                          │
                                                    swap the dispatch table
                                                    marked functions divert
```

Everything the device checks is checked again at publish time by the same
`marineford_core` code. A patch that could never have loaded fails in front of
the person who can fix it.

---

## Quick start

### 1. Install the CLI

```bash
dart pub global activate marineford_cli
```

It installs as `marineford`, and as `mf` for short.

Until the packages are on pub.dev, activate from a checkout instead, and use
`path:` dependencies in step 2:

```bash
dart pub global activate --source path packages/marineford_cli
```

### 2. Add the dependencies

```yaml
dependencies:
  marineford: ^0.1.0
  marineford_annotation: ^0.1.0

dev_dependencies:
  build_runner: ^2.15.0
  marineford_gen: ^0.1.0
```

No `build.yaml` is needed — the generator applies itself to anything that
depends on it.

### 3. Create the project

```bash
marineford init com.example.app
```

This writes `marineford.yaml`, generates an Ed25519 key pair into
`.marineford/`, adds the private key to `.gitignore`, and prints the public key
for you to paste into your app.

**The private key is the whole security model.** Anyone holding it can run code
inside every app that trusts it. Keep it out of version control, back it up
somewhere you trust, and put it in a CI secret rather than a file. Losing it
means you can never publish again for builds already in the field.

### 4. Mark something

```dart
// lib/api_client.dart
import 'package:marineford/marineford.dart';
import 'package:marineford_annotation/marineford_annotation.dart';

part 'api_client.marineford.dart';

class ApiClient {
  Future<Map<String, dynamic>?> get(String endpoint) async {
    final raw = await _http(endpoint);
    return normalizeResponse(endpoint, raw); // ← the generated wrapper
  }
}

@patchable
Map<String, dynamic>? _normalizeResponse(
  String endpoint,
  Map<String, dynamic>? raw,
) =>
    raw;
```

The annotated function is private. The generator owns the public name, so your
call sites use `normalizeResponse` and never know a patch might be involved.

### 5. Generate

```bash
dart run build_runner build
```

You get three things:

| File | What it is |
|---|---|
| `lib/api_client.marineford.dart` | The dispatch shim. A `part` of your file. |
| `lib/marineford.g.dart` | `kMarinefordAbi` and `kMarinefordPatchIds`. |
| `marineford_ids.json` | The id registry the CLI checks patches against. |

All three are generated; add them to `.gitignore`.

### 6. Start the client

```dart
import 'package:marineford/marineford.dart';
import 'package:pub_semver/pub_semver.dart';
import 'marineford.g.dart';

const kMarinefordPublicKey = '...'; // printed by `marineford init`

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Marineford.init(MarinefordConfig(
    appId: 'com.example.app',
    appVersion: Version.parse('1.4.0'),
    abi: kMarinefordAbi,
    manifestUrl: Uri.parse('https://cdn.example.com/prod/manifest.json'),
    publicKey: kMarinefordPublicKey,
  ));

  runApp(const MyApp());

  // Check in the background; never block a frame on the network.
  unawaited(Marineford.checkForUpdate());
}
```

`init` reads two small files and, when a patch is already installed, builds a
dart_eval runtime — about a millisecond, which is why awaiting it before
`runApp` is fine. With no patch installed it does neither.

### 7. Write a patch, when you need one

Create `patch/lib/` beside your app. It is not a pub package; it is source that
dart_eval compiles.

```dart
// patch/lib/normalize.dart
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

@RuntimeOverride(
  'pkg:app/lib/api_client.dart#normalizeResponse',
  version: '>=1.4.0 <1.5.0',
)
Map normalize(String endpoint, Map raw) {
  final out = <String, Object?>{};
  final status = raw['status'];
  out['status'] = (status == 'ok' || status == 'success') ? 'ok' : 'error';

  final data = raw['data'];
  final node = data is Map ? data : raw;
  final day = node['collect_day'] ?? node['day'];
  if (day != null) out['day'] = day.toString();

  return out;
}
```

The id must match one in `marineford_ids.json`. `marineford build` verifies it.

### 8. Ship it

```bash
marineford build
```

```bash
marineford publish --to dist --app-versions '>=1.4.0 <1.5.0' --percent 10
```

That writes `dist/prod/` — `manifest.json` (which carries its own signature) and `1.mfp`.
Upload that directory anywhere static: S3, R2, Cloudflare Pages, a folder behind
nginx. There is no server to run.

Watch it, then open the tap:

```bash
marineford rollout 1 --percent 100
```

And if it goes wrong:

```bash
marineford revoke 1
```

Devices roll back on their next check.

---

## Where to put the marker

### The chokepoint — start here

One marked normaliser on your HTTP client's output. This is the highest-leverage
marker in most apps, because backend contract drift is the most common thing you
need to fix in a hurry, and every instance of it passes through this one
function.

```dart
@patchable
Map<String, dynamic>? _normalizeResponse(String endpoint, Map<String, dynamic>? raw) => raw;
```

The [example app](example/json_drift_app) is built entirely around this: one
marked function repairs eight different backend changes, while the function that
actually contains the bug is never marked and never could be.

### `@patchable` — a single function

The annotated function must be private; the generator emits the public one.

```dart
part 'discount.marineford.dart';

@patchable
int _applyDiscount(int total, int units) => total;
// generated: int applyDiscount(int total, int units) { ... }
```

Pass `@Patchable(id: 'stable.id')` if you need the dispatch id to survive a
rename. By default the id is derived from the library path and the function
name.

### `@PatchableService` — a whole class

Annotate a base class; use the generated subclass at your call sites.

```dart
part 'pricing.marineford.dart';

@PatchableService()
class PricingRulesBase {
  int cartTotal(List<Map<String, dynamic>> items) => 0;
  String label(Map<String, dynamic> cart) => '';
}
// generated: class PricingRules extends PricingRulesBase { ... }
```

Every public instance method becomes patchable. Exclude the ones that shouldn't
be:

```dart
@PatchableService(exclude: ['pricePerFrame'])
```

Like every shim, the generated class caches its slot lookups behind a generation
counter, so the per-call cost is an integer compare rather than a map lookup.

### Where **not** to mark

Crossing into the interpreter costs about **2.6 µs**. That is nothing for a
screen's worth of logic and ruinous per list item or per frame. `marineford
build` warns when a patch looks like it will be expensive, but the marking
decision is yours.

The arguments cost something too. A JSON payload is deep-copied into interpreter
values on the way in and back out on the way out — around 390 ns for a five-key
map, which disappears next to the crossing, but 34 µs for fifty rows of eight
fields, which does not. Pass a patch the part of a response it needs rather than
the whole response.

---

## What can cross the boundary

The generator refuses at build time rather than emitting a shim that compiles
and then silently falls back.

| Type | Supported |
|---|---|
| `int`, `double`, `bool`, `num` | yes |
| `String` | yes |
| `List`, `Map`, `Set`, `Iterable` | yes |
| `Object`, `dynamic` | yes |
| nullable versions of all the above | yes |
| `void` return | yes |
| your own classes | **no** — build error |
| `Future`, `Stream` | **no** — build error |
| function types / callbacks | **no** — build error |
| named or optional parameters | **no** — build error |

If a parameter is your own domain object, move the boundary rather than the
type: mark a function further up the call chain whose parameters are already
JSON-shaped. That is usually the better boundary anyway.

Async is not a real limitation in practice. Keep the `await` in your compiled
code and mark the synchronous function it feeds — that is where the bug lives.

---

## Writing patches

Patch code runs on [dart_eval](https://pub.dev/packages/dart_eval), which
implements most of Dart but not all of it. `marineford build` catches every one
of these at build time.

**Not supported:** mixins, extension methods, generators (`sync*`/`async*`),
typedefs, `late`, deferred imports, isolates.

**Three things that will bite you:**

- **Always pass `version:`.** Without it dart_eval defaults the constraint to
  *its own* version, which no app satisfies — so the override compiles,
  publishes, and silently never fires. The linter warns.

- **Declare `RuntimeOverride` in the patch file.** dart_eval matches the
  annotation by name and never resolves the import, so the patch package
  declares its own three-line copy. This is why patch sources look slightly
  unusual.

- **Keep functions small.** dart_eval's compiler crashes outright on some
  combinations of statements in a large function. `marineford build` translates
  that crash into a sentence telling you to split it up. Small patch functions
  are good practice regardless.

Exclude the patch directory from your analyzer — it is not Dart the SDK will
ever compile:

```yaml
analyzer:
  exclude:
    - patch/**
```

---

## The CLI

```
marineford init <app-id>     Create marineford.yaml and a signing key pair
marineford abi               Print this build's ABI fingerprint
marineford build             Compile, lint and pack the patch package
marineford publish           Upload the packed patch and update the manifest
marineford rollout <n>       Change a patch's staged rollout percentage
marineford revoke <n> [n...] Revoke patches so devices roll back
marineford doctor            Check the project is ready to publish
```

`marineford.yaml`:

```yaml
app_id: com.example.app
channel: prod

patch_package: patch   # where the patch source lives
app_package: .         # where marineford_ids.json is

size_budget_kb: 256    # warn above this
```

In CI, supply the key through the environment instead of a file:

```bash
MARINEFORD_SIGNING_KEY="$SIGNING_KEY" marineford publish --app-versions '>=1.4.0 <1.5.0'
```

Channels are just directories. `--channel beta` publishes to `dist/beta/`, and
a build pointed at `.../beta/manifest.json` sees only those patches.

`marineford build` also lints, using the measured cost model: it warns about
large interpreted loops, override ids the app does not declare, missing version
constraints, and patches over the size budget. None of these fail the build.

---

## Runtime API

```dart
await Marineford.init(config);        // recover, activate, ready
await Marineford.checkForUpdate();    // fetch, verify, install
await Marineford.markBootSuccessful();// "this launch is healthy"
await Marineford.rollback();          // drop the active patch for this run
```

### Configuration worth knowing about

```dart
MarinefordConfig(
  // ...required fields...
  channel: 'prod',
  activation: PatchActivation.onNextLaunch,
  autoConfirmBootAfter: Duration(seconds: 3),
  maxBootAttempts: 2,
  failureThreshold: 5,
  retainPatches: 2,
  observer: MyObserver(),
)
```

**`activation`** — `onNextLaunch` (default) leaves the running app alone and
activates on the next start. `immediate` is also sound in v1, because activation
is a dispatch-table swap costing about a millisecond; functions already running
keep their original body and the next call diverts.

**`autoConfirmBootAfter`** — how long after activation to declare the launch
healthy. Set it to `null` and call `markBootSuccessful()` yourself at the point
your app is genuinely usable. A timer cannot tell a working app from one stuck
on a spinner, so if your app has a meaningful "we reached the home screen"
moment, use it.

**`observer`** — publish from a static host and nothing reports back to you. An
observer is the replacement:

```dart
final class MyObserver implements PatchObserver {
  @override
  void onEvent(PatchEvent event) {
    switch (event) {
      case PatchActivated(:final number, :final elapsed):
        analytics.log('patch_activated', {'n': number, 'ms': elapsed.inMilliseconds});
      case PatchFailure(:final id, :final error):
        Sentry.captureException(error, hint: id);
      case PatchBlocklisted(:final number, :final reason):
        Sentry.captureMessage('patch $number blocklisted: $reason');
      default:
    }
  }
}
```

Skip it and a patch failing on every device in the field is invisible to you.
This is the real cost of the no-server decision, and it is worth being deliberate
about.

**`plugins`** — bridges exposed to interpreted code. Empty by default, and that
default matters: a patch can only touch what you list here. Adding a bridge
grants that capability to anyone who can publish a patch.

---

## What it costs

Every number comes from [`bench/`](bench), which is committed and runs in CI.
Reproduce them AOT — JIT numbers describe nothing that ships:

```bash
dart compile exe bench/bin/run.dart -o bench/run && ./bench/run
```

| | |
|---|---|
| Marked call, no patch active | **~4 ns** (unmarked: ~2 ns) |
| Crossing into the interpreter | **~2.6 µs** fixed |
| Interpreted loop iteration | **~110 ns** |
| Realistic JSON normaliser call | **~3.4 µs** |
| Activating a patch at startup | **~1 ms** |
| A small patch on the wire | **~3.5 KB** gzipped |

At 60fps you have 16,666 µs per frame — room for roughly 500 boundary crossings.
That is a lot for screen-level logic and very little for anything per-item.

---

## Safety

| Threat | What stops it |
|---|---|
| A patch you did not sign | Ed25519 over the whole container, checked **before** anything is decompressed |
| A corrupted download | SHA-256 against the manifest, checked before parsing |
| A patch for the wrong build | ABI fingerprint of the patchable surface — catches the renamed signature semver misses |
| A replayed old patch | Monotonic patch numbers; a device never moves backwards unless its current patch was revoked |
| A patch that crashes on launch | Boot token; two failed launches and the device blocklists it permanently |
| A patch that throws at runtime | Every call falls back to the original function; repeated failures drop the patch for the session |
| A patch you need gone now | `marineford revoke` — devices roll back on their next check |
| A misdirected manifest | Ignored, never acted on — otherwise anyone who could swap the file could force a downgrade |

Interpreted code sees nothing by default. No file system, no network, no
platform channels.

### Store policy

Apple's developer agreement allows downloading interpreted code that does not
change the app's primary purpose — the same clause Shorebird relies on for iOS.
Google Play's Device and Network Abuse policy exempts code running in an
interpreter; what it forbids is downloading `dex`, `so` or `jar`. `.mfp`
payloads are dart_eval bytecode and no native code is downloaded at any point.

Staying inside "does not change the primary purpose" is your call, not the
library's.

---

## Repository layout

| Package | What it is |
|---|---|
| [`marineford`](packages/marineford) | The Flutter runtime: dispatch, download, verify, activate, roll back. |
| [`marineford_core`](packages/marineford_core) | Pure Dart. Manifest, `.mfp` container, signatures, patch selection, rollout bucketing. Shared by the runtime and the CLI so both sides agree on the rules. |
| [`marineford_annotation`](packages/marineford_annotation) | `@patchable`, `@PatchableService`, `@RuntimeOverride`. Zero dependencies. |
| [`marineford_gen`](packages/marineford_gen) | `build_runner` generator for the dispatch shims and the ABI fingerprint. |
| [`marineford_cli`](packages/marineford_cli) | The `marineford` command. |
| [`example/json_drift_app`](example/json_drift_app) | One marked function repairing eight backend changes, end to end. |
| [`bench`](bench) | The cost model the design is argued from. |

---

## Compared with Shorebird

[Shorebird](https://shorebird.dev) needs no annotations at all. It forks the
Flutter engine and the Dart compiler, saves your release snapshot, diffs the
next compile against it, and ships a binary patch — so it can fix any Dart code
in your app, including code nobody thought to mark.

| | Shorebird | marineford |
|---|---|---|
| Marking | none | required, ahead of time |
| Dart language coverage | 100% | dart_eval's subset |
| Engine | forked | stock |
| Flutter versions | only what Shorebird supports | any |
| Platforms | Android + iOS | anywhere Dart runs |
| Self-host | not offered | your own CDN |
| Cost | per patch install | none |
| Native code / plugins | cannot patch | cannot patch |

If you target Android and iOS, are happy to stay on the Flutter versions
Shorebird supports, and do not mind a subscription and a vendor, Shorebird is
the better product. marineford is a different trade: no fork, no vendor, no
cost, works anywhere Dart runs, and the entire pipeline is yours — paid for with
the marking requirement and a language subset.

---

## Development

A [pub workspace](https://dart.dev/tools/pub/workspaces) — one lockfile, one
`.dart_tool`, no extra tooling.

```bash
flutter pub get && flutter analyze && dart format --set-exit-if-changed .
```

Pure-Dart packages run under `dart test`; the Flutter runtime needs
`flutter test`. `marineford_gen` in particular cannot run under the Flutter test
harness, because `build_test` drives `build_runner`, which needs the Dart VM's
own package resolution.

```bash
dart test packages/marineford_core packages/marineford_annotation packages/marineford_gen packages/marineford_cli
```

```bash
flutter test packages/marineford example/json_drift_app
```

## License

MIT. See [LICENSE](packages/marineford_core/LICENSE).
