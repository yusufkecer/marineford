import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:pub_semver/pub_semver.dart';

/// Sentinel meaning "the patch ran and returned null".
///
/// [Patch.invoke0] and friends use `null` to mean "there is no patch, or it
/// failed — use the original code". A patch that legitimately returns null
/// therefore needs a distinguishable value, and this is it. Generated shims
/// unwrap it; hand-written ones must too.
///
/// This is not the only value a hand-written shim has to recognise. A patched
/// `async` function has to be dispatched through [Patch.dispatchAsync], which
/// answers with these same three values one await later.
const Object patchedNull = _PatchedNull();

final class _PatchedNull {
  const _PatchedNull();
  @override
  String toString() => 'patchedNull';
}

/// Called when interpreted code throws.
typedef PatchFailureHandler = void Function(
    String id, Object error, StackTrace stackTrace);

/// The dispatch table generated shims call into.
///
/// Everything here is static and deliberately so: the hot path is a shim asking
/// "is there a patch for me?", and that question has to cost essentially
/// nothing when the answer is no. With no patch active it is one static field
/// read against null — measured at roughly 4ns against 2ns for calling the
/// original function directly. See `bench/`.
///
/// This class is not meant to be called by hand. Use `@patchable` or
/// `@PatchableService` and let `marineford_gen` write the calls.
final class Patch {
  Patch._();

  static Map<String, int>? _slots;
  static Runtime? _runtime;
  static int _depth = 0;
  static int _failureCount = 0;
  static int _failureThreshold = 5;
  static PatchFailureHandler? _onFailure;

  static int _generation = 0;
  static final ValueNotifier<int> _generationNotifier = ValueNotifier<int>(0);

  /// The zone every patched call runs in.
  ///
  /// The catch in [_run] only sees what comes back synchronously, and that is
  /// not the whole of what a patch can do wrong. Interpreted code can start a
  /// Future and not await it — its own `async` helper, or a bridge that returns
  /// one — and when that fails afterwards it lands nowhere: the counter does
  /// not move, the observer hears nothing, the blocklist never engages, and in
  /// Flutter it surfaces as an unhandled zone error that can take the app down
  /// depending on the error handler installed.
  ///
  /// So the whole point of the safety net — "a bug in downloaded code degrades
  /// to the original function running" — held only for synchronous bugs. This
  /// forked zone catches the rest, which is why dispatch runs inside it.
  ///
  /// Reached without a signing key: an ordinary fire-and-forget mistake is
  /// enough, which makes it the more likely of the two to be met in practice.
  ///
  /// Entering it costs 11ns, against 2.6µs for the crossing it wraps — see
  /// `bench/`. Paid only while a patch is live and only on calls that actually
  /// dispatch, and it buys the difference between an app that degrades and one
  /// that dies.
  ///
  /// That figure used to read 454ns, which was noise rather than a cost: it was
  /// arrived at by timing a crossing inside the zone, timing one outside, and
  /// subtracting — two ~2.6µs measurements whose spread is far wider than the
  /// number being recovered. Consecutive runs of the same pair gave +158ns and
  /// -515ns. The zone is now timed on its own.
  static Zone? _zone;

  /// The zone [dispatchAsync] installed for the call currently being started.
  ///
  /// Non-null only for the moment between forking that zone and the interpreter
  /// suspending inside it. [_run] reads it to know it is already in a guarded
  /// zone and must not enter [_zone] on top — the whole point of the per-call
  /// fork is that the continuation captures *that* zone and no other.
  static Zone? _callZone;

  /// Bumped every time a patch is activated or deactivated.
  ///
  /// Every generated shim reads this on every call and compares it against a
  /// cached slot, which turns a per-call string hash and map probe into a
  /// per-call integer compare. Measured at 8.9ns against 4.5ns for a marked
  /// function that is not itself patched while some other patch is live — the
  /// normal state of an app once anything has shipped. See `bench/`.
  ///
  /// A plain static field rather than the notifier's value, deliberately.
  /// `ValueNotifier` is subclassed throughout Flutter, so reading `.value` is
  /// an interface call the compiler cannot always devirtualise, and this is the
  /// single hottest read in the library.
  @pragma('vm:prefer-inline')
  static int get generation => _generation;

  /// [generation] as something widgets can listen to.
  ///
  /// v1 has no widget patching, so nothing in the framework listens yet. It is
  /// exposed now because v2's patchable widget zones will need exactly this and
  /// changing the dispatcher later would be a breaking change.
  static Listenable get generationListenable => _generationNotifier;

  /// Advances the generation, invalidating every shim's cached slot.
  ///
  /// The counter moves first: a listener that calls a patched function from its
  /// callback must not see a stale slot.
  static void _bump() {
    _generationNotifier.value = ++_generation;
  }

