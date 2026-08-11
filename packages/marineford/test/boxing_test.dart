import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marineford/marineford.dart';
import 'package:pub_semver/pub_semver.dart';

/// Pins down which argument forms dart_eval accepts for which parameter types.
///
/// This is not testing our code so much as testing an assumption our code
/// generator is built on. If dart_eval ever changes how it boxes parameters,
/// every generated shim silently starts passing the wrong thing — and the
/// symptom is a patch that quietly falls back, not an error. Better to find out
/// here.
void main() {
  late Runtime runtime;

  setUpAll(() {
    // Every function here uses its parameter. That is load-bearing: with an
    // unused parameter dart_eval never emits the box/unbox opcode, every form
    // appears to work, and the test proves nothing.
    const source = r'''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}
@RuntimeOverride('#int', version: '>=1.0.0') String fi(int v) { return 'ok:$v'; }
@RuntimeOverride('#double', version: '>=1.0.0') String fd(double v) { return 'ok:$v'; }
@RuntimeOverride('#bool', version: '>=1.0.0') String fb(bool v) { return 'ok:$v'; }
@RuntimeOverride('#intN', version: '>=1.0.0') String fin(int? v) { return 'ok:$v'; }
@RuntimeOverride('#doubleN', version: '>=1.0.0') String fdn(double? v) { return 'ok:$v'; }
@RuntimeOverride('#boolN', version: '>=1.0.0') String fbn(bool? v) { return 'ok:$v'; }
@RuntimeOverride('#string', version: '>=1.0.0') String fs(String v) { return 'ok:$v'; }
@RuntimeOverride('#stringN', version: '>=1.0.0') String fsn(String? v) { return 'ok:$v'; }
@RuntimeOverride('#num', version: '>=1.0.0') String fn(num v) { return 'ok:$v'; }
@RuntimeOverride('#object', version: '>=1.0.0') String fo(Object v) { return 'ok:$v'; }
''';
    final program = Compiler().compile({
      'p': {'main.dart': source},
    });
    runtime = Runtime(program.write().buffer.asByteData())
      ..loadGlobalOverrides();
  });

  setUp(() {
    Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.0.0')),
        failureThreshold: 9999);
  });

  tearDown(Patch.resetForTesting);

  bool accepts(String id, Object? argument) =>
      Patch.invoke1(Patch.slot(id)!, argument) != null;

  group('non-nullable int, double and bool are unboxed', () {
    test('raw values are accepted', () {
      expect(accepts('#int', 42), isTrue);
      expect(accepts('#double', 1.5), isTrue);
      expect(accepts('#bool', true), isTrue);
    });

    test('wrapped values are rejected', () {
      expect(accepts('#int', MarinefordJson.wrap(42)), isFalse);
      expect(accepts('#double', MarinefordJson.wrap(1.5)), isFalse);
      expect(accepts('#bool', MarinefordJson.wrap(true)), isFalse);
    });
  });

  group('making a primitive nullable flips the rule', () {
    test('wrapped values are accepted', () {
      expect(accepts('#intN', MarinefordJson.wrap(42)), isTrue);
      expect(accepts('#doubleN', MarinefordJson.wrap(1.5)), isTrue);
      expect(accepts('#boolN', MarinefordJson.wrap(true)), isTrue);
    });

    test('raw values are rejected', () {
      // The nastiest case in the table: `int` and `int?` need opposite
      // treatment, so adding a `?` to a patch parameter breaks the shim unless
      // the generator re-reads the type.
      expect(accepts('#intN', 42), isFalse);
      expect(accepts('#doubleN', 1.5), isFalse);
      expect(accepts('#boolN', true), isFalse);
    });
  });

  group('everything else is boxed', () {
    test('wrapped values are accepted', () {
      expect(accepts('#string', MarinefordJson.wrap('x')), isTrue);
      expect(accepts('#stringN', MarinefordJson.wrap('x')), isTrue);
      expect(accepts('#num', MarinefordJson.wrap(7)), isTrue);
      expect(accepts('#object', MarinefordJson.wrap('x')), isTrue);
    });

    test('raw values are rejected', () {
      expect(accepts('#string', 'x'), isFalse);
      expect(accepts('#num', 7), isFalse);
      expect(accepts('#object', 'x'), isFalse);
    });
  });

  group('MarinefordJson round trip', () {
    test('nested maps and lists survive both directions', () {
      final original = <String, dynamic>{
        'status': 'ok',
        'count': 3,
        'ratio': 0.5,
        'flag': true,
        'nothing': null,
        'days': <dynamic>['Pazartesi', 'Salı'],
        'data': <String, dynamic>{
          'nested': <dynamic>[
            1,
            <String, dynamic>{'deep': 'yes'}
          ],
        },
      };
      expect(MarinefordJson.unwrap(MarinefordJson.wrap(original)), original);
    });

    test('a plain container holding interpreter values still unwraps', () {
      // Reachable when a patch builds a structure out of pieces that did not
      // all come from the interpreter. `unwrap` descends into $Map and $List
      // directly now instead of going through $reified, so the branch that
      // catches a *plain* container full of $Values is the one that could
      // quietly stop firing.
      final mixed = <String, dynamic>{
        'wrapped': MarinefordJson.wrap('value'),
        'list': <dynamic>[MarinefordJson.wrap(1), MarinefordJson.wrap(null)],
      };
      expect(MarinefordJson.unwrap(mixed), <String, dynamic>{
        'wrapped': 'value',
        'list': <dynamic>[1, null],
      });
    });

    test('a bridged object nested inside survives unwrapping', () {
      // Not JSON, so `wrap` leaves it alone; `unwrap` has to leave it alone
      // too, rather than mangling it on the way back out.
      final sentinel = Object();
      final round = MarinefordJson.unwrap(MarinefordJson.wrap(<String, dynamic>{
        'plain': 1,
        'opaque': sentinel,
      }));
      expect(round, isA<Map<Object?, Object?>>());
      expect(identical((round! as Map)['opaque'], sentinel), isTrue);
    });

    test('unwrapMap rejects a non-map so the caller can fall back', () {
      expect(MarinefordJson.unwrapMap(MarinefordJson.wrap(<dynamic>[1, 2])),
          isNull);
      expect(MarinefordJson.unwrapMap(MarinefordJson.wrap('nope')), isNull);
      expect(
          MarinefordJson.unwrapMap(
              MarinefordJson.wrap(<String, dynamic>{'a': 1})),
          <String, dynamic>{'a': 1});
    });

    test('unwrapList rejects a non-list', () {
      expect(
          MarinefordJson.unwrapList(MarinefordJson.wrap(<String, dynamic>{})),
          isNull);
      expect(MarinefordJson.unwrapList(MarinefordJson.wrap(<dynamic>[1, 2])),
          [1, 2]);
    });

    test('non-JSON values pass through wrap untouched', () {
      final sentinel = Object();
      expect(identical(MarinefordJson.wrap(sentinel), sentinel), isTrue);
    });
  });

  group('the return path builds the result once', () {
    // unwrapMap and unwrapList used to call unwrap and then rebuild what it
    // returned. Reaching into the interpreter's own container instead is what
    // removed the second pass, and it means these entry points no longer share
    // a code path with unwrap — so every shape has to be checked against them
    // directly rather than assumed to follow from the unwrap tests above.

    test('a deeply nested map comes back whole', () {
      final original = <String, dynamic>{
        'status': 'ok',
        'rows': <dynamic>[
          <String, dynamic>{
            'id': 1,
            'tags': <dynamic>['a', 'b'],
          },
          <String, dynamic>{
            'id': 2,
            'nested': <String, dynamic>{'deep': true},
          },
        ],
        'nothing': null,
      };
      expect(MarinefordJson.unwrapMap(MarinefordJson.wrap(original)), original);
    });

    test('a plain Dart map full of interpreter values still converts', () {
      // The fast path returns the caller's map untouched, so its values are
      // still $Values and have to be unwrapped one by one on the way out.
      expect(
        MarinefordJson.unwrapMap(<Object?, Object?>{
          'a': MarinefordJson.wrap(1),
          'b': MarinefordJson.wrap(<dynamic>['x']),
        }),
        <String, dynamic>{
          'a': 1,
          'b': <dynamic>['x'],
        },
      );
    });

    test('a non-string key becomes one rather than a cast error', () {
      // Not valid JSON, but a patch can produce it, and the alternative is a
      // failure thrown from somewhere the app author cannot see.
      final result = MarinefordJson.unwrapMap(
          MarinefordJson.wrap(<Object?, Object?>{1: 'one', true: 'yes'}));
      expect(result, <String, dynamic>{'1': 'one', 'true': 'yes'});
    });

    test('unwrapList converts the elements it hands back', () {
      // The old version returned unwrap's list as-is. The new one builds the
      // list itself, so it owns the element conversion too.
      expect(
        MarinefordJson.unwrapList(MarinefordJson.wrap(<dynamic>[
          <String, dynamic>{'a': 1},
          <dynamic>[2],
          null,
        ])),
        <dynamic>[
          <String, dynamic>{'a': 1},
          <dynamic>[2],
          null,
        ],
      );
      expect(
        MarinefordJson.unwrapList(<Object?>[MarinefordJson.wrap('x')]),
        <dynamic>['x'],
      );
    });

    test('a bridged object survives the return path too', () {
      final sentinel = Object();
      final result = MarinefordJson.unwrapMap(
          MarinefordJson.wrap(<String, dynamic>{'opaque': sentinel}));
      expect(identical(result!['opaque'], sentinel), isTrue);
    });
  });
}
