import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'errors.dart';

/// File magic for a marineford patch container: `MFP1`.
const List<int> kMfpMagic = <int>[0x44, 0x44, 0x4d, 0x31];

/// Highest container schema this build understands.
const int kMaxMfpSchema = 1;

/// Length of the fixed header, in bytes.
const int kMfpHeaderLength = 44;

/// Length of an Ed25519 signature, in bytes.
const int kMfpSignatureLength = 64;

/// Smallest possible well-formed container: header plus signature, empty
/// payload.
const int kMfpMinLength = kMfpHeaderLength + kMfpSignatureLength;

/// Capability bits in the container header.
///
/// A client refuses any container whose flags include a bit it does not
/// implement. That refusal is the whole point: it turns "a newer patch reached
/// an older app" from a crash into a log line.
extension type const MfpFlags(int bits) {
  /// No capabilities requested.
  static const MfpFlags none = MfpFlags(0);

  /// The payload is gzip-compressed.
  static const MfpFlags gzip = MfpFlags(1 << 0);

  /// The patch needs the Flutter widget bridge.
  ///
  /// Reserved for v2 and never set by v1 publishers. A v1 client that sees it
  /// rejects the patch with [UnsupportedFlagsException] instead of loading a
  /// program whose bridge it cannot provide.
  static const MfpFlags flutterBridge = MfpFlags(1 << 1);

  /// Everything this build knows how to honour.
  static const MfpFlags supported = MfpFlags(1);

  /// Whether [other]'s bits are all set here.
  bool has(MfpFlags other) => bits & other.bits == other.bits;

  /// Bits set here that [supported] does not cover.
  int get unsupportedBits => bits & ~supported.bits;
}

/// A parsed `.mfp` patch container.
///
/// Layout, all integers little-endian:
///
/// ```text
/// offset  size  field
/// 0       4     magic "MFP1"
/// 4       2     flags
/// 6       2     schema
/// 8       32    abi fingerprint (raw sha256)
/// 40      4     payload length
/// 44      N     payload (dart_eval .evc, gzipped if the gzip flag is set)
/// 44+N    64    Ed25519 signature over bytes [0, 44+N)
/// ```
///
/// Parsing is structural only — it proves the bytes are shaped like a
/// container, nothing more. Call [signedRegion] and check the signature before
/// you touch [payload]. In particular the payload is *not* decompressed here:
/// inflating unverified bytes is how you get a decompression bomb.
@immutable
final class MfpContainer {
  const MfpContainer._({
    required this.flags,
    required this.schema,
    required this.abiHash,
    required this.payload,
    required this.signature,
    required this.bytes,
  });

  /// Capability bits the publisher set.
  final MfpFlags flags;

  /// Container schema version.
  final int schema;

  /// Raw 32-byte ABI fingerprint the patch was built against.
  final Uint8List abiHash;

  /// The patch program, still compressed if [MfpFlags.gzip] is set.
  final Uint8List payload;

  /// The Ed25519 signature trailer.
  final Uint8List signature;

  /// The complete original file.
  final Uint8List bytes;

  /// The bytes the signature covers: everything except the signature itself.
  Uint8List get signedRegion =>
      Uint8List.sublistView(bytes, 0, bytes.length - kMfpSignatureLength);

  /// The ABI fingerprint in manifest form, `sha256:<hex>`.
  String get abi {
    final buffer = StringBuffer('sha256:');
    for (final byte in abiHash) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Parses a container, checking only that it is structurally sound.
  ///
  /// Throws [MfpFormatException] if the bytes are not a container, and
  /// [UnsupportedFlagsException] if they are but ask for capabilities this
  /// build does not have.
  factory MfpContainer.parse(Uint8List bytes,
      {int maxSchema = kMaxMfpSchema,
      MfpFlags supported = MfpFlags.supported}) {
    if (bytes.length < kMfpMinLength) {
      throw MfpFormatException('file is ${bytes.length} bytes, shorter than '
          'the $kMfpMinLength byte minimum for a patch container');
    }
    for (var i = 0; i < kMfpMagic.length; i++) {
      if (bytes[i] != kMfpMagic[i]) {
        throw const MfpFormatException(
            'file does not start with the MFP1 magic; this is not a patch');
      }
    }

    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final flags = MfpFlags(view.getUint16(4, Endian.little));
    final schema = view.getUint16(6, Endian.little);
    if (schema > maxSchema) {
      throw MfpFormatException('patch container schema $schema is newer than '
          'the supported maximum $maxSchema');
    }

    final unsupported = flags.bits & ~supported.bits;
    if (unsupported != 0) {
      throw UnsupportedFlagsException(unsupported);
    }

    final payloadLength = view.getUint32(40, Endian.little);
    final expected = kMfpHeaderLength + payloadLength + kMfpSignatureLength;
    if (expected != bytes.length) {
      throw MfpFormatException('header declares a $payloadLength byte payload, '
          'which needs a $expected byte file, but the file is '
          '${bytes.length} bytes');
    }

    return MfpContainer._(
      flags: flags,
      schema: schema,
      abiHash: Uint8List.sublistView(bytes, 8, 40),
      payload: Uint8List.sublistView(
          bytes, kMfpHeaderLength, kMfpHeaderLength + payloadLength),
      signature:
          Uint8List.sublistView(bytes, bytes.length - kMfpSignatureLength),
      bytes: bytes,
    );
  }

  /// Builds the unsigned part of a container: everything the signature covers.
  ///
  /// The CLI signs the result and appends the 64-byte signature to get the
  /// final file. Kept separate from signing so this stays pure and testable.
  static Uint8List buildSignedRegion({
    required Uint8List payload,
    required Uint8List abiHash,
    MfpFlags flags = MfpFlags.gzip,
    int schema = kMaxMfpSchema,
  }) {
    if (abiHash.length != 32) {
      throw ArgumentError.value(
          abiHash.length, 'abiHash.length', 'ABI fingerprint must be 32 bytes');
    }
    final out = Uint8List(kMfpHeaderLength + payload.length);
    out.setRange(0, 4, kMfpMagic);
    final view = ByteData.view(out.buffer);
    view.setUint16(4, flags.bits, Endian.little);
    view.setUint16(6, schema, Endian.little);
    out.setRange(8, 40, abiHash);
    view.setUint32(40, payload.length, Endian.little);
    out.setRange(kMfpHeaderLength, out.length, payload);
    return out;
  }

  @override
  String toString() => 'MfpContainer(schema $schema, flags ${flags.bits}, '
      '${payload.length} byte payload)';
}
