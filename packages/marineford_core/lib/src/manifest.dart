import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import 'abi.dart';
import 'errors.dart';
import 'mfp.dart';

/// Highest manifest schema this build understands.
const int kMaxManifestSchema = 1;

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
  /// A cross-check against the manifest, not a defence on its own: the manifest
  /// is attacker-controlled if the CDN is, so trusting this number to bound a
  /// download would be circular. The transport enforces its own hard ceiling
  /// independently; this catches a truncated or swapped file early, before the
  /// hash is computed.
  final int size;

  /// Lowercase hex SHA-256 of the whole `.mfp` file.
  final String sha256;

  /// Fingerprint of the build this patch was compiled against.
  final AbiFingerprint abi;

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
    if (size > kMfpMaxLength) {
      throw ManifestFormatException(
          'patch "size" of $size exceeds the $kMfpMaxLength byte ceiling');
    }
    final hash = _string(json, 'sha256');
    if (!_hexPattern.hasMatch(hash)) {
      throw const ManifestFormatException(
          'patch "sha256" must be 64 lowercase hex digits');
    }

    final AbiFingerprint abi;
    try {
      abi = AbiFingerprint.parse(_string(json, 'abi'));
    } on FormatException catch (e) {
      throw ManifestFormatException('patch "abi": ${e.message}');
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
        'abi': abi.toString(),
        'runtime': runtime.toString(),
        'rollout': rollout,
        if (notes != null) 'notes': notes,
      };

  /// Returns a copy with the given fields replaced.
  PatchEntry copyWith({double? rollout, String? notes}) => PatchEntry(
        number: number,
        url: url,
        size: size,
        sha256: sha256,
        abi: abi,
        runtime: runtime,
        rollout: rollout ?? this.rollout,
        notes: notes ?? this.notes,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PatchEntry &&
          number == other.number &&
          url == other.url &&
          size == other.size &&
          sha256 == other.sha256 &&
          abi == other.abi &&
          runtime.toString() == other.runtime.toString() &&
          rollout == other.rollout &&
          notes == other.notes;

  @override
  int get hashCode => Object.hash(
      number, url, size, sha256, abi, runtime.toString(), rollout, notes);

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
    required this.sequence,
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

  /// Monotonically increasing publication counter.
  ///
  /// Every signature stays valid forever, so a client that accepted whatever it
  /// was handed could be walked backwards: serve the manifest from before a
  /// revocation and the kill switch is undone. A client remembers the highest
  /// sequence it has accepted and refuses anything lower, which closes that.
  ///
  /// Be precise about what it does not close. This stops knowledge being taken
  /// *back*; it does not force knowledge *forward*. A device that has not yet
  /// seen the manifest carrying a revocation has a low remembered sequence, so
  /// serving it that same older manifest forever passes this check every time —
  /// equal and higher are both accepted, as they must be, since an unchanged
  /// manifest is what every ordinary check returns.
  ///
  /// So `revoke` reaches a device only if the device can reach a current
  /// manifest. Two things make that true in practice and neither is this
  /// counter: `manifestUrl` is required to be https, so nobody on the path can
  /// answer for your host; and beyond that you are trusting whoever serves your
  /// files, exactly as you trust them not to serve a patch you never signed —
  /// except they cannot forge that one.
  final int sequence;

  /// When the publisher generated this manifest.
  ///
  /// Informational: nothing enforces it. A device's clock is not trustworthy
  /// enough to reject on, and a publisher who has not shipped in months is the
  /// normal case rather than an attack, so a max-age rule would fire far more
  /// often for the boring reason than the interesting one.
  final DateTime generatedAt;

  /// Available patches. Not guaranteed to be sorted.
  final List<PatchEntry> patches;

  /// Patch numbers that must never be applied, and must be rolled back if
  /// already installed. This is the kill switch.
  final Set<int> revoked;

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

    final sequence = _int(json, 'sequence');
    if (sequence < 1) {
      throw const ManifestFormatException('manifest "sequence" must be >= 1');
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
      sequence: sequence,
      generatedAt: generatedAt,
      patches: List<PatchEntry>.unmodifiable(patches),
      revoked: Set<int>.unmodifiable(revoked),
    );
  }

  /// Renders this manifest to JSON.
  Map<String, Object?> toJson() => <String, Object?>{
        'schema': schema,
        'app': appId,
        'channel': channel,
        'sequence': sequence,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'patches': [for (final p in patches) p.toJson()],
        'revoked': revoked.toList()..sort(),
      };

  @override
  String toString() =>
      'PatchManifest($appId/$channel #$sequence, ${patches.length} patches, '
      '${revoked.length} revoked)';
}

