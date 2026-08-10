import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import 'errors.dart';

/// Highest manifest schema this build understands.
const int kMaxManifestSchema = 1;

/// Matches an ABI fingerprint: `sha256:` followed by 64 lowercase hex digits.
final RegExp _abiPattern = RegExp(r'^sha256:[0-9a-f]{64}$');
final RegExp _hexPattern = RegExp(r'^[0-9a-f]{64}$');

/// One publishable patch, as described by the manifest.
@immutable
final class PatchEntry {
  /// Creates a [PatchEntry].
  const PatchEntry({
    required this.number,
    required this.url,
    required this.size,
    required this.sha256,
    required this.abi,
    required this.runtime,
    this.rollout = 1.0,
    this.notes,
  });

  /// Monotonically increasing patch number within a channel.
  ///
  /// Ordering is by this number, not by publish time, and the client refuses to
  /// move to a lower number unless the installed one was revoked. That is what
  /// stops a compromised CDN from replaying an old, validly signed patch.
  final int number;

  /// Where to fetch the `.mfp` from. May be relative to the manifest.
  final String url;

  /// Expected size of the `.mfp` in bytes.
  ///
  /// Checked before the body is read so a hostile or broken server cannot make
  /// the client buffer an unbounded response.
  final int size;

  /// Lowercase hex SHA-256 of the whole `.mfp` file.
  final String sha256;

  /// ABI fingerprint the patch was built against, as `sha256:<hex>`.
  final String abi;

  /// App versions this patch applies to.
  final VersionConstraint runtime;

  /// Fraction of devices that should receive this patch, in `[0, 1]`.
  final double rollout;

  /// Free-form note for humans reading the manifest. Never shown to end users.
  final String? notes;

  /// Reads a [PatchEntry] from decoded JSON.
  ///
  /// Throws [ManifestFormatException] on anything unexpected. Unknown keys are
  /// ignored so that a newer publisher can add fields without breaking older
  /// clients.
  factory PatchEntry.fromJson(Map<String, Object?> json) {
    final number = _int(json, 'number');
    if (number <= 0) {
      throw const ManifestFormatException('patch "number" must be positive');
    }
    final size = _int(json, 'size');
    if (size <= 0) {
      throw const ManifestFormatException('patch "size" must be positive');
    }
    final hash = _string(json, 'sha256');
    if (!_hexPattern.hasMatch(hash)) {
      throw const ManifestFormatException(
          'patch "sha256" must be 64 lowercase hex digits');
    }
    final abi = _string(json, 'abi');
    if (!_abiPattern.hasMatch(abi)) {
      throw const ManifestFormatException(
          'patch "abi" must look like sha256:<64 lowercase hex digits>');
    }

    final VersionConstraint runtime;
    try {
      runtime = VersionConstraint.parse(_string(json, 'runtime'));
    } on FormatException catch (e) {
      throw ManifestFormatException('patch "runtime" is not a valid version '
          'constraint: ${e.message}');
    }

    var rollout = 1.0;
    final rawRollout = json['rollout'];
    if (rawRollout != null) {
      if (rawRollout is! num) {
        throw const ManifestFormatException('patch "rollout" must be a number');
      }
      rollout = rawRollout.toDouble();
      if (rollout.isNaN || rollout < 0.0 || rollout > 1.0) {
        throw const ManifestFormatException(
            'patch "rollout" must be between 0 and 1');
      }
    }

    final notes = json['notes'];
    if (notes != null && notes is! String) {
      throw const ManifestFormatException('patch "notes" must be a string');
    }

    return PatchEntry(
      number: number,
      url: _string(json, 'url'),
      size: size,
      sha256: hash,
      abi: abi,
      runtime: runtime,
      rollout: rollout,
      notes: notes as String?,
    );
  }

  /// Renders this entry back to JSON, as the CLI writes it.
  Map<String, Object?> toJson() => <String, Object?>{
        'number': number,
        'url': url,
        'size': size,
        'sha256': sha256,
        'abi': abi,
        'runtime': runtime.toString(),
        'rollout': rollout,
        if (notes != null) 'notes': notes,
      };

  @override
  String toString() => 'PatchEntry(#$number, $runtime, rollout $rollout)';
}

