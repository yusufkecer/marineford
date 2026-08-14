import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:marineford_core/marineford_core.dart';
import 'package:pub_semver/pub_semver.dart';

/// Reproduces the numbers marineford's design is argued from.
///
/// Every performance claim in the README and the plan comes from here. They are
/// committed and run rather than remembered, because the design rests on a
/// handful of specific costs — 2.4ns for a marked call with no patch, ~2.5µs to
/// cross into the interpreter, ~107ns per interpreted loop iteration, ~74ns to
/// fork the zone an async dispatch needs — and each one justifies a decision
/// that would be wrong if the number moved.
///
/// Measure a small cost on its own, never by subtracting two large ones. The
/// zone figures here were once derived by differencing two interpreter
/// crossings and reported 454ns for something that costs 11ns; consecutive runs
/// of that same subtraction gave +158ns and -515ns.
///
/// Run with `--check` to fail when a measurement drifts past its tolerance.
///
/// Timings are machine-dependent. The tolerances are wide on purpose: this
/// guards against an order-of-magnitude regression, not against a slow laptop.
/// True when this was built with `dart compile exe`.
///
/// Product mode is only set for an AOT build, and the distinction matters more
/// than it looks: under the JIT the same measurements come out several times
/// worse — compiling a patch reads 246ms against 2ms — because the JIT is still
/// warming up the analyzer. Shipped apps are AOT, so JIT numbers describe
/// nothing anyone experiences.
const bool _isAot = bool.fromEnvironment('dart.vm.product');

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  if (check && !_isAot) {
    stderr.writeln('Refusing to check budgets under the JIT.\n\n'
        'Timings here only mean something for an AOT build, which is what ships.\n'
        'Build it first:\n\n'
        '  dart compile exe bench/bin/run.dart -o bench/run\n'
        '  ./bench/run --check\n');
    exit(2);
  }
  if (!_isAot) {
    stdout.writeln('NOTE: running under the JIT. These numbers are not '
        'comparable to the ones\n      in the README, which are AOT. Use '
        '`dart compile exe` for those.\n');
  }
  final results = <_Result>[];

  results.addAll(_dispatchCosts());
  results.addAll(await _interpreterCosts());
  results.addAll(_jsonBridgeCosts());
  results.addAll(await _signatureCosts());
  results.addAll(_patchSizes());

  stdout.writeln('');
  stdout.writeln('${'measurement'.padRight(44)} ${'value'.padLeft(12)}  '
      'budget');
  stdout.writeln('${'-' * 44} ${'-' * 12}  ------');
  var failed = 0;
  for (final result in results) {
    final over = result.budget != null && result.value > result.budget!;
    if (over) failed++;
    stdout.writeln('${result.label.padRight(44)} '
        '${result.formatted.padLeft(12)}  '
        '${result.budget == null ? '-' : result.formatBudget()}'
        '${over ? '  OVER' : ''}');
  }

  if (check && failed > 0) {
    stderr.writeln('\n$failed measurement${failed == 1 ? '' : 's'} outside '
        'budget.');
    exit(1);
  }
}

final class _Result {
  _Result(this.label, this.value, this.unit, {this.budget});

  final String label;
  final double value;
  final String unit;
  final double? budget;

  String get formatted => '${value.toStringAsFixed(value < 10 ? 2 : 0)} $unit';
  String formatBudget() => '${budget!.toStringAsFixed(0)} $unit';
}

Future<double> _timeNsAsync(
    int iterations, Future<void> Function() body) async {
  for (var i = 0; i < 200; i++) {
    await body();
  }
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await body();
  }
  return stopwatch.elapsedMicroseconds * 1000 / iterations;
}

double _timeNs(int iterations, void Function() body) {
  for (var i = 0; i < 2000; i++) {
    body();
  }
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    body();
  }
  return stopwatch.elapsedMicroseconds * 1000 / iterations;
}

// --- the shim hot path -------------------------------------------------------

Map<String, int>? _slots;

@pragma('vm:prefer-inline')
int? _slot(String id) => _slots?[id];

int _native(int a, int b) => a + b;

/// What the generator emits: one static read, then the original.
int _guardedShim(int a, int b) {
  final slot = _slot('bench#add');
  if (slot != null) return 0;
  return _native(a, b);
}

