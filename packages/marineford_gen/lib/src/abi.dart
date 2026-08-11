import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Builds the ABI fingerprint that decides whether a patch may load.
///
/// The fingerprint is a hash of every signature a patch can reach: the dispatch
/// id, the parameter types, the return type. If any of those changes between
/// two builds of the app, the fingerprint changes and patches built for the old
/// one stop being loadable.
///
/// This exists because semver does not catch the thing that actually breaks
/// patches. A developer bumps 1.4.0 to 1.4.1, renames a parameter's type along
/// the way, and the version constraint on the old patch still matches — so it
/// loads, and then throws somewhere unrelated. The fingerprint turns that into
/// a patch that is simply never selected.
final class AbiBuilder {
  /// Creates an [AbiBuilder] for a given generator/runtime contract version.
  AbiBuilder({this.contractVersion = 1});

  /// Version of the calling convention the shims were generated against.
  ///
  /// Part of the hash. Two builds can expose byte-identical signatures and
  /// still be incompatible if the generated call sequence changed underneath —
  /// the argument shape handed to the interpreter, or the way a result is
  /// unwrapped. Without this, a patch built before such a change loads happily
  /// into a build after it.
  final int contractVersion;

  final List<String> _entries = <String>[];

  /// Records one patchable function.
  ///
  /// [parameterTypes] and [returnType] must be canonical display strings, so
  /// that formatting or import-prefix differences do not change the hash.
  void add({
    required String id,
    required List<String> parameterTypes,
    required String returnType,
  }) {
    _entries.add('$id(${parameterTypes.join(',')})->$returnType');
  }

  /// Number of recorded functions.
  int get length => _entries.length;

  /// The canonical text the fingerprint is taken over.
  ///
  /// Sorted, so the order files happen to be processed in cannot change the
  /// result — a fingerprint that depends on build order would invalidate every
  /// patch at random.
  String get canonicalForm {
    final sorted = [..._entries]..sort();
    return sorted.join('\n');
  }

  /// The fingerprint, as `sha256:<64 lowercase hex digits>`.
  String build() => 'sha256:${sha256.convert(utf8.encode(canonicalForm))}';
}
