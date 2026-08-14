import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The fingerprint of a build's patchable surface.
///
/// One type, one place. It used to exist in six: raw bytes in the container
/// header, hex assembled by hand for the manifest, two regexes validating that
/// hex, the generator's own builder, and the CLI's parser. Six representations
/// of one value is five chances for them to disagree, and a disagreement here
/// means a patch loading against a build it was not compiled for — the exact
/// failure the fingerprint exists to prevent.
@immutable
final class AbiFingerprint {
  const AbiFingerprint._(this._bytes);

  /// Length of the underlying digest.
  static const int lengthInBytes = 32;

  /// The `sha256:` prefix every textual form carries.
  static const String prefix = 'sha256:';

  static const int _textLength = prefix.length + lengthInBytes * 2;

  final Uint8List _bytes;

  /// Wraps 32 raw digest bytes.
  ///
  /// Throws [FormatException] on any other length; a truncated fingerprint must
  /// never silently become a different one.
  factory AbiFingerprint.fromBytes(Uint8List bytes) {
    if (bytes.length != lengthInBytes) {
      throw FormatException(
          'an ABI fingerprint is $lengthInBytes bytes, got ${bytes.length}');
    }
    return AbiFingerprint._(Uint8List.fromList(bytes));
  }

  /// Parses the `sha256:<64 lowercase hex>` form.
  factory AbiFingerprint.parse(String value) {
    final bytes = _decode(value);
    if (bytes == null) {
      throw FormatException(
          'an ABI fingerprint looks like $prefix<64 lowercase hex digits>, '
          'got "$value"');
    }
    return AbiFingerprint._(bytes);
  }

  /// Parses [value], or returns null instead of throwing.
  static AbiFingerprint? tryParse(String value) {
    final bytes = _decode(value);
    return bytes == null ? null : AbiFingerprint._(bytes);
  }

  /// Validates and decodes in one pass, or returns null.
  ///
  /// By hand rather than by regex and `int.parse`, because the previous version
  /// allocated 33 substrings and a match object to produce 32 bytes — on a path
  /// that runs for every entry of every manifest the client reads. Reading code
  /// units costs nothing and, more usefully, folds validation and decoding into
  /// the same loop so the two cannot disagree about what is accepted.
  static Uint8List? _decode(String value) {
    if (value.length != _textLength) return null;
    for (var i = 0; i < prefix.length; i++) {
      if (value.codeUnitAt(i) != prefix.codeUnitAt(i)) return null;
    }
    final bytes = Uint8List(lengthInBytes);
    for (var i = 0; i < lengthInBytes; i++) {
      final high = _nibble(value.codeUnitAt(prefix.length + i * 2));
      final low = _nibble(value.codeUnitAt(prefix.length + i * 2 + 1));
      if (high < 0 || low < 0) return null;
      bytes[i] = (high << 4) | low;
    }
    return bytes;
  }

  /// One hex digit, or -1.
  ///
  /// Lowercase only. Uppercase is a different string for the same value, and
  /// accepting both would mean a fingerprint that compares equal as bytes but
  /// not as text — which is how two spellings of one build end up in a manifest.
  static int _nibble(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
    if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x57;
    return -1;
  }

  /// The raw digest, as a copy.
  Uint8List toBytes() => Uint8List.fromList(_bytes);

  @override
  String toString() {
    final units = Uint8List(_textLength);
    for (var i = 0; i < prefix.length; i++) {
      units[i] = prefix.codeUnitAt(i);
    }
    for (var i = 0; i < lengthInBytes; i++) {
      units[prefix.length + i * 2] = _hexDigit(_bytes[i] >> 4);
      units[prefix.length + i * 2 + 1] = _hexDigit(_bytes[i] & 0xf);
    }
    return String.fromCharCodes(units);
  }

  static int _hexDigit(int nibble) =>
      nibble < 10 ? 0x30 + nibble : 0x57 + nibble;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AbiFingerprint) return false;
    for (var i = 0; i < lengthInBytes; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    return true;
  }

  /// Recomputed on every call, deliberately.
  ///
  /// Caching it in a `late final` is the obvious move and does not compile:
  /// this class has a const constructor, and a class with one cannot hold a
  /// late final field. Between a const fingerprint and a memoised hash of 32
  /// bytes, the constructor is worth more — this is reached through
  /// `PatchEntry.hashCode`, and a manifest holds a handful of entries, not a
  /// hot loop.
  @override
  int get hashCode => Object.hashAll(_bytes);
}