/// The shape the design started from, kept as the comparison that justifies
/// arity-specialised invokes: it allocates an argument list on every call even
/// when there is no patch.
int _naiveShim(int a, int b) {
  final result = _naiveLookup('bench#add', <Object?>[a, b]);
  if (result != null) return result as int;
  return _native(a, b);
}

/// Never inlined on purpose.
///
/// In the real dispatcher this is a static call into another library that
/// pushes the arguments onto an interpreter stack, so the list genuinely
/// escapes and genuinely gets allocated. Left inlinable here, Dart's escape
/// analysis deletes the allocation and the comparison silently measures
/// nothing.
@pragma('vm:never-inline')
Object? _naiveLookup(String id, List<Object?> args) {
  final slot = _slots?[id];
  if (slot == null) return null;
  return args.length;
}

/// Stands in for `Patch.generation`, which a real shim compares against.
int _generation = 0;

int _cachedGeneration = -1;
int? _cachedSlot;

/// The same shim with its lookup cached against the generation counter.
///
/// This is what a `@PatchableService` method does — the question this measures
/// is whether a top-level function should do it too.
///
/// Worth knowing that this comment was wrong for a while, and in the direction
/// that flatters the number. The generated service kept these fields on the
/// instance, so every new object started at generation -1 and paid a lookup
/// per method on its first call, while this models them as top-level statics.
/// They are static in the generated code now, so the two agree.
int _cachedShim(int a, int b) {
  if (_cachedGeneration != _generation) {
    _cachedGeneration = _generation;
    _cachedSlot = _slot('bench#add');
  }
  if (_cachedSlot != null) return 0;
  return _native(a, b);
}

/// The runtime helper a hand-written shim would call instead of being emitted.
///
/// This is the question codegen's existence turns on. If a developer can write
/// the marking by hand at a cost close to the generated form, the generator
/// becomes a convenience — go_router's model, where the builder is optional and
/// hand-written routes are equally correct. If it is far off, codegen earns its
/// place and the argument is over.
///
/// Never inlined for the same reason as [_naiveLookup]: in the real dispatcher
/// this is a static call into another library, so a closure handed to it
/// genuinely escapes. Left inlinable, escape analysis deletes the allocation and
/// the comparison measures nothing.
@pragma('vm:never-inline')
R _dispatch<A, B, R>(String id, A a, B b, R Function(A, B) original) {
  final slot = _slot(id);
  if (slot != null) {
    // The real helper boxes the arguments and crosses into the interpreter.
    // Neither measurement reaches this branch: with no patch the table is null,
    // and with another patch live the lookup misses.
    _dispatched++;
    return original(a, b);
  }
  return original(a, b);
}

int _dispatched = 0;

/// The same id [_guardedShim] asks for, and deliberately so: it is absent from
/// [_realisticSlots], so both shapes are measured on a miss. Naming the entry
/// that *is* present measures a dispatch instead, which is a different question.
const String _handId = 'bench#add';

/// Hand-written, passing the original as a top-level tear-off.
///
/// Dart canonicalises a tear-off of a top-level function, so this allocates
/// nothing per call — the shape worth measuring.
int _handShimTearoff(int a, int b) => _dispatch(_handId, a, b, _native);

/// Hand-written, passing a closure.
///
/// The form a developer writes without thinking about it, and the one that
/// allocates on every call whether or not a patch is live.
int _handShimClosure(int a, int b) =>
    _dispatch(_handId, a, b, (int x, int y) => _native(x, y));

/// A slot table the size a real app's would be.
///
/// Measuring against a one-entry map would flatter the lookup: hashing the key
/// costs the same either way, but collision behaviour and cache locality do
/// not, and an app with one patchable function is not the app anyone has.
Map<String, int> _realisticSlots() => <String, int>{
      for (var i = 0; i < 24; i++) 'package:app/service_$i.dart#method$i': i,
      // Present, but not the id the shim asks for. What matters here is the
      // cost of a *miss* while some other function is patched: that is what
      // every marked-but-unpatched function in the app pays.
      'package:app/pricing.dart#total': 99,
    };

