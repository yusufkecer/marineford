import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:pub_semver/pub_semver.dart';

/// Sentinel meaning "the patch ran and returned null".
///
/// [Patch.invoke0] and friends use `null` to mean "there is no patch, or it
/// failed — use the original code". A patch that legitimately returns null
/// therefore needs a distinguishable value, and this is it. Generated shims
/// unwrap it; hand-written ones must too.
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
    _bump();
  }

  /// Stops dispatching. Every shim goes back to its original body.
  static void deactivate() {
    if (_slots == null) return;
    _runtime = null;
    _slots = null;
    _onFailure = null;
    _failureCount = 0;
    _depth = 0;
    _bump();
  }

  /// Calls a patched function with no arguments.
  static Object? invoke0(int offset, [String id = '']) => _run(offset, id);

  /// Calls a patched function with one argument.
  static Object? invoke1(int offset, Object? a0, [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    runtime.args.add(a0);
    return _run(offset, id);
  }

  /// Calls a patched function with two arguments.
  static Object? invoke2(int offset, Object? a0, Object? a1, [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    runtime.args
      ..add(a0)
      ..add(a1);
    return _run(offset, id);
  }

  /// Calls a patched function with three arguments.
  static Object? invoke3(int offset, Object? a0, Object? a1, Object? a2,
      [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    runtime.args
      ..add(a0)
      ..add(a1)
      ..add(a2);
    return _run(offset, id);
  }

  /// Calls a patched function with any number of arguments.
  ///
  /// Allocates a list, so the fixed-arity variants are preferred where they
  /// fit — the allocation measures about 5ns against 4ns on the no-patch path,
  /// and considerably more once a patch is live and the list actually escapes.
  static Object? invokeN(int offset, List<Object?> args, [String id = '']) {
    final runtime = _runtime;
    if (runtime == null) return null;
    runtime.args.addAll(args);
    return _run(offset, id);
  }

  static Object? _run(int offset, String id) {
    final runtime = _runtime;
    if (runtime == null) return null;

    _depth++;
    try {
      final Object? raw;
      if (_depth > 1) {
        // Re-entry. A patched method that calls another patched method — via a
        // bridged object, or just `this.other()` on a patched service — lands
        // here. Runtime.execute() resets the program counter and would corrupt
        // the frame we are already inside; bridgeCall saves and restores it.
        // Verified: with execute() the nested case dies with a RangeError on
        // the opcode array, with bridgeCall it returns the right answer.
        runtime.bridgeCall(offset);
        raw = runtime.returnValue;
      } else {
        raw = runtime.execute(offset);
      }
      // A call that came back is evidence the patch works. Without this the
      // count is cumulative over the whole session, so a patch that throws once
      // an hour on one rare input eventually crosses the threshold and is
      // abandoned despite being right the rest of the time. The threshold means
      // consecutive failures.
      _failureCount = 0;
      if (raw == null) return patchedNull;
      if (raw is $Value) {
        return raw.$reified ?? patchedNull;
      }
      return raw;
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
      if (_depth == 0) {
        // A throw can leave arguments pushed for a frame that never started.
        // Only safe to clear at the outermost level; an inner frame's failure
        // must not eat the outer frame's arguments.
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
