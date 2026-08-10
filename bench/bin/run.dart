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

List<_Result> _dispatchCosts() {
  stdout.writeln('Measuring dispatch overhead...');
  _slots = null;
  const iterations = 2000000;
  var sink = 0;

  final native = _timeNs(iterations, () => sink += _native(2, 3));
  final guarded = _timeNs(iterations, () => sink += _guardedShim(2, 3));
  final naive = _timeNs(iterations, () => sink += _naiveShim(2, 3));
  if (sink == 0) throw StateError('optimised away');

  return <_Result>[
    _Result('unmarked call', native, 'ns'),
    _Result('marked call, no patch (generated shim)', guarded, 'ns',
        budget: 15),
    _Result('marked call, no patch (naive, for contrast)', naive, 'ns'),
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

Object? _wrap(Object? value) {
  if (value == null) return $null();
  if (value is String) return $String(value);
  if (value is int) return $int(value);
  if (value is bool) return $bool(value);
  if (value is Map) {
    return $Map.wrap(<Object?, Object?>{
      for (final e in value.entries) _wrap(e.key): _wrap(e.value),
    });
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
    _Result('interpreted loop iteration', perIteration, 'ns', budget: 600),
    _Result('realistic JSON normaliser call', parse / 1000, 'us', budget: 25),
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