List<_Result> _dispatchCosts() {
  stdout.writeln('Measuring dispatch overhead...');
  _slots = null;
  const iterations = 2000000;
  var sink = 0;

  final native = _timeNs(iterations, () => sink += _native(2, 3));
  final guarded = _timeNs(iterations, () => sink += _guardedShim(2, 3));
  final naive = _timeNs(iterations, () => sink += _naiveShim(2, 3));
  final handTearoff = _timeNs(iterations, () => sink += _handShimTearoff(2, 3));
  final handClosure = _timeNs(iterations, () => sink += _handShimClosure(2, 3));

  // Now with a patch live. Not a patch on *this* function — the interesting
  // case is the other marked functions in the app, which keep running their
  // original bodies but stop short-circuiting on the null table and start
  // paying a full string hash and map probe on every call.
  _slots = _realisticSlots();
  _generation++;
  final missGuarded = _timeNs(iterations, () => sink += _guardedShim(2, 3));
  final missCached = _timeNs(iterations, () => sink += _cachedShim(2, 3));
  final missHandTearoff =
      _timeNs(iterations, () => sink += _handShimTearoff(2, 3));
  final missHandClosure =
      _timeNs(iterations, () => sink += _handShimClosure(2, 3));
  _slots = null;
  _generation++;

  if (sink == 0) throw StateError('optimised away');
  // Neither hand-written measurement may have taken the dispatch branch: with
  // no patch the table is null, and with another patch live the lookup misses.
  // If it fired, the comparison is against the wrong path.
  if (_dispatched != 0) {
    throw StateError('the hand-written shim dispatched; it is measuring a '
        'patched call, not a marked one');
  }

  return <_Result>[
    _Result('unmarked call', native, 'ns'),
    _Result('marked call, no patch (generated shim)', guarded, 'ns',
        budget: 15),
    _Result('marked call, no patch (naive, for contrast)', naive, 'ns'),
    _Result('marked call, another patch live (map lookup)', missGuarded, 'ns'),
    _Result('hand-written, no patch (tear-off)', handTearoff, 'ns'),
    _Result('hand-written, no patch (closure)', handClosure, 'ns'),
    _Result(
        'hand-written, another patch live (tear-off)', missHandTearoff, 'ns'),
    _Result(
        'hand-written, another patch live (closure)', missHandClosure, 'ns'),
    _Result('marked call, another patch live (cached slot)', missCached, 'ns',
        budget: 15),
  ];
}

// --- crossing into the interpreter -------------------------------------------

const _source = r'''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

@RuntimeOverride('#trivial', version: '>=1.0.0')
int trivial(int a) { return a + 1; }

@RuntimeOverride('#loop', version: '>=1.0.0')
int loop(int a) {
  var total = 0;
  for (var i = 0; i < 1000; i++) { total = total + a + i; }
  return total;
}

@RuntimeOverride('#asyncTrivial', version: '>=1.0.0')
Future asyncTrivial(int a) async { return a + 1; }

@RuntimeOverride('#parse', version: '>=1.0.0')
String parse(Map response) {
  final status = response['status'];
  if (status != 'ok') { return 'no'; }
  final day = response['day'];
  if (day == null) { return 'no'; }
  return day.toString();
}
''';

/// A copy of `MarinefordJson.wrap`.
///
/// Copied rather than imported: the runtime package depends on Flutter and this
/// one deliberately does not, so a `flutter test` harness is not sitting between
/// the stopwatch and the code.
///
/// A copy is a thing that goes stale, and this one did. It kept measuring an
/// eager deep copy for a while after the library stopped doing that, which is
/// the worst way for a benchmark to be wrong — it reported a cost nobody paid
/// any more and the number looked plausible. Keep it in step with
/// `json_bridge.dart`; [_eagerWrap] is retained beside it as the baseline the
/// lazy form is argued against.
Object? _wrap(Object? value) {
  if (value == null) return const $null();
  if (value is String) return $String(value);
  if (value is int) return $int(value);
  if (value is double) return $double(value);
  if (value is bool) return $bool(value);
  if (value is List) return $List.wrap(_BenchLazyList(value));
  if (value is Map) return $Map.wrap(_BenchLazyMap(value));
  return value;
}

/// What [_wrap] used to do: copy the whole payload before the patch reads it.
///
/// Kept so the comparison can be measured rather than asserted. On a fifty-row
/// response this was ~31µs whatever the patch went on to touch; the lazy form
/// is ~0.4µs for a normaliser that reads two keys, ~9µs if it reads one field
/// of every row, and level with this one only if it reads every field of every
/// row — which is to say it never loses.
Object? _eagerWrap(Object? value) {
  if (value == null) return const $null();
  if (value is String) return $String(value);
  if (value is int) return $int(value);
  if (value is double) return $double(value);
  if (value is bool) return $bool(value);
  if (value is List) {
    return $List.wrap(<Object?>[for (final item in value) _eagerWrap(item)]);
  }
  if (value is Map) {
    return $Map.wrap(<Object?, Object?>{
      for (final e in value.entries) _eagerWrap(e.key): _eagerWrap(e.value),
    });
  }
  return value;
}

