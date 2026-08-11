import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:pub_semver/pub_semver.dart';

/// Reproduces the numbers marineford's design is argued from.
///
/// Every performance claim in the README and the plan comes from here. They are
/// committed and run rather than remembered, because the design rests on a
/// handful of specific costs — 2.4ns for a marked call with no patch, ~2.5µs to
/// cross into the interpreter, ~107ns per interpreted loop iteration — and each
/// one justifies a decision that would be wrong if the number moved.
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

void main(List<String> args) {
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
  results.addAll(_interpreterCosts());
  results.addAll(_jsonBridgeCosts());
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
/// This is what a `@PatchableService` method already does — the question this
/// measures is whether a top-level function should do it too.
int _cachedShim(int a, int b) {
  if (_cachedGeneration != _generation) {
    _cachedGeneration = _generation;
    _cachedSlot = _slot('bench#add');
  }
  if (_cachedSlot != null) return 0;
  return _native(a, b);
}

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

  // Now with a patch live. Not a patch on *this* function — the interesting
  // case is the other marked functions in the app, which keep running their
  // original bodies but stop short-circuiting on the null table and start
  // paying a full string hash and map probe on every call.
  _slots = _realisticSlots();
  _generation++;
  final missGuarded = _timeNs(iterations, () => sink += _guardedShim(2, 3));
  final missCached = _timeNs(iterations, () => sink += _cachedShim(2, 3));
  _slots = null;
  _generation++;

  if (sink == 0) throw StateError('optimised away');

  return <_Result>[
    _Result('unmarked call', native, 'ns'),
    _Result('marked call, no patch (generated shim)', guarded, 'ns',
        budget: 15),
    _Result('marked call, no patch (naive, for contrast)', naive, 'ns'),
    _Result('marked call, another patch live (map lookup)', missGuarded, 'ns'),
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
/// the stopwatch and the code. Keep it in step with `json_bridge.dart`.
Object? _wrap(Object? value) {
  if (value == null) return $null();
  if (value is String) return $String(value);
  if (value is int) return $int(value);
  if (value is double) return $double(value);
  if (value is bool) return $bool(value);
  if (value is List) {
    return $List.wrap(<Object?>[for (final item in value) _wrap(item)]);
  }
  if (value is Map) {
    return $Map.wrap(<Object?, Object?>{
      for (final e in value.entries) _wrap(e.key): _wrap(e.value),
    });
  }
  return value;
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

List<_Result> _interpreterCosts() {
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
    _Result('zone guard overhead per crossing', zoned - direct, 'ns',
        budget: 800),
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
final class _LazyView extends MapBase<Object?, Object?> {
  _LazyView(this._source);

  final Map<String, Object?> _source;

  @override
  Object? operator [](Object? key) {
    final plain = key is $String ? key.$value : key;
    return _wrap(_source[plain]);
  }

  @override
  void operator []=(Object? key, Object? value) => throw UnimplementedError();
  @override
  void clear() => throw UnimplementedError();
  @override
  Iterable<Object?> get keys => _source.keys.map(_wrap);
  @override
  Object? remove(Object? key) => throw UnimplementedError();
}

/// Prices the deep copy that every marked call with a JSON payload pays.
///
/// The design assumes this is small next to the ~2.6µs it costs to enter the
/// interpreter at all — which is the argument for wrapping eagerly instead of
/// building a lazy view over the original map. Assumptions like that are worth
/// a number, because the conclusion flips if a payload is big enough.
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
  final lazy = $Map.wrap(_LazyView(flat));
  final eager = _wrap(flat) as $Map;

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
  final program = Compiler().compile(<String, Map<String, String>>{
    'bench': <String, String>{'main.dart': _source},
  });
  final evc = program.write();
  final packed = gzip.encode(evc);

  return <_Result>[
    _Result('bytecode', evc.length / 1024, 'KB'),
    _Result('packed payload', packed.length / 1024, 'KB', budget: 32),
    _Result('compression ratio', evc.length / packed.length, 'x'),
  ];
}
