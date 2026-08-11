import 'dart:convert';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:logging/logging.dart';
import 'package:marineford_gen/builder.dart';
import 'package:marineford_gen/src/shim_generator.dart'
    show abiMarker, kShimContractVersion;
import 'package:test/test.dart';

/// Writes what a shim's marker block looks like on disk.
///
/// The aggregator reads generated files rather than element models, so its
/// input really is text of this shape — reproducing it here is the only honest
/// way to test what it does with a file it did not just write itself.
String shim({
  required String id,
  List<String> params = const <String>['int'],
  String returns = 'String',
  int contract = kShimContractVersion,
}) =>
    <String>[
      "part of 'pricing.dart';",
      '// $abiMarker${jsonEncode(<String, Object?>{
            'id': id,
            'params': params,
            'returns': returns,
            'origin': 'lib/pricing.dart',
          })}',
      '// $abiMarker{"contract":$contract}',
    ].join('\n');

final _errors = <Object>[];

Future<Object?> _run(
    Map<String, String> shims, Map<String, Object> outputs) async {
  _errors.clear();
  Object? captured;
  await testBuilder(
    marinefordAbiBuilder(const BuilderOptions(<String, dynamic>{})),
    <String, String>{
      'app|lib/pricing.dart': '// nothing the aggregator reads',
      ...shims,
    },
    rootPackage: 'app',
    outputs: <String, Object>{
      for (final entry in outputs.entries) entry.key: entry.value,
      if (outputs.isNotEmpty)
        'app|marineford_ids.json': decodedMatches(predicate((Object? value) {
          captured = jsonDecode('$value');
          return true;
        })),
    },
    onLog: (record) {
      final error = record.error;
      if (error != null) _errors.add(error);
      if (record.level >= Level.SEVERE) _errors.add(record.message);
    },
  );
  return captured;
}

/// Runs the aggregator over [shims] and returns the decoded id registry.
Future<Map<String, Object?>> aggregate(Map<String, String> shims) async =>
    (await _run(
            shims, <String, Object>{'app|lib/marineford.g.dart': anything}))!
        as Map<String, Object?>;

/// Runs the aggregator expecting it to refuse, and returns what it said.
///
/// Asserting no outputs rather than asserting a throw, because build_runner
/// catches a builder's exception and reports it through the log. `throwsA`
/// around [aggregate] would only ever see the missing file, never the reason —
/// and a message nobody checks is a message that can rot into uselessness.
Future<String> refusal(Map<String, String> shims) async {
  await _run(shims, const <String, Object>{});
  expect(_errors, isNotEmpty, reason: 'the aggregator accepted this build');
  return _errors.join('\n');
}

void main() {
  group('aggregation', () {
    test('every shim in the package lands in one fingerprint', () async {
      final result = await aggregate(<String, String>{
        'app|lib/pricing.marineford.dart': shim(id: 'pricing.total'),
        'app|lib/orders.marineford.dart': shim(id: 'orders.status'),
      });

      expect(result['abi'], startsWith('sha256:'));
      expect(
        (result['ids']! as List).map((Object? r) => (r! as Map)['id']),
        <String>['orders.status', 'pricing.total'],
        reason: 'sorted, so the fingerprint does not depend on file order',
      );
    });

    test('two functions sharing a dispatch id are refused', () async {
      // Nothing else can catch this: two files in the same package cannot see
      // each other's ids, so the collision is only visible from up here.
      expect(
        await refusal(<String, String>{
          'app|lib/pricing.marineford.dart': shim(id: 'total'),
          'app|lib/orders.marineford.dart': shim(id: 'total'),
        }),
        contains('share the dispatch id "total"'),
      );
    });
  });

  group('contract version', () {
    test('a shim from an older generator stops the build', () async {
      // The fingerprint must depend only on the generator that is running. A
      // stale shim taken at its word would move the fingerprint to a value
      // neither generator version agrees with, and the only symptom would be
      // patches quietly never loading.
      expect(
        await refusal(<String, String>{
          'app|lib/pricing.marineford.dart': shim(id: 'a'),
          'app|lib/orders.marineford.dart':
              shim(id: 'b', contract: kShimContractVersion - 1),
        }),
        allOf(
          contains('lib/orders.marineford.dart'),
          contains('contract v${kShimContractVersion - 1}'),
          contains('stale'),
          contains('build_runner'),
        ),
      );
    });

    test('the fingerprint is the same however many shims declare it', () async {
      // Each shim repeats the contract line, so a build with two of them used
      // to fold the number in twice as often as a build with one. It must not
      // matter.
      final one = await aggregate(<String, String>{
        'app|lib/pricing.marineford.dart': shim(id: 'a'),
      });
      final two = await aggregate(<String, String>{
        'app|lib/pricing.marineford.dart': shim(id: 'a'),
        'app|lib/orders.marineford.dart': shim(id: 'a2'),
      });
      final again = await aggregate(<String, String>{
        'app|lib/pricing.marineford.dart': shim(id: 'a'),
      });

      expect(one['abi'], again['abi']);
      expect(one['abi'], isNot(two['abi']));
    });
  });
}