/// Copy of `_LazyMap` from `json_bridge.dart`. See [_wrap].
final class _BenchLazyMap extends MapBase<Object?, Object?> {
  _BenchLazyMap(this._plain);

  final Map<Object?, Object?> _plain;
  final Map<Object?, Object?> _wrapped = <Object?, Object?>{};
  Map<Object?, Object?>? _owned;

  static Object? _plainKey(Object? key) => key is $Value ? key.$reified : key;

  @override
  Object? operator [](Object? key) {
    final owned = _owned;
    if (owned != null) return owned[key];
    final plainKey = _plainKey(key);
    final existing = _wrapped[plainKey];
    if (existing != null) return existing;
    if (!_plain.containsKey(plainKey)) return null;
    return _wrapped[plainKey] = _wrap(_plain[plainKey]);
  }

  @override
  void operator []=(Object? key, Object? value) => _materialise()[key] = value;

  @override
  Object? remove(Object? key) => _materialise().remove(key);

  @override
  void clear() => _materialise().clear();

  @override
  Iterable<Object?> get keys => _owned?.keys ?? _plain.keys.map(_wrap);

  @override
  int get length => _owned?.length ?? _plain.length;

  @override
  bool containsKey(Object? key) =>
      _owned?.containsKey(key) ?? _plain.containsKey(_plainKey(key));

  Map<Object?, Object?> _materialise() => _owned ??= <Object?, Object?>{
        for (final entry in _plain.entries)
          _wrap(entry.key): _wrapped[entry.key] ?? _wrap(entry.value),
      };
}

/// Copy of `_LazyList` from `json_bridge.dart`. See [_wrap].
final class _BenchLazyList extends ListBase<Object?> {
  _BenchLazyList(this._plain);

  final List<Object?> _plain;
  final Map<int, Object?> _wrapped = <int, Object?>{};
  List<Object?>? _owned;

  @override
  int get length => _owned?.length ?? _plain.length;

  @override
  set length(int value) => _materialise().length = value;

  @override
  Object? operator [](int index) {
    // Not `_owned?[index] ?? ...`: once materialised, an element that is
    // legitimately null would fall through to the lazy branch and answer with
    // the pre-write value — or read out of range, if `length=` shrank the list.
    final owned = _owned;
    if (owned != null) return owned[index];
    return _wrapped[index] ??= _wrap(_plain[index]);
  }

  @override
  void operator []=(int index, Object? value) => _materialise()[index] = value;

  List<Object?> _materialise() => _owned ??= <Object?>[
        for (var i = 0; i < _plain.length; i++) _wrapped[i] ?? _wrap(_plain[i]),
      ];
}

