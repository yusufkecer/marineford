import 'dart:convert';

import 'package:build/build.dart';
import 'package:glob/glob.dart';

import 'abi.dart';
import 'shim_generator.dart' show abiMarker;

/// Collects every shim in the package into one ABI fingerprint and id registry.
///
/// Has to be a separate, aggregating build step: the fingerprint covers the
/// whole app, and no single file can compute it. The output is two things:
///
/// * `lib/marineford.g.dart`, holding `kMarinefordAbi`, which you pass to the
///   client config and which the runtime compares against every patch.
/// * `marineford_ids.json`, the list of dispatch ids, which `marineford doctor` checks
///   a patch package against so a typo in an `@RuntimeOverride` id is caught
///   before publishing rather than by silence in the field.
final class AbiAggregator implements Builder {
  /// Creates an [AbiAggregator].
  const AbiAggregator();

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
        r'$lib$': <String>['marineford.g.dart'],
        r'$package$': <String>['marineford_ids.json'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final records = <Map<String, Object?>>[];
    await for (final input
        in buildStep.findAssets(Glob('**/*.marineford.dart'))) {
      for (final line in const LineSplitter()
          .convert(await buildStep.readAsString(input))) {
        final marker = line.indexOf(abiMarker);
        if (marker < 0) continue;
        final decoded = jsonDecode(line.substring(marker + abiMarker.length));
        if (decoded is Map<String, Object?>) records.add(decoded);
      }
    }

    records.sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));

    final abi = AbiBuilder();
    for (final record in records) {
      abi.add(
        id: '${record['id']}',
        parameterTypes: <String>[
          for (final t in record['params'] as List? ?? const []) '$t',
        ],
        returnType: '${record['returns']}',
      );
    }
    final fingerprint = abi.build();

    if (buildStep.inputId.path.endsWith(r'$lib$')) {
      await buildStep.writeAsString(
        AssetId(buildStep.inputId.package, 'lib/marineford.g.dart'),
        _library(fingerprint, records),
      );
    } else {
      await buildStep.writeAsString(
        AssetId(buildStep.inputId.package, 'marineford_ids.json'),
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'abi': fingerprint,
          'ids': records,
        }),
      );
    }
  }

  String _library(String abi, List<Map<String, Object?>> records) {
    final ids = StringBuffer();
    for (final record in records) {
      ids.writeln("  r'${record['id']}',");
    }
    return '''
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint

/// ABI fingerprint of this build's patchable surface.
///
/// Pass this to `MarinefordConfig.abi`. The runtime refuses any patch built against
/// a different fingerprint, which is what stops a patch compiled for an older
/// build from loading against changed method signatures — the failure semver
/// alone cannot catch.
///
/// Covers ${records.length} patchable function${records.length == 1 ? '' : 's'}.
const String kMarinefordAbi = '$abi';

/// Every dispatch id in this build, sorted.
///
/// A patch's `@RuntimeOverride` id must appear here or it will never fire.
/// `marineford doctor` checks a patch package against this list.
const List<String> kMarinefordPatchIds = <String>[
${ids.toString().trimRight()}
];
''';
  }
}
