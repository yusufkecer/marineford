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

  static final RegExp _text = RegExp('^$prefix[0-9a-f]{64}\$');

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
    if (!_text.hasMatch(value)) {
      throw FormatException(
          'an ABI fingerprint looks like $prefix<64 lowercase hex digits>, '
          'got "$value"');
    }
    final hex = value.substring(prefix.length);
    return AbiFingerprint._(Uint8List.fromList(<int>[
      for (var i = 0; i < lengthInBytes; i++)
        int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ]));
  }

  /// Parses [value], or returns null instead of throwing.
  static AbiFingerprint? tryParse(String value) {
    try {
      return AbiFingerprint.parse(value);
    } on FormatException {
      return null;
    }
  }

  /// The raw digest, as a copy.
  Uint8List toBytes() => Uint8List.fromList(_bytes);

  @override
  String toString() {
    final buffer = StringBuffer(prefix);
    for (final byte in _bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AbiFingerprint) return false;
    for (var i = 0; i < lengthInBytes; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_bytes);
}