/// A copy of `MarinefordJson.unwrap`.
Object? _unwrap(Object? value) {
  if (value is $Map) {
    return <Object?, Object?>{
      for (final e in value.$value.entries) _unwrap(e.key): _unwrap(e.value),
    };
  }
  if (value is $List) {
    return <Object?>[for (final item in value.$value) _unwrap(item)];
  }
  if (value is $Value) return _unwrap(value.$reified);
  if (value is Map) {
    return <Object?, Object?>{
      for (final e in value.entries) _unwrap(e.key): _unwrap(e.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _unwrap(item)];
  }
  return value;
}

/// The shape it had before: every container reached through `$reified`.
///
/// Kept as the comparison the change is argued from. `$reified` is recursive,
/// so this builds the whole plain structure and then walks the result and
/// builds it again.
Object? _unwrapViaReified(Object? value) {
  if (value is $Value) return _unwrapViaReified(value.$reified);
  if (value is Map) {
    return <Object?, Object?>{
      for (final e in value.entries)
        _unwrapViaReified(e.key): _unwrapViaReified(e.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _unwrapViaReified(item)];
  }
  return value;
}

Future<List<_Result>> _interpreterCosts() async {
  stdout.writeln('Measuring interpreter costs...');

  final compileWatch = Stopwatch()..start();
  final program = Compiler().compile(<String, Map<String, String>>{
    'bench': <String, String>{'main.dart': _source},
  });
  final bytes = program.write();
  final compileMs = compileWatch.elapsedMicroseconds / 1000;

  final activateWatch = Stopwatch()..start();
  final runtime = Runtime(bytes.buffer.asByteData())..loadGlobalOverrides();
  final version = Version.parse('1.0.0');
  final slots = <String, int>{};
  runtime.overrideMap.forEach((id, spec) {
    final constraint = spec.versionConstraint;
    if (constraint == null ||
        VersionConstraint.parse(constraint).allows(version)) {
      slots[id] = spec.offset;
    }
  });
  final activateMs = activateWatch.elapsedMicroseconds / 1000;

  Object? invoke(String id, Object? argument) {
    runtime.args.add(argument);
    try {
      return runtime.execute(slots[id]!);
    } finally {
      runtime.args.clear();
    }
  }

  // What running dispatch inside a forked zone costs. The zone is what catches
  // a Future the patch started and did not await; without it that failure
  // escapes the dispatcher entirely. It is only worth having if it disappears
  // against the crossing it wraps, so the number belongs here rather than in a
  // comment claiming it does.
  final guard = Zone.current.fork(
    specification: ZoneSpecification(
      handleUncaughtError: (Zone self, ZoneDelegate parent, Zone zone,
          Object error, StackTrace stackTrace) {},
    ),
  );
  final direct = _timeNs(30000, () => invoke('#trivial', 1));
  final zoned = _timeNs(30000, () => guard.run(() => invoke('#trivial', 1)));

  // The zone costs are measured on their own, not by differencing two
  // crossings. A crossing is ~2.6µs and its run-to-run spread is well above
  // 100ns, so subtracting one from another to recover a ~150ns figure reports
  // the noise and nothing else: the same pair gave +158ns and -515ns on
  // consecutive runs of this file.
  ZoneSpecification spec() => ZoneSpecification(
        handleUncaughtError: (Zone self, ZoneDelegate parent, Zone zone,
            Object error, StackTrace stackTrace) {},
      );
  var zoneSink = 0;
  final bare = _timeNs(2000000, () => zoneSink++);
  final entered = _timeNs(2000000, () => guard.run(() => zoneSink++));
  // What an async dispatch has to do, and cannot avoid: it cannot share the
  // zone above, because dart_eval reports a failure after an await as an
  // uncaught error in whichever zone the continuation captured — a shared one
  // catches it with no call to attribute it to, and the future the caller holds
  // never completes at all. One zone per call is what turns that back into an
  // answer, and this is what the answer costs.
  final forkedEach = _timeNs(500000, () {
    Zone.current.fork(specification: spec()).run(() => zoneSink++);
  });
  if (zoneSink == 0) throw StateError('optimised away');

  /// The shape `Patch.dispatchAsync` runs, without the Flutter dependency.
  Future<Object?> dispatchAsync(String id, Object? argument) {
    final settled = Completer<Object?>();
    final zone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (Zone self, ZoneDelegate parent, Zone inner,
            Object error, StackTrace stackTrace) {
          if (!settled.isCompleted) settled.complete(null);
        },
      ),
    );
    final outcome = zone.run(() => invoke(id, argument));
    if (outcome is Future<Object?>) {
      zone.run(() => outcome.then<void>(
            (Object? value) {
              if (!settled.isCompleted) settled.complete(value);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!settled.isCompleted) settled.complete(null);
            },
          ));
    } else {
      settled.complete(outcome);
    }
    return settled.future;
  }

  final asyncCrossing =
      await _timeNsAsync(5000, () => dispatchAsync('#asyncTrivial', 1));

  final trivial = _timeNs(30000, () => invoke('#trivial', 1));
  final loop = _timeNs(2000, () => invoke('#loop', 1));
  final payload =
      _wrap(jsonDecode('{"status":"ok","day":"Salı"}') as Map<String, dynamic>);
  final parse = _timeNs(20000, () => invoke('#parse', payload));

  // The loop body runs 1000 iterations, so subtracting the fixed crossing cost
  // and dividing gives the marginal per-iteration price.
  final perIteration = (loop - trivial) / 1000;

  return <_Result>[
    _Result('compile a small patch', compileMs, 'ms', budget: 200),
    _Result('activate (build runtime + slot table)', activateMs, 'ms',
        budget: 20),
    _Result('cross into the interpreter (fixed)', trivial / 1000, 'us',
        budget: 15),
    _Result('the same crossing inside the guard zone', zoned / 1000, 'us',
        budget: 20),
    _Result('entering the guard zone', entered - bare, 'ns', budget: 800),
    _Result('forking a zone per call, over entering one', forkedEach - entered,
        'ns',
        budget: 600),
    _Result(
        'async crossing (fork, suspend, resume)', asyncCrossing / 1000, 'us',
        budget: 25),
    _Result('async crossing over a synchronous one',
        (asyncCrossing - direct) / 1000, 'us',
        budget: 15),
    _Result('interpreted loop iteration', perIteration, 'ns', budget: 600),
    _Result('realistic JSON normaliser call', parse / 1000, 'us', budget: 25),
  ];
}