  /// Whether a patch is currently dispatching.
  static bool get isActive => _slots != null;

  /// Ids the active patch replaces. Empty when no patch is active.
  static Iterable<String> get activeIds => _slots?.keys ?? const <String>[];

  /// How many times interpreted code has thrown since activation.
  static int get failureCount => _failureCount;

  /// Looks up the bytecode offset for [id], or null if it is not patched.
  ///
  /// This is the function on the hot path. Keep it a single field read.
  @pragma('vm:prefer-inline')
  static int? slot(String id) => _slots?[id];

  /// Makes [runtime] the active patch.
  ///
  /// [slots] must already be filtered by version constraint — see
  /// [resolveSlots]. Resolving constraints here instead would put a
  /// `VersionConstraint.parse` on every call, which measured well over a
  /// microsecond of pure waste per invocation.
  static void activate(
    Runtime runtime,
    Map<String, int> slots, {
    PatchFailureHandler? onFailure,
    int failureThreshold = 5,
  }) {
    _runtime = runtime;
    _slots = Map<String, int>.unmodifiable(slots);
    _onFailure = onFailure;
    _failureThreshold = failureThreshold;
    _failureCount = 0;
    _depth = 0;
    // Forked once here rather than per call. A per-call fork could attribute an
    // async failure to the exact dispatch that started it, but it would pay for
    // that on every crossing, and the id is a diagnostic — what has to be right
    // is that the failure is counted at all.
    _zone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (Zone self, ZoneDelegate parent, Zone zone,
            Object error, StackTrace stackTrace) {
          _recordFailure(_asyncId, error, stackTrace);
        },
      ),
    );
    _bump();
  }

  /// Stands in for a dispatch id when the failure arrived asynchronously.
  ///
  /// By the time an unawaited Future fails, the call that started it has
  /// returned, so there is nothing left to name it with. Better an honest
  /// placeholder than the id of whichever call happened to run most recently.
  static const String _asyncId = '<async, after the call returned>';

  /// Stops dispatching. Every shim goes back to its original body.
  static void deactivate() {
    if (_slots == null) return;
    _runtime = null;
    _slots = null;
    _onFailure = null;
    _failureCount = 0;
    _depth = 0;
    _zone = null;
    _bump();
  }

  /// Calls a patched function with no arguments.
  ///
  /// Three results are possible here and in every `invokeN` below: `null` for
  /// "no patch, or it failed"; [patchedNull] for a patch that returned null;
  /// and a `Future` when the patched function is `async`. Do not await that
  /// future directly — call the whole thing through [dispatchAsync], which is
  /// what installs the zone its failure is reported to.
  static Object? invoke0(int offset, [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    final staged = runtime.args;
    return _run(runtime, offset, id, staged, staged.length);
  }

  /// Calls a patched function with one argument.
  static Object? invoke1(int offset, Object? a0, [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    final staged = runtime.args;
    final mark = staged.length;
    staged.add(a0);
    return _run(runtime, offset, id, staged, mark);
  }

  /// Calls a patched function with two arguments.
  static Object? invoke2(int offset, Object? a0, Object? a1, [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    final staged = runtime.args;
    final mark = staged.length;
    staged
      ..add(a0)
      ..add(a1);
    return _run(runtime, offset, id, staged, mark);
  }

  /// Calls a patched function with three arguments.
  static Object? invoke3(int offset, Object? a0, Object? a1, Object? a2,
      [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    final staged = runtime.args;
    final mark = staged.length;
    staged
      ..add(a0)
      ..add(a1)
      ..add(a2);
    return _run(runtime, offset, id, staged, mark);
  }

  /// Calls a patched function with any number of arguments.
  ///
  /// Allocates a list, so the fixed-arity variants are preferred where they
  /// fit — the allocation measures about 5ns against 4ns on the no-patch path,
  /// and considerably more once a patch is live and the list actually escapes.
  static Object? invokeN(int offset, List<Object?> args, [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    final staged = runtime.args;
    final mark = staged.length;
    staged.addAll(args);
    return _run(runtime, offset, id, staged, mark);
  }

  /// Dispatches a patched `async` function and settles what it produced.
  ///
  /// [invoke] is the ordinary `invokeN` call; this runs it, and returns a
  /// future that resolves to what the patch resolved to, [patchedNull] if it
  /// resolved to null, or **null if it failed** — the same three answers the
  /// synchronous path gives, so the generated shim reads them the same way and
  /// runs the original function on null.
  ///
  /// The failure never reaches the caller as a rejection. That is deliberate:
  /// falling back is only sound because of the type boundary. A patch body
  /// takes JSON and returns JSON; it cannot touch the file system, the network,
  /// or the app's own state, so running the original after the patch already
  /// ran cannot repeat a side effect. If that boundary is ever widened, this is
  /// the guarantee that has to be revisited first.
  ///
  /// dart_eval reports an async failure through whichever channel the throw
  /// happened on. Before the first `await` it comes back out of the call
  /// synchronously and `_run` catches it. After one, it does *not* reject the
  /// future the caller holds — it surfaces as an uncaught error in the zone the
  /// continuation captured, and the future simply never completes. Both are
  /// funnelled into the same completer below.
  static Future<Object?> dispatchAsync(Object? Function() invoke,
      [String id = '']) {
    final settled = Completer<Object?>();
    var recorded = false;
    void fail(Object error, StackTrace stackTrace) {
      // Only the first failure of a call is the one that broke it; a later one
      // from something the patch started and abandoned is still worth counting,
      // but not twice for the same cause.
      if (!recorded) {
        recorded = true;
        _recordFailure(id, error, stackTrace);
      }
      if (settled.isCompleted) return;
      settled.complete(null);
      // And the patch goes with it. The interpreter does not survive an async
      // failure: dart_eval unwinds one without restoring the frame bookkeeping
      // it pushed at the suspension, so the *next* dispatch reads a frame that
      // is not its own and fails too. The consecutive-failure threshold would
      // get there eventually, but only after spending several more crossings
      // on a runtime already known to be unusable. Every shim falls back to its
      // original from here, which is the outcome the threshold was aiming at.
      deactivate();
    }

    // Forked per call, which the synchronous path deliberately does not do.
    // It has to be per call here: the interpreter's own failure after an await
    // arrives as an *uncaught* error in whichever zone the continuation
    // captured, not as a rejection of the future the caller is holding. A
    // single shared zone therefore swallowed it — the error was reported, the
    // future never completed, and the caller waited forever. One zone per call
    // is what makes the error attributable to the call it belongs to.
    final zone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (Zone self, ZoneDelegate parent, Zone innerZone,
                Object error, StackTrace stackTrace) =>
            fail(error, stackTrace),
      ),
    );

    final previous = _callZone;
    _callZone = zone;
    Object? outcome;
    try {
      outcome = zone.run(invoke);
    } finally {
      _callZone = previous;
    }

    if (outcome == null) {
      // Failed on the synchronous channel; `_run` has already recorded it.
      settled.complete(null);
    } else if (outcome is Future<Object?>) {
      final pending = outcome;
      final before = _failureCount;
      zone.run(() => pending.then<void>(
            (Object? value) {
              // Only if nothing failed while this call was suspended. The count
              // means *consecutive* failures, and a run of them that piled up
              // during the await is not broken by this call succeeding.
              if (_failureCount == before) _failureCount = 0;
              if (!settled.isCompleted) settled.complete(_reify(value));
            },
            onError: fail,
          ));
    } else {
      settled.complete(outcome);
    }
    return settled.future;
  }

  /// An interpreter value as the dispatcher hands it to a shim.
  static Object? _reify(Object? value) {
    if (value == null) return patchedNull;
    if (value is $Value) return value.$reified ?? patchedNull;
    return value;
  }

  /// Runs the patch at [offset].
  ///
  /// [staged] is the list this frame pushed its arguments onto and [mark] is
  /// where they start, so a failure can take back exactly its own and nothing
  /// else. See the note in the `finally` for why that cannot be done by
  /// clearing.
  static Object? _run(
      Runtime runtime, int offset, String id, List<Object?> staged, int mark) {
    _depth++;
    try {
      // Inside the zone, so that anything the patch starts and does not await
      // inherits it and reports its failure back here instead of escaping to
      // the app. Entered once at the outermost frame: a nested call is already
      // in the zone, and re-entering would cost a closure per crossing for
      // nothing.
      // Always bridgeCall, never execute.
      //
      // The two differ only in that bridgeCall saves and restores the program
      // counter, which is what makes a nested call safe — a patched method
      // calling another patched method dies with a RangeError on the opcode
      // array under execute(). The dispatcher used to pick between them on
      // depth, and that choice was a liability: depth is decremented when the
      // frame unwinds, but an interpreted `async` function unwinds at its first
      // await and is resumed later by dart_eval itself. Anything re-entering
      // during that gap would be judged top-level and get execute(), while the
      // interpreter was genuinely mid-call.
      //
      // Removing the choice removes the way to get it wrong. Verified against
      // the whole runtime suite, and the extra save/restore is a few
      // instructions against a 2.6µs crossing.
      final zone = _zone;
      Object? enter() {
        runtime.bridgeCall(offset);
        return runtime.returnValue;
      }

      // Entered once at the outermost frame: a nested call is already in the
      // zone, and re-entering would cost a closure per crossing for nothing.
      // An async dispatch has already forked its own zone and is running inside
      // it, so entering the shared one on top would be the thing that made the
      // per-call fork pointless.
      final Object? raw = _depth > 1 || zone == null || _callZone != null
          ? enter()
          : zone.run(enter);
      // An interpreted `async` function hands back a `$Future`, and a `$Future`
      // is also a `$Value` — so this has to come first or the branch below
      // would quietly reify it into a *different* future that unwraps only one
      // level deep. The shim awaits it through [awaitPatched] instead.
      //
      // It also comes before the reset below, and that is the load-bearing
      // part: a suspended call has not succeeded, it has only stopped. Resetting
      // here let awaitPatched's later increment be wiped by the next dispatch,
      // so the count oscillated between 0 and 1 and an async patch that failed
      // every single call was never abandoned.
      if (raw is Future) return raw;
      // A call that came back is evidence the patch works. Without this the
      // count is cumulative over the whole session, so a patch that throws once
      // an hour on one rare input eventually crosses the threshold and is
      // abandoned despite being right the rest of the time. The threshold means
      // consecutive failures.
      _failureCount = 0;
      return _reify(raw);
    } on Object catch (error, stackTrace) {
      // Deliberately catches everything. A bug in downloaded code must degrade
      // to "the original function runs" and never to a crash — that is the
      // whole safety story, and it only holds if nothing escapes here.
      _recordFailure(id, error, stackTrace);
      return null;
    } finally {
      // Clamped rather than a plain decrement: _recordFailure can deactivate
      // mid-flight, and deactivate resets the depth while this frame is still
      // on the stack. An unclamped decrement would take it negative, and then
      // the `== 0` below would never fire again and arguments would accumulate
      // forever.
      if (_depth > 0) _depth--;

      // Leave the argument stack exactly as this frame found it.
      //
      // The interpreter takes ownership of the staged list at the callee's
      // first opcode: it copies the values into the new frame and installs a
      // *fresh* one (dart_eval 0.8.5, flow.dart — `runtime.args = []`, not
      // `clear()`). Which list is current on the way out therefore says which
      // of two different messes we are cleaning up.
      //
      // Still ours: the callee never started — a bad offset, or a throw in the
      // VM's own setup — and our arguments are untouched. Take back exactly
      // those. Not the whole list: at depth one or more, everything before the
      // mark belongs to the frame that called us and is still owed to it.
      //
      // Not ours: the callee ran and abandoned values it had staged for a call
      // of its own before it threw. Nothing above us lives on that list, so
      // clearing it is both safe and necessary — the caller keeps pushing onto
      // that same list once we unwind, and would find the leftovers first.
      //
      // The previous version only cleared at depth 0. That covered both cases
      // at the outermost level, which is why it looked complete, and neither
      // one level in.
      if (identical(runtime.args, staged)) {
        if (staged.length > mark) staged.removeRange(mark, staged.length);
      } else {
        runtime.args.clear();
      }
    }
  }

  static void _recordFailure(String id, Object error, StackTrace stackTrace) {
    _failureCount++;
    final handler = _onFailure;
    if (handler != null) {
      try {
        handler(id, error, stackTrace);
      } on Object {
        // An observer that throws must not turn a handled patch failure into an
        // unhandled one. Whatever it was trying to report is already lost; the
        // fallback path is not.
      }
    }
    if (_failureCount >= _failureThreshold) {
      // A patch that has thrown this many times in a row is not going to start
      // working. Drop it for the rest of the session; the client blocklists it
      // on disk so the next launch does not pay for it again.
      deactivate();
    }
  }

  /// Resets everything. Tests only.
  @visibleForTesting
  static void resetForTesting() {
    _runtime = null;
    _slots = null;
    _onFailure = null;
    _failureCount = 0;
    _depth = 0;
    _zone = null;
    _generation = 0;
    _generationNotifier.value = 0;
  }
}

/// Turns a compiled program's override table into a dispatch table, dropping
/// entries whose version constraint does not cover [appVersion].
///
/// Done once at activation. Doing it per call — which is what dart_eval's own
/// `runtimeOverride` does — costs a `VersionConstraint.parse` on every
/// invocation and measured 4.21µs against 2.49µs for the resolved form.
///
/// An unparseable constraint drops the override rather than throwing: one bad
/// annotation in a patch should cost that one function, not the whole patch.
Map<String, int> resolveSlots(Runtime runtime, Version appVersion) {
  final slots = <String, int>{};
  runtime.overrideMap.forEach((id, spec) {
    final constraint = spec.versionConstraint;
    if (constraint == null) {
      slots[id] = spec.offset;
      return;
    }
    try {
      if (VersionConstraint.parse(constraint).allows(appVersion)) {
        slots[id] = spec.offset;
      }
    } on FormatException {
      // Unparseable constraint: skip this override only.
    }
  });
  return slots;
}
