import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Length of an Ed25519 public key, in bytes.
const int kPublicKeyLength = 32;

/// Length of an Ed25519 private key seed, in bytes.
const int kPrivateKeySeedLength = 32;

final Ed25519 _ed25519 = Ed25519();

/// Verifies Ed25519 signatures against a public key embedded in the app.
///
/// This is the only part of marineford_core that stands between an attacker who
/// controls your CDN and arbitrary code running in your app, so it is
/// deliberately small and deliberately paranoid: every failure mode —
/// wrong key, tampered payload, truncated signature, garbage bytes — returns
/// `false`. It never throws, because a caller that has to wrap this in a
/// try/catch will eventually forget to.
final class PatchVerifier {
  /// Creates a verifier for a raw 32-byte public key.
  PatchVerifier(Uint8List publicKey)
      : _publicKey = SimplePublicKey(
          _checkedKey(publicKey),
          type: KeyPairType.ed25519,
        );

  /// Creates a verifier from a base64-encoded public key.
  ///
  /// This is the form `marineford init` prints for you to paste into your app.
  /// Throws [FormatException] if the string is not valid base64 of the right
  /// length — a broken key is a build-time mistake and should be loud.
  factory PatchVerifier.fromBase64(String encoded) =>
      PatchVerifier(base64Decode(encoded.trim()));

  final SimplePublicKey _publicKey;

  static Uint8List _checkedKey(Uint8List key) {
    if (key.length != kPublicKeyLength) {
      throw FormatException(
          'Ed25519 public key must be $kPublicKeyLength bytes, got '
          '${key.length}');
    }
    return key;
  }

  /// Whether [signature] is a valid signature over [message] by this key.
  ///
  /// Returns `false` rather than throwing for every kind of bad input.
  Future<bool> verify(Uint8List message, Uint8List signature) async {
    if (signature.length != 64) return false;
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(signature, publicKey: _publicKey),
      );
    } on Object {
      // Intentionally broad. Anything the algorithm can throw on hostile input
      // — StateError on a malformed point, range errors on odd lengths — means
      // the same thing to us: not a valid signature. Rethrowing would turn a
      // rejected patch into a crash.
      return false;
    }
  }
}

/// Creates Ed25519 signatures. Used by the CLI; never needed at runtime.
///
/// Kept beside [PatchVerifier] on purpose: the two must agree on key encoding
/// and on exactly which bytes get signed, and splitting them across packages is
/// how that agreement rots.
final class PatchSigner {
  PatchSigner._(this._keyPair, this.publicKey);

  /// Generates a fresh signing key pair.
  static Future<PatchSigner> generate() async {
    final keyPair = await _ed25519.newKeyPair();
    final pub = await keyPair.extractPublicKey();
    return PatchSigner._(keyPair, Uint8List.fromList(pub.bytes));
  }

  /// Restores a signer from a 32-byte private key seed.
  static Future<PatchSigner> fromSeed(Uint8List seed) async {
    if (seed.length != kPrivateKeySeedLength) {
      throw FormatException(
          'Ed25519 private key seed must be $kPrivateKeySeedLength bytes, got '
          '${seed.length}');
    }
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    return PatchSigner._(keyPair, Uint8List.fromList(pub.bytes));
  }

  final SimpleKeyPair _keyPair;

  /// The matching raw 32-byte public key.
  final Uint8List publicKey;

  /// The public key in the base64 form meant to be pasted into an app.
  String get publicKeyBase64 => base64Encode(publicKey);

  /// The private key seed. Write this to a file the user has been told to
  /// keep out of version control, and nowhere else.
  Future<Uint8List> extractSeed() async =>
      Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());

  /// Signs [message], returning the 64-byte signature.
  Future<Uint8List> sign(Uint8List message) async {
    final signature = await _ed25519.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(signature.bytes);
  }
}

/// Lowercase hex SHA-256 of [bytes], in the form the manifest stores.
String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// Whether [bytes] hashes to [expectedHex], compared without leaking timing.
///
/// A constant-time compare is arguably theatre for a hash the attacker already
/// knows, but it costs nothing and removes the need to think about it again.
bool matchesSha256(List<int> bytes, String expectedHex) {
  final actual = sha256Hex(bytes);
  if (actual.length != expectedHex.length) return false;
  var diff = 0;
  for (var i = 0; i < actual.length; i++) {
    diff |= actual.codeUnitAt(i) ^ expectedHex.codeUnitAt(i);
  }
  return diff == 0;
}