// --- the JSON bridge ---------------------------------------------------------

/// A payload of [fields] keys, [rows] of them if nested.
Object _payload({required int fields, int rows = 0}) {
  Map<String, Object?> row(int i) => <String, Object?>{
        for (var f = 0; f < fields; f++) 'field_$f': f.isEven ? 'value_$f' : f,
        'index': i,
      };
  if (rows == 0) return row(0);
  return <String, Object?>{
    'status': 'ok',
    'data': <Object?>[for (var i = 0; i < rows; i++) row(i)],
  };
}

/// A copy of `MarinefordJson.unwrapMap`.
///
/// This, not [_unwrap], is what a generated shim calls when the marked function
/// returns a map — which is the flagship case, a normaliser sitting on an HTTP
/// response. Measuring the inner helper instead of the entry point is how the
/// third pass over the data went unnoticed.
Map<String, dynamic>? _unwrapMap(Object? value) {
  final source = _mapView(value);
  if (source == null) return null;
  return <String, dynamic>{
    for (final entry in source.entries)
      _stringKey(entry.key): _unwrap(entry.value),
  };
}

/// A copy of `MarinefordJson.unwrapList`.
List<dynamic>? _unwrapList(Object? value) {
  final source = _listView(value);
  if (source == null) return null;
  return <dynamic>[for (final item in source) _unwrap(item)];
}

Map<Object?, Object?>? _mapView(Object? value) {
  if (value is $Map) return value.$value;
  if (value is Map) return value;
  final plain = _unwrap(value);
  return plain is Map ? plain : null;
}

List<Object?>? _listView(Object? value) {
  if (value is $List) return value.$value;
  if (value is List) return value;
  final plain = _unwrap(value);
  return plain is List ? plain : null;
}

String _stringKey(Object? key) {
  final plain = _unwrap(key);
  return plain is String ? plain : '$plain';
}

/// The shape the return path had before: build the map, then build it again.
///
/// Kept as the comparison the change is argued from.
Map<String, dynamic>? _unwrapMapTwice(Object? value) {
  final plain = _unwrap(value);
  if (plain is! Map) return null;
  return <String, dynamic>{
    for (final entry in plain.entries) '${entry.key}': entry.value,
  };
}