/// A manifest together with the signature over it.
///
/// The manifest and its signature are one file, not two. Publishing them
/// separately means a window in which the new manifest is up and the old
/// signature is still there — during which *every* device rejects the channel —
/// and a failed second upload leaves it that way permanently.
///
/// The signed content is carried as an opaque string rather than as nested
/// JSON, which removes canonicalisation from the picture entirely: the verifier
/// signs and checks the exact bytes it was given, so no amount of re-encoding,
/// key reordering or whitespace difference between publisher and client can
/// invalidate a good signature. The cost is that the file is not pretty to read
/// by hand; `marineford show` prints it.
@immutable
final class SignedManifest {
  const SignedManifest._({
    required this.signedBytes,
    required this.signature,
  });

  /// The exact bytes the signature covers.
  final Uint8List signedBytes;

  /// Ed25519 signature over [signedBytes].
  final Uint8List signature;

  /// Envelope schema version, so a future format change is refusable.
  static const int envelopeSchema = 1;

  /// Builds an envelope around [manifest], ready to be signed.
  ///
  /// Returns the bytes to sign; pass the resulting signature to [encode].
  static Uint8List bytesToSign(PatchManifest manifest) =>
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson())));

  /// Serialises a signed envelope.
  static Uint8List encode(Uint8List signedBytes, Uint8List signature) =>
      Uint8List.fromList(utf8.encode(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'envelope': envelopeSchema,
          'signature': base64Encode(signature),
          'manifest': utf8.decode(signedBytes),
        }),
      ));

  /// Reads the envelope, and nothing inside it.
  ///
  /// Genuinely structural: it decodes the outer object, pulls out the signature
  /// and the bytes it covers, and stops. The manifest inside stays an opaque
  /// string until [open] is called.
  ///
  /// The split is the whole point. Verification has to happen before the
  /// attacker-controlled payload is parsed, and the only reliable way to
  /// guarantee that is to make the parse a separate step the caller cannot
  /// reach by accident. An earlier version parsed the manifest here and
  /// described itself as structural; it ran every field validation, and every
  /// JSON decode, on bytes nobody had vouched for.
  factory SignedManifest.parse(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw ManifestFormatException('manifest is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const ManifestFormatException('manifest must be a JSON object');
    }

    final envelope = _int(decoded, 'envelope');
    if (envelope > envelopeSchema) {
      throw UnsupportedSchemaException(envelope, envelopeSchema);
    }

    final Uint8List signature;
    try {
      signature = base64Decode(_string(decoded, 'signature'));
    } on FormatException {
      throw const ManifestFormatException(
          'manifest "signature" is not valid base64');
    }

    return SignedManifest._(
      signedBytes:
          Uint8List.fromList(utf8.encode(_string(decoded, 'manifest'))),
      signature: signature,
    );
  }

  /// Parses the manifest this envelope carries.
  ///
  /// Call this only after [signature] has been verified over [signedBytes].
  /// Everything it does — decoding JSON, validating fields, parsing version
  /// constraints — is work performed on whatever the server sent, so doing it
  /// first would put the parser in front of the signature rather than behind
  /// it.
  PatchManifest open({int maxSchema = kMaxManifestSchema}) {
    final Object? inner;
    try {
      inner = jsonDecode(utf8.decode(signedBytes));
    } on FormatException catch (e) {
      throw ManifestFormatException(
          'the signed manifest is not valid JSON: ${e.message}');
    }
    if (inner is! Map<String, Object?>) {
      throw const ManifestFormatException(
          'the signed manifest must be a JSON object');
    }
    return PatchManifest.fromJson(inner, maxSchema: maxSchema);
  }
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
