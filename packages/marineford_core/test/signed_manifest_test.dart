import 'dart:convert';
import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

PatchManifest manifest({int sequence = 1}) => PatchManifest(
      schema: 1,
      appId: 'com.example.app',
      channel: 'prod',
      sequence: sequence,
      generatedAt: DateTime.utc(2026, 8, 11),
      patches: <PatchEntry>[
        PatchEntry(
          number: 7,
          url: '7.mfp',
          size: 1024,
          sha256: 'c' * 64,
          abi: AbiFingerprint.parse('sha256:${'a' * 64}'),
          runtime: VersionConstraint.parse('>=1.0.0 <2.0.0'),
        ),
      ],
      revoked: const <int>{3},
    );

Future<Uint8List> publish(PatchSigner signer, PatchManifest source) async {
  final signedBytes = SignedManifest.bytesToSign(source);
  return SignedManifest.encode(signedBytes, await signer.sign(signedBytes));
}

void main() {
  late PatchSigner signer;
  late PatchVerifier verifier;

  setUp(() async {
    signer = await PatchSigner.generate();
    verifier = PatchVerifier(signer.publicKey);
  });

  group('round trip', () {
    test('a published envelope parses back to the same manifest', () async {
      final source = manifest();
      final parsed = SignedManifest.parse(await publish(signer, source));
      final reopened = parsed.open();

      expect(reopened.appId, source.appId);
      expect(reopened.sequence, source.sequence);
      expect(reopened.patches.single, source.patches.single);
      expect(reopened.revoked, source.revoked);
      expect(
          await verifier.verify(parsed.signedBytes, parsed.signature), isTrue);
    });

    test('the whole channel is one file', () async {
      // The point of the envelope. Two files meant a window where the new
      // manifest was up and the old signature was not, during which every
      // device rejected the channel — and a failed second upload made that
      // permanent.
      final bytes = await publish(signer, manifest());
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      expect(decoded.keys, containsAll(<String>['signature', 'manifest']));
    });

    test('re-encoding the envelope does not invalidate the signature',
        () async {
      // The reason the signed payload is an opaque string. Anything that
      // re-serialises structured JSON — a proxy, a different encoder, a key
      // reordering — would otherwise break verification on every device at
      // once.
      final original = await publish(signer, manifest());
      final decoded = jsonDecode(utf8.decode(original)) as Map<String, Object?>;
      final reencoded =
          Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
        'manifest': decoded['manifest'],
        'envelope': decoded['envelope'],
        'signature': decoded['signature'],
      })));

      final parsed = SignedManifest.parse(reencoded);
      expect(
          await verifier.verify(parsed.signedBytes, parsed.signature), isTrue);
    });
  });

  group('tampering', () {
    test('editing the manifest text breaks the signature', () async {
      final decoded = jsonDecode(utf8.decode(await publish(signer, manifest())))
          as Map<String, Object?>;
      final edited = (decoded['manifest']! as String)
          .replaceAll('"sequence":1', '"sequence":2');
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
        ...decoded,
        'manifest': edited,
      })));

      final parsed = SignedManifest.parse(bytes);
      expect(parsed.open().sequence, 2,
          reason: 'opening is not a trust '
              'boundary; it happily reads the edited value');
      expect(
          await verifier.verify(parsed.signedBytes, parsed.signature), isFalse,
          reason: 'the signature is what catches it');
    });

    test('dropping a revocation breaks the signature', () async {
      final decoded = jsonDecode(utf8.decode(await publish(signer, manifest())))
          as Map<String, Object?>;
      final edited = (decoded['manifest']! as String)
          .replaceAll('"revoked":[3]', '"revoked":[]');
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
        ...decoded,
        'manifest': edited,
      })));
      final parsed = SignedManifest.parse(bytes);
      expect(
          await verifier.verify(parsed.signedBytes, parsed.signature), isFalse);
    });

    test('a signature from another key does not verify', () async {
      final impostor = await PatchSigner.generate();
      final parsed = SignedManifest.parse(await publish(impostor, manifest()));
      expect(
          await verifier.verify(parsed.signedBytes, parsed.signature), isFalse);
    });
  });

  group('malformed envelopes', () {
    void rejects(String label, Object? json) {
      test(label, () {
        expect(
          () => SignedManifest.parse(
              Uint8List.fromList(utf8.encode(jsonEncode(json)))),
          throwsA(isA<MarinefordFormatException>()),
        );
      });
    }

    rejects('not an object', <Object?>[1, 2, 3]);
    rejects('missing signature', <String, Object?>{
      'envelope': 1,
      'manifest': '{}',
    });
    rejects('missing manifest', <String, Object?>{
      'envelope': 1,
      'signature': 'AAAA',
    });
    rejects('signature not base64', <String, Object?>{
      'envelope': 1,
      'signature': 'not base64!!',
      'manifest': '{}',
    });
    test('a newer envelope version is refused as unsupported', () {
      expect(
        () => SignedManifest.parse(
            Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
          'envelope': 99,
          'signature': base64Encode(Uint8List(64)),
          'manifest': '{}',
        })))),
        throwsA(isA<UnsupportedSchemaException>()),
      );
    });

    test('an HTML error page is refused', () {
      expect(
        () => SignedManifest.parse(
            Uint8List.fromList(utf8.encode('<html>504</html>'))),
        throwsA(isA<ManifestFormatException>()),
      );
    });
  });

  group('nothing inside the envelope is read until open()', () {
    // The ordering these tests pin down is the reason `parse` and `open` are
    // two calls. If parsing the envelope also parsed the manifest, every field
    // validation — and the JSON decoder itself — would run on bytes nobody had
    // checked the signature of yet. A well-formed envelope carrying garbage has
    // to survive `parse` and die on `open`, not the other way around.
    Uint8List envelope(String inner) =>
        Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
          'envelope': 1,
          'signature': base64Encode(Uint8List(64)),
          'manifest': inner,
        })));

    void deferred(String label, String inner) {
      test(label, () {
        final parsed = SignedManifest.parse(envelope(inner));
        expect(parsed.signature, hasLength(64));
        expect(utf8.decode(parsed.signedBytes), inner);
        expect(parsed.open, throwsA(isA<MarinefordFormatException>()));
      });
    }

    deferred('inner payload is not JSON', 'nonsense');
    deferred('inner payload is not an object', '[1,2,3]');
    deferred('inner payload is missing every field', '{}');
    deferred(
        'inner payload has a bad version constraint',
        jsonEncode(<String, Object?>{
          ...manifest().toJson(),
          'patches': <Object?>[
            <String, Object?>{
              ...manifest().patches.single.toJson(),
              'runtime': 'not a constraint',
            },
          ],
        }));
    deferred('inner payload claims a newer schema',
        jsonEncode(<String, Object?>{...manifest().toJson(), 'schema': 99}));

    test('a manifest that fails verification is never opened', () async {
      final impostor = await PatchSigner.generate();
      final parsed = SignedManifest.parse(await publish(impostor, manifest()));

      // The client's order: check the signature, and only then read what it
      // covered. Here the check fails, so `open` is simply never reached —
      // which is the whole defence, since `open` is where an attacker's JSON
      // would otherwise get to run the parser.
      expect(
          await verifier.verify(parsed.signedBytes, parsed.signature), isFalse);
    });
  });
}
