import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'abi.dart';
import 'errors.dart';

/// File magic for a marineford patch container: `MFP1` in ASCII.
///
/// Spelled from the characters rather than hex on purpose. It was hex once, and
/// a project rename updated every mention of the old magic in prose while
/// leaving the bytes saying the old thing.
final List<int> kMfpMagic = List<int>.unmodifiable('MFP1'.codeUnits);

/// Highest container schema this build understands.
const int kMaxMfpSchema = 1;

/// Length of the fixed header, in bytes.
const int kMfpHeaderLength = 44;

/// Length of an Ed25519 signature, in bytes.
const int kMfpSignatureLength = 64;

/// Smallest possible well-formed container: header plus signature, empty
/// payload.
const int kMfpMinLength = kMfpHeaderLength + kMfpSignatureLength;

/// Largest container this build will parse.
///
/// A patch is kilobytes. This is not a tuning knob — it is a ceiling on how much
/// a hostile or broken server can make the client hold in memory before any of
/// it has been verified.
const int kMfpMaxLength = 8 * 1024 * 1024;

/// Capability bits in the container header.
///
/// A client refuses any container whose flags include a bit it does not
/// implement. That refusal is the whole point: it turns "a newer patch reached
/// an older app" from a crash into a log line.
extension type const MfpFlags(int bits) {
  static const int _gzip = 1 << 0;
  static const int _flutterBridge = 1 << 1;

  /// Every bit this build implements, as a raw mask.
  ///
  /// One source of truth, spelled from the same constants the individual flags
  /// use. Written as its own literal it would be free to drift from them, and a
  /// mask that claims more than the code implements is a patch loaded with a
  /// capability nobody provides.
  static const int _supported = _gzip;

  /// No capabilities requested.
  static const MfpFlags none = MfpFlags(0);

  /// The payload is gzip-compressed.
  static const MfpFlags gzip = MfpFlags(_gzip);

  /// The patch needs the Flutter widget bridge.
  ///
  /// Reserved for v2 and never set by v1 publishers. A v1 client that sees it
  /// rejects the patch with [UnsupportedFlagsException] instead of loading a
  /// program whose bridge it cannot provide.
  static const MfpFlags flutterBridge = MfpFlags(_flutterBridge);

  /// Everything this build knows how to honour.
  static const MfpFlags supported = MfpFlags(_supported);

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
    required this.abi,
    required this.payload,
    required this.signature,
    required this.signedRegion,
  });

  /// Capability bits the publisher set.
  final MfpFlags flags;

  /// Container schema version.
  final int schema;

  /// The fingerprint of the build this patch was compiled against.
  final AbiFingerprint abi;

  /// The patch program, still compressed if [MfpFlags.gzip] is set.
  ///
  /// A copy, not a view onto the original buffer: a view would let a caller
  /// mutate the bytes the signature was checked over.
  final Uint8List payload;

  /// The Ed25519 signature trailer.
  final Uint8List signature;

  /// The bytes the signature covers: everything except the signature itself.
  final Uint8List signedRegion;

  /// Parses a container, checking only that it is structurally sound.
  ///
  /// Throws [MfpFormatException] if the bytes are not a container, and
  /// [UnsupportedFlagsException] if they are but ask for capabilities this
  /// build does not have.
  factory MfpContainer.parse(
    Uint8List bytes, {
    int maxSchema = kMaxMfpSchema,
    MfpFlags supported = MfpFlags.supported,
    int maxLength = kMfpMaxLength,
  }) {
    if (bytes.length > maxLength) {
      throw MfpFormatException('file is ${bytes.length} bytes, over the '
          '$maxLength byte ceiling');
    }
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
      abi: AbiFingerprint.fromBytes(Uint8List.sublistView(bytes, 8, 40)),
      payload: Uint8List.fromList(Uint8List.sublistView(
          bytes, kMfpHeaderLength, kMfpHeaderLength + payloadLength)),
      signature: Uint8List.fromList(
          Uint8List.sublistView(bytes, bytes.length - kMfpSignatureLength)),
      signedRegion: Uint8List.fromList(
          Uint8List.sublistView(bytes, 0, bytes.length - kMfpSignatureLength)),
    );
  }

  /// Builds the unsigned part of a container: everything the signature covers.
  ///
  /// The CLI signs the result and appends the 64-byte signature to get the
  /// final file. Kept separate from signing so this stays pure and testable.
  static Uint8List buildSignedRegion({
    required Uint8List payload,
    required AbiFingerprint abi,
    MfpFlags flags = MfpFlags.gzip,
    int schema = kMaxMfpSchema,
  }) {
    final out = Uint8List(kMfpHeaderLength + payload.length);
    out.setRange(0, 4, kMfpMagic);
    final view = ByteData.view(out.buffer);
    view.setUint16(4, flags.bits, Endian.little);
    view.setUint16(6, schema, Endian.little);
    out.setRange(8, 40, abi.toBytes());
    view.setUint32(40, payload.length, Endian.little);
    out.setRange(kMfpHeaderLength, out.length, payload);
    return out;
  }

  @override
  String toString() => 'MfpContainer(schema $schema, flags ${flags.bits}, '
      '${payload.length} byte payload)';
}