/// A read-only stand-in for the lazy view `wrap` could hand the interpreter.
///
/// Not a proposal — an instrument. It answers one question: how many key reads
/// a patch has to do before translating on every lookup costs more than
/// translating everything once up front.
///
/// The shape is forced by dart_eval. `$Map`'s runtime methods do not call
/// `operator []` on the `$Map`; they do `(target.$value as Map)[key]` with the
/// raw `$String` the interpreter pushed. So a lazy view cannot be a `$Map`
/// subclass — it has to be the map handed to `$Map.wrap`, doing the key
/// translation itself, which is why only `[]` is implemented here. A real one
/// would owe the whole `Map` interface.
/// Prices the deep copy that every marked call with a JSON payload pays.
///
/// The design wraps eagerly on the assumption that this is small next to the
/// ~2.6µs it costs to enter the interpreter at all. The numbers below say that
/// assumption holds for a small payload and stops holding for a realistic one:
/// 5 keys costs 421ns, 50 costs 3.3µs — the crossing itself — and 50 rows of 8
/// fields costs 35µs, thirteen crossings.
///
/// This is history now: the eager copy was replaced by the lazy views the
/// break-even below argued for, and [_eagerWrap] is kept only so the comparison
/// stays measurable rather than remembered.
///
/// The objection that held it back for a while was real and had to be answered
/// rather than waved off. dart_eval reaches past `$Map.operator []` into
/// `$value`, so a lazy view has to *be* the backing map and owe the whole `Map`
/// interface with key translation in every method — and one method that forgets
/// returns wrong data silently, which is the failure the deep copy made
/// impossible by construction. What answered it was `MapBase`, which derives
/// the whole interface from four methods, plus tests that pin the behaviour a
/// view makes newly possible: writing through it must copy, because the
/// interpreter now holds the caller's own structure.
///
/// The payoff: a normaliser reading two keys of a fifty-row response went from
/// ~31µs to ~0.4µs. Reading one field of every row is ~9µs. Reading every field
/// of every row is level with the eager copy — so there is no shape that lost.
///
/// Measured at the entry points the generator actually emits, in both
/// directions, because the return path is where the cost concentrates.
List<_Result> _jsonBridgeCosts() {
  stdout.writeln('Measuring the JSON bridge...');

  final small = _payload(fields: 5);
  final wide = _payload(fields: 50);
  final huge = _payload(fields: 100);
  final nested = _payload(fields: 8, rows: 50);

  final wrapSmall = _timeNs(200000, () => _wrap(small));
  final wrapWide = _timeNs(50000, () => _wrap(wide));
  final wrapHuge = _timeNs(20000, () => _wrap(huge));
  final wrapNested = _timeNs(5000, () => _wrap(nested));

  final wrappedWide = _wrap(wide);
  final wrappedHuge = _wrap(huge);
  final wrappedNested = _wrap(nested);

  final unwrapWide = _timeNs(50000, () => _unwrapMap(wrappedWide));
  final unwrapHuge = _timeNs(20000, () => _unwrapMap(wrappedHuge));
  final unwrapNested = _timeNs(5000, () => _unwrapMap(wrappedNested));

  final wrappedList = _wrap(<Object?>[
    for (var i = 0; i < 50; i++) _payload(fields: 8),
  ]);
  final unwrapList = _timeNs(5000, () => _unwrapList(wrappedList));

  final unwrapOld = _timeNs(5000, () => _unwrapViaReified(wrappedNested));
  final unwrapTwiceWide = _timeNs(50000, () => _unwrapMapTwice(wrappedWide));

  // What a lazy view would cost per key read, against what wrapping the whole
  // map costs once. The ratio is the break-even: below it lazy wins, above it
  // the eager copy does.
  final flat = wide as Map<String, Object?>;
  final probe = $String('field_7');
  final lazy = $Map.wrap(_BenchLazyMap(flat));
  final eager = _eagerWrap(flat) as $Map;

  // Both probes must actually find something. A lookup that misses is the
  // failure this whole file exists to prevent — $String keys against plain
  // String keys return null and throw nothing — and it would also be a much
  // faster "measurement" than the real thing, so it has to be ruled out before
  // the numbers mean anything rather than after.
  if ((lazy.$value as Map)[probe] == null) {
    throw StateError('the lazy view missed; it is measuring a failed lookup');
  }
  if (eager.$value[probe] == null) {
    throw StateError('the wrapped map missed; it is measuring a failed lookup');
  }

  var sink = 0;
  final lazyRead = _timeNs(500000, () {
    // Exactly what the interpreter's index op does: reach through $value.
    if ((lazy.$value as Map)[probe] != null) sink++;
  });
  final eagerRead = _timeNs(500000, () {
    if (eager.$value[probe] != null) sink++;
  });
  if (sink < 1000000) throw StateError('optimised away');
  final breakEven = wrapWide / (lazyRead - eagerRead);

  return <_Result>[
    _Result('wrap a 5-key map', wrapSmall, 'ns', budget: 3000),
    _Result('wrap a 50-key map', wrapWide / 1000, 'us', budget: 20),
    _Result('wrap a 100-key map', wrapHuge / 1000, 'us', budget: 40),
    _Result('wrap 50 rows x 8 fields', wrapNested / 1000, 'us', budget: 200),
    _Result('unwrapMap a 50-key map', unwrapWide / 1000, 'us', budget: 20),
    _Result('unwrapMap the same in two passes (for contrast)',
        unwrapTwiceWide / 1000, 'us'),
    _Result('unwrapMap a 100-key map', unwrapHuge / 1000, 'us', budget: 40),
    _Result('unwrapMap 50 rows x 8 fields', unwrapNested / 1000, 'us',
        budget: 200),
    _Result('unwrapList 50 rows x 8 fields', unwrapList / 1000, 'us',
        budget: 200),
    _Result(
        r'unwrap the same via $reified (for contrast)', unwrapOld / 1000, 'us'),
    _Result('key read, lazy view', lazyRead, 'ns'),
    _Result('key read, eagerly wrapped', eagerRead, 'ns'),
    _Result('lazy view break-even, 50-key map', breakEven, 'reads'),
  ];
}

