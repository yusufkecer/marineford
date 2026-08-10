import 'dart:convert';
import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:test/test.dart';

Uint8List msg([int size = 5000]) =>
    Uint8List.fromList(List.generate(size, (i) => i % 251));

void main() {
  late PatchSigner signer;
  late PatchVerifier verifier;
  late Uint8List message;
  late Uint8List signature;

  setUp(() async {
    signer = await PatchSigner.generate();
    verifier = PatchVerifier(signer.publicKey);
    message = msg();
    signature = await signer.sign(message);
  });

  group('valid signatures', () {
    test('a signature made by the matching key verifies', () async {
      expect(await verifier.verify(message, signature), isTrue);
    });

    test('the base64 public key round-trips into a working verifier', () async {
      final fromText = PatchVerifier.fromBase64(signer.publicKeyBase64);
      expect(await fromText.verify(message, signature), isTrue);
    });

    test('whitespace around a pasted key is tolerated', () async {
      final padded = PatchVerifier.fromBase64('  ${signer.publicKeyBase64}\n');
      expect(await padded.verify(message, signature), isTrue);
    });

    test('a key restored from its seed produces the same public key', () async {
      final seed = await signer.extractSeed();
      final restored = await PatchSigner.fromSeed(seed);
      expect(restored.publicKey, signer.publicKey);
      expect(
          await verifier.verify(message, await restored.sign(message)), isTrue);
    });

    test('an empty message can be signed and verified', () async {
      final empty = Uint8List(0);
      expect(await verifier.verify(empty, await signer.sign(empty)), isTrue);
    });
  });

  group('rejection — every one of these must return false, never throw', () {
    test('a single flipped bit in the message', () async {
      final tampered = Uint8List.fromList(message)..[2500] ^= 0x01;
      expect(await verifier.verify(tampered, signature), isFalse);
    });

    test('a single flipped bit in the signature', () async {
      final tampered = Uint8List.fromList(signature)..[10] ^= 0x01;
      expect(await verifier.verify(message, tampered), isFalse);
    });

    test('a signature from a different key', () async {
      final other = await PatchSigner.generate();
      expect(
          await verifier.verify(message, await other.sign(message)), isFalse);
    });

    test('a truncated signature', () async {
      expect(await verifier.verify(message, signature.sublist(0, 63)), isFalse);
    });

    test('an over-long signature', () async {
      expect(
        await verifier.verify(message, Uint8List.fromList([...signature, 0])),
        isFalse,
      );
    });

    test('an empty signature', () async {
      expect(await verifier.verify(message, Uint8List(0)), isFalse);
    });

    test('all-zero signature bytes', () async {
      expect(await verifier.verify(message, Uint8List(64)), isFalse);
    });

    test('all-0xff signature bytes — a malformed curve point', () async {
      // This is the input that made the underlying library throw StateError
      // rather than return false. If the wrapper ever stops catching, a
      // corrupt download becomes a crash instead of a rejected patch.
      final garbage = Uint8List(64)..fillRange(0, 64, 0xff);
      expect(await verifier.verify(message, garbage), isFalse);
    });

    test('a message truncated by one byte', () async {
      expect(
          await verifier.verify(message.sublist(0, 4999), signature), isFalse);
    });

    test('a message with one byte appended', () async {
      expect(
        await verifier.verify(Uint8List.fromList([...message, 0]), signature),
        isFalse,
      );
    });
  });

  group('key handling', () {
    test('a wrong-length raw public key is rejected loudly at construction',
        () {
      // A broken key is a build mistake, not hostile input, so this one throws.
      expect(() => PatchVerifier(Uint8List(31)), throwsFormatException);
      expect(() => PatchVerifier(Uint8List(33)), throwsFormatException);
    });

    test('a non-base64 key string is rejected', () {
      expect(() => PatchVerifier.fromBase64('not a key!'),
          throwsA(isA<FormatException>()));
    });

    test('a base64 string of the wrong length is rejected', () {
      expect(() => PatchVerifier.fromBase64(base64Encode(Uint8List(16))),
          throwsFormatException);
    });

    test('a wrong-length seed is rejected', () {
      expect(() => PatchSigner.fromSeed(Uint8List(16)), throwsFormatException);
    });

    test('two generated signers differ', () async {
      final a = await PatchSigner.generate();
      final b = await PatchSigner.generate();
      expect(a.publicKey, isNot(b.publicKey));
    });
  });

  group('sha256 helpers', () {
    test('known vector', () {
      expect(sha256Hex(utf8.encode('abc')),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('matchesSha256 accepts the right hash and rejects the rest', () {
      final bytes = utf8.encode('marineford');
      final hash = sha256Hex(bytes);
      expect(matchesSha256(bytes, hash), isTrue);
      expect(matchesSha256(bytes, hash.replaceRange(0, 1, '0')), isFalse);
      expect(matchesSha256(bytes, ''), isFalse);
      expect(matchesSha256(bytes, hash.toUpperCase()), isFalse);
      expect(matchesSha256(utf8.encode('dendem'), hash), isFalse);
    });
  });

  group('end to end over a real container', () {
    test('a signed container verifies, and any edit to it does not', () async {
      final region = MfpContainer.buildSignedRegion(
        payload: Uint8List.fromList(List.generate(2000, (i) => i % 256)),
        abiHash: Uint8List(32)..fillRange(0, 32, 0x11),
      );
      final sig = await signer.sign(region);
      final file = Uint8List.fromList([...region, ...sig]);

      final parsed = MfpContainer.parse(file);
      expect(
          await verifier.verify(parsed.signedRegion, parsed.signature), isTrue);

      // Flip a payload byte and re-frame it: the container still parses, but
      // the signature no longer covers it. Parsing is not a trust boundary.
      final edited = Uint8List.fromList(file);
      edited[kMfpHeaderLength + 100] ^= 0x01;
      final reparsed = MfpContainer.parse(edited);
      expect(await verifier.verify(reparsed.signedRegion, reparsed.signature),
          isFalse);

      // Swapping in a different ABI fingerprint is also covered.
      final abiEdited = Uint8List.fromList(file);
      abiEdited[8] ^= 0x01;
      final abiReparsed = MfpContainer.parse(abiEdited);
      expect(
          await verifier.verify(
              abiReparsed.signedRegion, abiReparsed.signature),
          isFalse);
    });
  });
}
