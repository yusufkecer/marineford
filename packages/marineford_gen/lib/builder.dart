/// build_runner entry points for marineford's code generator.
///
/// Two steps, because they answer different questions:
///
/// * [marinefordShimBuilder] turns each `@patchable` / `@PatchableService` in a
///   file into a dispatch shim, writing a `part` beside it.
/// * [marinefordAbiBuilder] aggregates every shim in the package into one
///   fingerprint and one id registry — something no single file can compute.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/abi_aggregator.dart';
import 'src/shim_generator.dart';

export 'src/abi.dart' show AbiBuilder;
export 'src/shim_generator.dart' show ShimGenerator, ShimRecord;
export 'src/types.dart'
    show ArgumentForm, TypeSupport, TypeVerdict, classifyType;

/// Emits the `.marineford.dart` part files holding the dispatch shims.
Builder marinefordShimBuilder(BuilderOptions options) => PartBuilder(
      <Generator>[ShimGenerator()],
      '.marineford.dart',
      header: '''
// GENERATED CODE - DO NOT MODIFY BY HAND
//
// Every shim here is one static field read away from doing nothing. That is
// deliberate: marking a function must stay close to free when no patch is live.
// ignore_for_file: type=lint, unnecessary_cast, prefer_final_locals
// ignore_for_file: no_leading_underscores_for_local_identifiers
''',
    );

/// Emits `lib/marineford.g.dart` and `marineford_ids.json`.
Builder marinefordAbiBuilder(BuilderOptions options) => const AbiAggregator();
