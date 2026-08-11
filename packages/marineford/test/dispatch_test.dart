import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marineford/marineford.dart';
import 'package:pub_semver/pub_semver.dart';

const _header = '''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}
''';

Runtime compile(String source) {
  final program = Compiler().compile({
    'p': {'main.dart': '$_header\n$source'},
  });
  final bytes = program.write();
  return Runtime(bytes.buffer.asByteData());
}

void main() {
  tearDown(Patch.resetForTesting);
  _gaps();

  group('no patch active', () {
    test('slot lookups return null', () {
      expect(Patch.isActive, isFalse);
      expect(Patch.slot('anything'), isNull);
    });

    test('invoking without a runtime returns null rather than throwing', () {
      expect(Patch.invoke0(0), isNull);
      expect(Patch.invoke1(0, 1), isNull);
      expect(Patch.invoke2(0, 1, 2), isNull);
      expect(Patch.invoke3(0, 1, 2, 3), isNull);
      expect(Patch.invokeN(0, [1, 2, 3, 4]), isNull);
    });
  });

  group('dispatch', () {
    late Runtime runtime;

    setUp(() {
      runtime = compile('''
@RuntimeOverride('#add', version: '>=1.0.0')
int add(int a, int b) { return a + b; }

@RuntimeOverride('#greet', version: '>=1.0.0')
String greet(String name) { return 'merhaba \$name'; }

@RuntimeOverride('#nothing', version: '>=1.0.0')
String? nothing() { return null; }

@RuntimeOverride('#boom', version: '>=1.0.0')
int boom(int a) { return a ~/ 0; }

@RuntimeOverride('#old', version: '<1.0.0')
int old(int a) { return 0; }
''');
      runtime.loadGlobalOverrides();
      Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.4.0')));
    });

    test('a patched function runs and returns its value', () {
      final slot = Patch.slot('#add')!;
      expect(Patch.invoke2(slot, 20, 22), 42);
    });

    test('string results come back unwrapped', () {
      // A String parameter is boxed by dart_eval, unlike a non-nullable int.
      expect(Patch.invoke1(Patch.slot('#greet')!, MarinefordJson.wrap('dünya')),
          'merhaba dünya');
    });

    test('a patch returning null is distinguishable from no patch', () {
      // Both would be `null` without the sentinel, and the caller could not
      // tell "the patch said null" from "run the original".
      final result = Patch.invoke0(Patch.slot('#nothing')!);
      expect(result, isNotNull);
      expect(identical(result, patchedNull), isTrue);
      expect(Patch.slot('#missing'), isNull);
    });

    test('version constraints are applied once, at activation', () {
      expect(Patch.slot('#add'), isNotNull);
      expect(Patch.slot('#old'), isNull,
          reason: 'an override constrained to <1.0.0 must not be in the table '
              'for a 1.4.0 app');
    });

    test('deactivating restores the original behaviour', () {
      expect(Patch.isActive, isTrue);
      Patch.deactivate();
      expect(Patch.isActive, isFalse);
      expect(Patch.slot('#add'), isNull);
    });

    test('generation changes on activate and deactivate', () {
      final before = Patch.generation;
      Patch.deactivate();
      expect(Patch.generation, greaterThan(before));
    });

    test('generation is listenable', () {
      var notifications = 0;
      void listener() => notifications++;
      Patch.generationListenable.addListener(listener);
      addTearDown(() => Patch.generationListenable.removeListener(listener));
      Patch.deactivate();
      expect(notifications, 1);
    });
  });

  group('failure isolation', () {
    late Runtime runtime;
    late List<String> failures;

    setUp(() {
      runtime = compile('''
@RuntimeOverride('#boom', version: '>=1.0.0')
int boom(int a) { return a ~/ 0; }

@RuntimeOverride('#fine', version: '>=1.0.0')
int fine(int a) { return a + 1; }
''');
      runtime.loadGlobalOverrides();
      failures = <String>[];
      Patch.activate(
        runtime,
        resolveSlots(runtime, Version.parse('1.0.0')),
        onFailure: (id, error, _) => failures.add(id),
        failureThreshold: 3,
      );
    });

    test('a throwing patch returns null so the caller falls back', () {
      expect(Patch.invoke1(Patch.slot('#boom')!, 5), isNull);
      expect(failures, ['']);
    });

    test('the failing id is reported when the shim passes one', () {
      Patch.invoke1(Patch.slot('#boom')!, 5, '#boom');
      expect(failures, ['#boom']);
    });

    test('one bad function does not poison the others', () {
      Patch.invoke1(Patch.slot('#boom')!, 5, '#boom');
      expect(Patch.invoke1(Patch.slot('#fine')!, 41), 42,
          reason: 'a failure must not leave the interpreter unusable');
    });

    test('arguments are cleaned up after a failure', () {
      for (var i = 0; i < 2; i++) {
        Patch.invoke1(Patch.slot('#boom')!, 5, '#boom');
      }
      // If the failed call had left its argument on the stack, this one would
      // read the wrong value.
      expect(Patch.invoke1(Patch.slot('#fine')!, 100), 101);
    });

    test('repeated failures deactivate the patch entirely', () {
      for (var i = 0; i < 3; i++) {
        Patch.invoke1(Patch.slot('#boom')!, 5, '#boom');
      }
      expect(Patch.isActive, isFalse,
          reason: 'a patch that keeps throwing should stop being used');
      expect(failures.length, 3);
    });
  });

  group('re-entrancy', () {
    test('a patched function calling another patched function works', () {
      // The case that corrupts the interpreter if the dispatcher naively calls
      // Runtime.execute() again instead of bridgeCall(). Reproduced against
      // dart_eval directly before this dispatcher was written: execute() dies
      // with a RangeError on the opcode array.
      final runtime = compile('''
@RuntimeOverride('#outer', version: '>=1.0.0')
int outer(int a) { return inner(a) + 1000; }

@RuntimeOverride('#inner', version: '>=1.0.0')
int inner(int a) { return a * 2; }
''');
      runtime.loadGlobalOverrides();
      Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.0.0')));

      expect(Patch.invoke1(Patch.slot('#outer')!, 21), 1042);
      // And again, to prove the first call left no residue.
      expect(Patch.invoke1(Patch.slot('#outer')!, 21), 1042);
      expect(Patch.invoke1(Patch.slot('#inner')!, 21), 42);
    });
  });

  group('resolveSlots', () {
    test('an unparseable constraint drops only that override', () {
      final runtime = compile('''
@RuntimeOverride('#good', version: '>=1.0.0')
int good() { return 1; }

@RuntimeOverride('#bad', version: 'not a constraint')
int bad() { return 2; }
''');
      runtime.loadGlobalOverrides();
      final slots = resolveSlots(runtime, Version.parse('1.0.0'));
      expect(slots.keys, contains('#good'));
      expect(slots.keys, isNot(contains('#bad')),
          reason: 'one bad annotation should cost one function, not the patch');
    });
  });

  group('the dispatch table is immutable once active', () {
    test('callers cannot mutate it', () {
      final runtime = compile('''
@RuntimeOverride('#a', version: '>=1.0.0')
int a() { return 1; }
''');
      runtime.loadGlobalOverrides();
      final slots = resolveSlots(runtime, Version.parse('1.0.0'));
      Patch.activate(runtime, slots);
      slots['#injected'] = 0;
      expect(Patch.slot('#injected'), isNull);
    });
  });
}

