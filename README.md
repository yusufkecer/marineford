# marineford

Repair a Flutter app that is already installed — the parts of it you marked as
repairable before you shipped.

Stock engine, stock toolchain, nothing of yours leaving your infrastructure. A
signed patch on any static host, and an interpreter that only ever runs inside
branches `@patchable` compiled into your binary. The qualifier in the first
sentence is the whole trade, and it is not fine print: **code that shipped
unmarked can never be patched.**

Patching logic needs nothing but this package. Patching UI additionally needs
[flutter_eval](https://pub.dev/packages/flutter_eval), which does not currently
compile against Flutter 3.41 and so needs a fork until
[the fix](https://github.com/ethanblake4/flutter_eval/pull/142) is released —
the least settled part of this, and worth knowing before you plan around it.

```dart
@patchable
Map<String, dynamic>? _normalizeResponse(String endpoint, Map<String, dynamic>? raw) => raw;
```

One marker there covers most of what a backend does to you afterwards — renamed
fields, changed status values, a new envelope, a type that moved — because the
function with the bug never has to be the function you marked. The
[example app](example/json_drift_app) takes eight response shapes through that
one function, repairing six and correctly leaving two alone, and repairs the
card that draws the result from the same patch.

> **Status: 0.1.0, the first release.** The pipeline works end to end and is
> covered by 460 tests. Treat the API as settled enough to build on and not yet
> settled enough to be surprised by a breaking 0.2.0.

---

## Why marking, and why it is survivable

marineford does not fork the Dart compiler, so it cannot add a branch to machine
code that is already compiled. `@patchable` inserts that branch at build time
and nowhere else. Ship v1.4.0 without marking a function and fixing that
function means a store release — and only builds from that release onward will
be patchable.

That is the cost. Three things make it a price worth paying, and understanding
them is most of understanding the library:

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

## When not to use this

marineford is for repairing something that is broken, on builds already in
users' hands. Several problems look like that and are not:

| You want to | Use |
|---|---|
| Change a value, threshold, copy string or feature flag | Remote Config. It is simpler, instant, and needs no signing key. |
| Change the shape of an API response | Your backend. Fix it at the source; a patch is what you reach for when you cannot. |
| Ship a screen the reviewed build never had | A store release. See [Store policy](#store-policy). |
| Fix a bug in code nobody marked | A store release. Nothing can help — this is the trade. |
| A/B test a layout | A feature flag around code you shipped. |

The case marineford is built for is narrower and sharper than any of those: a
crash, a mis-parse, a screen showing the wrong thing — found after release,
where waiting days for review is the actual cost.

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

To work against this repository instead of the published version, activate from
the checkout and use `path:` dependencies in step 2:

```bash
dart pub global activate --source path packages/marineford_cli
```

### 2. Add the dependencies

```yaml
dependencies:
  marineford: ^0.1.0

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

Three things about that annotation are worth knowing, because none of them are
enforced by the analyzer — it never sees this file.

* **Declare it, do not import it.** `marineford` does not export it, and could
  not usefully: the CLI hands dart_eval only the files under `patch/lib/`, so a
  `package:` import never reaches the compiler.
* **`version` is effectively required.** Leave it out and dart_eval substitutes a
  constraint on *its own* version, which no app satisfies — the override
  compiles, publishes, and silently never fires. `marineford build` warns.
* **The name cannot change.** dart_eval matches this annotation by identifier,
  so `RuntimeOverride` cannot be renamed or aliased.

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

### Mark in the app package, not in a package it depends on

The generator computes one fingerprint per package, from the marked functions in
that package. It cannot see into your dependencies — build_runner gives a builder
no way to enumerate another package's files.

So a `@patchable` function in a shared package of your own is a trap. It still
generates a shim and still dispatches, because dispatch ids are global. But it is
absent from the app's fingerprint, which means changing its signature will not
invalidate patches built against the old one — the single failure the fingerprint
exists to prevent.

`marineford doctor` catches it from the other side: an override whose id the app
does not declare is refused before you can publish. Keep marked functions in the
app package and the question does not arise.

---

## What can cross the boundary

The generator refuses at build time rather than emitting a shim that compiles
and then silently falls back.

| Type | Supported |
|---|---|
| `int`, `double`, `bool`, `num` | yes |
| `String` | yes |
| `List`, `Map`, `Set`, `Iterable` | yes, with element types below |
| `Object`, `dynamic` | yes |
| nullable versions of all the above | yes |
| `void` return | yes |
| `Future<T>` return, for any `T` above | yes |
| `Widget` return, and `List<Widget>` | yes — see [Patching UI](#patching-ui) |
| your own classes | **no** — build error |
| `Stream`, `FutureOr` | **no** — build error |
| `Future` as a *parameter* | **no** — build error |
| `Widget` or `BuildContext` as a *parameter* | **no** — build error |
| function types / callbacks | **no** — build error |
| named or optional parameters | **no** — build error |

If a parameter is your own domain object, move the boundary rather than the
type: mark a function further up the call chain whose parameters are already
JSON-shaped. That is usually the better boundary anyway.

A collection's element type has to be something the unwrapping actually
produces — `dynamic`, a primitive, `String`, `Map<String, dynamic>` or
`List<dynamic>`. `List<Map<String, dynamic>>` is fine; `List<Map<String, int>>`
is a build error, because the value would be converted to `dynamic` and then
fail the check, and a patch that loads and is discarded on every call is the
one outcome worth refusing at build time.

### Async

A `Future`-returning function is patchable. The shim hands the interpreter's
future back, converts the resolved value, and falls back to the original if the
patch fails — the same guarantee the synchronous path gives, one await later.

An async dispatch measures **4.8µs** against 2.6µs for a synchronous one. Nearly
all of the difference is the suspend and resume; **74ns** of it is the zone each
async call forks for itself, which is what makes a post-await failure
attributable to the call it belongs to instead of vanishing.

Two limits come from dart_eval rather than from marineford, and both are build
errors:

* **`try`/`catch` around an `await` does not work.** The catch frame is dropped
  at the suspension point, so a handler written after an `await` never runs.
  `marineford build` refuses a patch that contains one — but that refusal reads
  the source text, and unlike the `dart:io` rule there is no runtime boundary
  behind it. A patch that slips past the check publishes with error handling
  that silently does nothing. Treat it as a rule to follow, not a net to lean
  on: do not write `catch` around `await` in a patch.
* **The `Future` surface is small.** Interpreted code gets `Future.delayed` and
  `.then`. There is no `Future.wait`, `Future.value`, `catchError`,
  `whenComplete` or `timeout`, and `async*` / `sync*` / `await for` are not
  supported at all. Anything else fails to compile, with a message naming it.

One more thing worth knowing: an async patch that fails takes the whole patch
down for the session. dart_eval does not restore its frame bookkeeping when an
async call unwinds, so the runtime is not trustworthy afterwards — every marked
function goes back to its original body rather than spending more calls on it.
The next launch starts clean.

### Patching UI

A function returning a `Widget` is patchable, so a screen that renders the
wrong thing can be repaired the same way a parser can.

```dart
@patchable
Widget _collectDayCard(Map<String, dynamic> data) => Card(/* ... */);
```

and in the patch:

```dart
@RuntimeOverride(
  'pkg:app/lib/collect_day_screen.dart#collectDayCard',
  version: '>=1.4.0 <1.5.0',
)
Widget card(Map data) => Card(/* the corrected arrangement */);
```

**`build` itself cannot be marked**, because a `BuildContext` cannot cross the
boundary. That restriction earns its keep: it forces the marker onto a function
whose inputs are data, which is the only kind a patch can be handed. Mark the
function that builds the part you want to repair, and call it from `build`.
This is the chokepoint pattern again — one marked builder per screen region
covers everything drawn inside it.

**Turn it on** by registering [flutter_eval](https://pub.dev/packages/flutter_eval),
which provides the Flutter bindings the interpreter needs:

```dart
MarinefordConfig(
  // ...
  plugins: const [flutterEvalPlugin],
)
```

Nothing in `marineford` depends on flutter_eval, so an app that only patches
logic never links it. The CLI does not need it either — it compiles patches
from bundled declarations and stays pure Dart, which is what keeps
`dart pub global activate` working.

> **You need a fork today.** flutter_eval 0.8.2 does not compile against
> current Flutter — `$Container` implements `Container` without its
> `isAntiAlias` field. The fix is one line and is open upstream as
> [flutter_eval#142](https://github.com/ethanblake4/flutter_eval/pull/142).
> Until it is released, add a `dependency_overrides` entry pointing at a fork
> that carries it. Only apps patching UI are affected.

#### What it costs

An interpreted card build — `Card` > `Padding` > `Column` with text, a row and
a button — measures **20µs** against **3µs** for the same tree built natively.
That is **0.12%** of a 60fps frame; about 820 of them would fill one.

The rule that follows: **patch a screen or a section, never a list row.** A
handful of patched regions per screen is free in practice. A marked builder
called once per item in a long list is not, and the difference is three orders
of magnitude, not a few percent.

#### What a patch can draw

flutter_eval's bindings, not all of Flutter. `Scaffold`, `AppBar`, `Card`,
`ListTile`, `Column`, `Row`, `Padding`, `Container`, `Stack`, `Text`,
`TextField`, `ElevatedButton`, `TextButton`, `IconButton`, `Image`,
`GestureDetector`, `InkWell`, `Navigator`, `Theme` and the painting types
around them are covered. Anything outside that fails at `marineford build`
with the name of what it could not resolve — a build error, not a surprise on
a device.

The sandbox is unchanged and still holds: `Image.network`, `Image.asset` and
platform channels are all permission-gated, marineford grants nothing, and a
patch that reaches for one fails and falls back like any other patch bug.
There are tests for each.

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

`revoke` is the one command with no undo — the revoked list only grows — so it
takes a `--dry-run`, which writes nothing and prints where devices would land:

```
$ marineford revoke 2 --dry-run 1.4.0
Revoking #2 on prod — dry run, nothing is written.
Simulated for app 1.4.0, with every device inside the rollout.

  device on     becomes
  ---------     -------
  nothing       #1
  #1            unchanged (#1)
  #2            #1
```

It takes an app version because the answer depends on one: a patch constrained
to `<1.5.0` is not a fallback for a device on 1.5.0. If the patch devices would
fall back to is itself on a staged rollout, the preview says so — the table is
optimistic in exactly that case.

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
| Handing a 50-row payload to a patch | **~0.06 µs** |
| Verifying one Ed25519 signature | **~2.4 ms** |
| Swapping the dispatch table | **~0.35 ms** |
| A small patch on the wire | **~3.5 KB** gzipped |

At 60fps you have 16,666 µs per frame — room for roughly 500 boundary crossings.
That is a lot for screen-level logic and very little for anything per-item.

Payloads are handed across as views rather than copies, which is why the fifth
row is what it is — it used to be **35 µs**, thirteen crossings' worth of
copying done before the patch read its first field. A patch sees an entry when
it asks for one. Writing through a view copies first, so a patch still cannot
reach back into your data.

**Startup is dominated by signature verification, not by anything marineford
does.** `Marineford.init` re-verifies the stored patch on every launch, so it
costs about **2.8 ms** — 2.4 of that is Ed25519. Call `checkForUpdate()` during
startup too, as the quick start does, and the manifest's signature makes it
about **5.2 ms**. An earlier version of this table said "~1 ms" for startup;
that was the table swap alone, with the verification it sits behind left out.

`cryptography` falls back to a pure Dart Ed25519 unless
[`cryptography_flutter`](https://pub.dev/packages/cryptography_flutter) is
present to hand it to the platform. marineford does not depend on that — it
would make this package carry native code, which is most of what "works
anywhere Dart runs" is worth. Add it to your app if 2.4 ms on the launch path
matters more to you than that does; nothing here needs to change.

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
| A manifest for the wrong channel | Ignored too. Nothing else compares the two, and a prod build pointed at a beta URL is an easy mistake |
| A patch that inflates to gigabytes | Decompression stops at 64MB. The container cap bounds the download, not what it expands to |
| A patch that fails asynchronously | Dispatch runs in a guarded zone, so a Future the patch never awaited is counted like any other failure instead of reaching your error handler |

### What a patch can reach

Its arguments, and the bridges you registered. Nothing else: no file system, no
network, no processes, no platform channels.

That is enforced in two places, and it is worth knowing which. dart_eval is
default-deny and checks a permission before each `dart:io` call; marineford
grants none, so those throw. But `InternetAddress.lookup` was never gated
upstream, and it ran — a patch could encode data into a hostname and exfiltrate
it over DNS, around the network permission entirely. marineford now takes over
`dart:io`'s ungated entry points and refuses them itself, and `marineford build`
rejects a patch that imports `dart:io` at all.

Reaching any of this needs the signing key, so the threat is a malicious patch
author or a stolen key rather than a stranger. That is exactly why the blast
radius has to be what the documentation says it is.

If a patch genuinely needs a capability, `permissions` on `MarinefordConfig`
grants it explicitly and narrowly. Granting widens what a stolen key is worth.

### Store policy

Read this yourself rather than taking anyone's summary, including this one.

**What is true about the payload.** `.mfp` files are dart_eval bytecode. No
native code is downloaded at any point — no `dex`, `so`, `jar` or dylib — and
Google Play's Device and Network Abuse policy draws its line exactly there: it
forbids downloading executable code and exempts code that runs in an
interpreter.

**What is true about capability.** The type boundary is not a policy, it is a
mechanism. A patch is handed JSON-shaped values and widgets and can reach
nothing else: no file system, no sockets, no processes, no DNS, no platform
channels. It cannot add a feature the shipped binary could not already perform,
because there is no surface through which to add one. That is a stronger claim
than "we intend to only fix bugs", and it is testable — there are tests.

**What is not settled.** Apple is the awkward one. The interpreted-code
exception in the Developer Program License Agreement is scoped to code run by
WebKit or JavaScriptCore, which dart_eval is not, and App Review Guideline
2.5.2 asks whether downloaded code "introduces or changes features or
functionality". An earlier version of this section said the agreement allows
interpreted code that does not change the app's primary purpose; that dropped
the scoping and read as more permission than the text gives.

Patching UI makes this judgement matter more, not less. What marineford is for
is repairing a screen that is already wrong — the same card, arranged
correctly. Shipping screens the reviewed build never had is a different thing,
and the guidelines are aimed at it.

Whether your patch stays on the right side of that line is your call. Nothing
in this library can make it for you.

---

## Repository layout

| Package | What it is |
|---|---|
| [`marineford`](packages/marineford) | The Flutter runtime: dispatch, download, verify, activate, roll back. Also `@patchable` and `@PatchableService`, since anything marking a function already depends on it. |
| [`marineford_core`](packages/marineford_core) | Pure Dart. Manifest, `.mfp` container, signatures, patch selection, rollout bucketing. Shared by the runtime and the CLI so both sides agree on the rules. |
| [`marineford_gen`](packages/marineford_gen) | `build_runner` generator for the dispatch shims and the ABI fingerprint. |
| [`marineford_cli`](packages/marineford_cli) | The `marineford` command. |
| [`example/json_drift_app`](example/json_drift_app) | One marked function repairing eight backend changes, and one marked builder repairing the card that draws the result — end to end, from one patch. |
| [`bench`](bench) | The cost model the design is argued from. |
| [`tool/bridge_dump`](tool/bridge_dump) | Regenerates the Flutter bridge declarations the CLI compiles against. The only thing here that depends on flutter_eval, kept out of the workspace so an upstream break cannot stop the rest building. |

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
| UI | any widget | flutter_eval's bindings, from a marked builder |
| Engine | forked | stock |
| Flutter versions | only what Shorebird supports | any |
| Platforms | Android + iOS | anywhere Dart runs |
| Self-host | not offered | your own CDN |
| Cost | per patch install | hosting only |
| Native code / plugins | cannot patch | cannot patch |

If you target Android and iOS, are happy to stay on the Flutter versions
Shorebird supports, and do not mind a subscription and a vendor, Shorebird is
the better product. It patches code nobody marked, which is the thing marineford
structurally cannot do.

marineford is a different trade: stock engine, no vendor, works anywhere Dart
runs, and the whole pipeline is yours — nothing leaves your infrastructure and
nobody else sees your code. Paid for with the marking requirement and a language
subset. The cost difference is smaller than it looks once you are hosting files
somewhere anyway; what actually differs is control.

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
dart test packages/marineford_core packages/marineford_gen packages/marineford_cli
```

```bash
flutter test packages/marineford example/json_drift_app
```

## License

MIT. See [LICENSE](packages/marineford_core/LICENSE).