// --- payload size ------------------------------------------------------------

List<_Result> _patchSizes() {
  stdout.writeln('Measuring patch size...');
  final evc = _benchBytecode();
  final packed = gzip.encode(evc);

  return <_Result>[
    _Result('bytecode', evc.length / 1024, 'KB'),
    _Result('packed payload', packed.length / 1024, 'KB', budget: 32),
    _Result('compression ratio', evc.length / packed.length, 'x'),
  ];
}

/// What the launch path actually pays to trust a patch.
///
/// The README says activating a patch at startup costs about a millisecond, and
/// that claim rests on this: `MarinefordClient.start` verifies a signature on
/// the UI isolate before it will run anything. `cryptography` resolves `Ed25519`
/// to its pure Dart implementation unless `cryptography_flutter` is present to
/// hand it to the platform, and this repository does not depend on that — so
/// what is measured here is what ships.
///
/// Two signatures per launch, not one: the manifest and the patch container.
/// Both are on the path before the first frame.
///
/// The message size barely matters — Ed25519 hashes the message and then does
/// fixed-cost curve arithmetic — so a small and a large payload are measured
/// together to show that, rather than leaving a reader to wonder whether the
/// number scales with the patch.
Future<List<_Result>> _signatureCosts() async {
  stdout.writeln('Measuring signature verification...');

  final signer = await PatchSigner.generate();
  final verifier = PatchVerifier.fromBase64(signer.publicKeyBase64);

  final manifest = Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
    'schema': 1,
    'appId': 'com.example.app',
    'channel': 'prod',
    'sequence': 12,
    'generatedAt': '2026-01-01T00:00:00.000Z',
    'patches': <Object?>[
      for (var i = 0; i < 8; i++)
        <String, Object?>{
          'number': i,
          'url': '$i.mfp',
          'size': 3600,
          'sha256': 'a' * 64,
          'abi': 'sha256:${'b' * 64}',
          'runtime': '>=1.0.0 <2.0.0',
          'rollout': 1.0,
        },
    ],
    'revoked': <int>[],
  })));
  final container = Uint8List.fromList(gzip.encode(_benchBytecode()));

  final manifestSignature = await signer.sign(manifest);
  final containerSignature = await signer.sign(container);

  // Both must actually verify. A benchmark that measures a rejection measures
  // the early-exit path, which is much cheaper and would flatter the number.
  if (!await verifier.verify(manifest, manifestSignature) ||
      !await verifier.verify(container, containerSignature)) {
    throw StateError('the benchmark is measuring a failed verification');
  }

  final manifestNs = await _timeNsAsync(
      200, () => verifier.verify(manifest, manifestSignature));
  final containerNs = await _timeNsAsync(
      200, () => verifier.verify(container, containerSignature));

  return <_Result>[
    _Result(
        'verify a manifest (${manifest.length} B)', manifestNs / 1000000, 'ms',
        budget: 8),
    _Result('verify a container (${(container.length / 1024).round()} KB)',
        containerNs / 1000000, 'ms',
        budget: 8),
    _Result('both, as a launch pays them', (manifestNs + containerNs) / 1000000,
        'ms',
        budget: 16),
  ];
}

/// The benchmark patch, compiled once.
///
/// Two sections want these bytes — one to sign, one to measure packed — and
/// compiling twice cost the run a second compile of the same source. That is
/// 2ms under AOT and 246ms under the JIT by this file's own header, which is
/// the mode the header tells people to use for a quick look.
Uint8List? _benchBytecodeCache;

Uint8List _benchBytecode() =>
    _benchBytecodeCache ??= Compiler().compile(<String, Map<String, String>>{
      'bench': <String, String>{'main.dart': _source},
    }).write();