/// Gaps the review named.
void _gaps() {
  tearDown(Patch.resetForTesting);

  Runtime compiled(String source) {
    final program = Compiler().compile(<String, Map<String, String>>{
      'p': <String, String>{'main.dart': '$_header\n$source'},
    });
    return Runtime(program.write().buffer.asByteData())..loadGlobalOverrides();
  }

  group('failure counting is consecutive, not cumulative', () {
    late Runtime runtime;

    setUp(() {
      runtime = compiled('''
@RuntimeOverride('#boom', version: '>=1.0.0')
int boom(int a) { return a ~/ 0; }

@RuntimeOverride('#fine', version: '>=1.0.0')
int fine(int a) { return a + 1; }
''');
      Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.0.0')),
          failureThreshold: 3);
    });

    test('a success resets the count', () {
      // Cumulative counting abandons a patch that is right 99.99% of the time
      // because it threw on a rare input a few times over a long session.
      for (var i = 0; i < 2; i++) {
        Patch.invoke1(Patch.slot('#boom')!, 5, '#boom');
      }
      expect(Patch.failureCount, 2);
      Patch.invoke1(Patch.slot('#fine')!, 1);
      expect(Patch.failureCount, 0);
      expect(Patch.isActive, isTrue);
    });

    test('interleaved failures never reach the threshold', () {
      for (var i = 0; i < 10; i++) {
        Patch.invoke1(Patch.slot('#boom')!, 5, '#boom');
        Patch.invoke1(Patch.slot('#fine')!, 1);
      }
      expect(Patch.isActive, isTrue);
    });

    test('consecutive failures still deactivate', () {
      for (var i = 0; i < 3; i++) {
        Patch.invoke1(Patch.slot('#boom')!, 5, '#boom');
      }
      expect(Patch.isActive, isFalse);
    });
  });

  group('deactivating mid-call leaves nothing behind', () {
    test('the depth does not go negative and arguments are cleared', () {
      // deactivate() resets the depth while _run's finally is still on the
      // stack. An unclamped decrement took it to -1, after which the "am I the
      // outermost frame" test never fired again and arguments accumulated
      // forever.
      final runtime = compiled('''
@RuntimeOverride('#boom', version: '>=1.0.0')
int boom(int a) { return a ~/ 0; }

@RuntimeOverride('#fine', version: '>=1.0.0')
int fine(int a) { return a + 1; }
''');
      Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.0.0')),
          failureThreshold: 1);

      final slot = Patch.slot('#boom')!;
      Patch.invoke1(slot, 5, '#boom');
      expect(Patch.isActive, isFalse, reason: 'threshold of one');
      expect(runtime.args, isEmpty,
          reason: 'the failed call must not leave its argument behind');

      // Re-activating has to produce a usable dispatcher, not one stuck at a
      // negative depth.
      Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.0.0')));
      expect(Patch.invoke1(Patch.slot('#fine')!, 41), 42);
      expect(runtime.args, isEmpty);
    });

    test('a nested throw still leaves the argument stack clean', () {
      final runtime = compiled('''
@RuntimeOverride('#outer', version: '>=1.0.0')
int outer(int a) { return inner(a) + 1; }

@RuntimeOverride('#inner', version: '>=1.0.0')
int inner(int a) { return a ~/ 0; }
''');
      Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.0.0')),
          failureThreshold: 99);

      expect(Patch.invoke1(Patch.slot('#outer')!, 5, '#outer'), isNull);
      expect(runtime.args, isEmpty);
      expect(Patch.invoke1(Patch.slot('#outer')!, 5, '#outer'), isNull,
          reason: 'a second attempt must behave the same as the first');
    });
  });

  test('a throwing failure handler does not escape', () {
    final runtime = compiled('''
@RuntimeOverride('#boom', version: '>=1.0.0')
int boom(int a) { return a ~/ 0; }
''');
    Patch.activate(
      runtime,
      resolveSlots(runtime, Version.parse('1.0.0')),
      onFailure: (_, __, ___) => throw StateError('handler is broken'),
    );
    expect(() => Patch.invoke1(Patch.slot('#boom')!, 5), returnsNormally);
  });
}