/// The published list of patches for one app on one channel.
@immutable
final class PatchManifest {
  /// Creates a [PatchManifest].
  const PatchManifest({
    required this.schema,
    required this.appId,
    required this.channel,
    required this.generatedAt,
    required this.patches,
    this.revoked = const <int>{},
  });

  /// Manifest schema version.
  final int schema;

  /// Application this manifest belongs to.
  ///
  /// Checked against the client's own id so that a misconfigured CDN path
  /// cannot feed one app another app's patches.
  final String appId;

  /// Release channel, e.g. `prod` or `beta`.
  final String channel;

  /// When the publisher generated this manifest.
  final DateTime generatedAt;

  /// Available patches. Not guaranteed to be sorted.
  final List<PatchEntry> patches;

  /// Patch numbers that must never be applied, and must be rolled back if
  /// already installed. This is the kill switch.
  final Set<int> revoked;

  /// Parses a manifest from its raw JSON text.
  ///
  /// Verify the detached signature over the exact bytes *before* calling this.
  /// Parsing is not a trust boundary.
  factory PatchManifest.parse(String source,
      {int maxSchema = kMaxManifestSchema}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw ManifestFormatException('manifest is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const ManifestFormatException('manifest must be a JSON object');
    }
    return PatchManifest.fromJson(decoded, maxSchema: maxSchema);
  }

  /// Reads a [PatchManifest] from decoded JSON.
  factory PatchManifest.fromJson(Map<String, Object?> json,
      {int maxSchema = kMaxManifestSchema}) {
    final schema = _int(json, 'schema');
    if (schema > maxSchema) {
      throw UnsupportedSchemaException(schema, maxSchema);
    }
    if (schema < 1) {
      throw const ManifestFormatException('manifest "schema" must be >= 1');
    }

    final DateTime generatedAt;
    try {
      generatedAt = DateTime.parse(_string(json, 'generatedAt'));
    } on FormatException {
      throw const ManifestFormatException(
          'manifest "generatedAt" must be an ISO 8601 timestamp');
    }

    final rawPatches = json['patches'];
    if (rawPatches is! List) {
      throw const ManifestFormatException('manifest "patches" must be a list');
    }
    final patches = <PatchEntry>[];
    final seen = <int>{};
    for (final raw in rawPatches) {
      if (raw is! Map<String, Object?>) {
        throw const ManifestFormatException(
            'every entry in "patches" must be an object');
      }
      final entry = PatchEntry.fromJson(raw);
      if (!seen.add(entry.number)) {
        throw ManifestFormatException(
            'patch number ${entry.number} appears more than once');
      }
      patches.add(entry);
    }

    final revoked = <int>{};
    final rawRevoked = json['revoked'];
    if (rawRevoked != null) {
      if (rawRevoked is! List) {
        throw const ManifestFormatException(
            'manifest "revoked" must be a list');
      }
      for (final raw in rawRevoked) {
        if (raw is! int) {
          throw const ManifestFormatException(
              'every entry in "revoked" must be an integer');
        }
        revoked.add(raw);
      }
    }

    return PatchManifest(
      schema: schema,
      appId: _string(json, 'app'),
      channel: _string(json, 'channel'),
      generatedAt: generatedAt,
      patches: List<PatchEntry>.unmodifiable(patches),
      revoked: Set<int>.unmodifiable(revoked),
    );
  }

  /// Renders this manifest back to JSON, as the CLI writes it.
  Map<String, Object?> toJson() => <String, Object?>{
        'schema': schema,
        'app': appId,
        'channel': channel,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'patches': [for (final p in patches) p.toJson()],
        'revoked': revoked.toList()..sort(),
      };

  @override
  String toString() =>
      'PatchManifest($appId/$channel, ${patches.length} patches, '
      '${revoked.length} revoked)';
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw ManifestFormatException('"$key" must be an integer');
  }
  return value;
}

String _string(Map<String, Object?> json, String key,
    {bool allowEmpty = false}) {
  final value = json[key];
  if (value is! String) {
    throw ManifestFormatException('"$key" must be a string');
  }
  if (!allowEmpty && value.isEmpty) {
    throw ManifestFormatException('"$key" must not be empty');
  }
  return value;
}
