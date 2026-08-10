import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:test/test.dart';

Uint8List abiHash([int fill = 0xab]) => Uint8List(32)..fillRange(0, 32, fill);

/// Builds a complete, structurally valid container. The signature is garbage —
/// these tests are about framing, not crypto.
Uint8List build({
  Uint8List? payload,
  MfpFlags flags = MfpFlags.gzip,
  int schema = 1,
}) {
  final region = MfpContainer.buildSignedRegion(
    payload: payload ?? Uint8List.fromList([1, 2, 3, 4, 5]),
    abiHash: abiHash(),
    flags: flags,
    schema: schema,
  );
  return Uint8List.fromList([...region, ...Uint8List(kMfpSignatureLength)]);
}

void main() {
  group('round trip', () {
    test('parses what buildSignedRegion produced', () {
      final payload = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final c = MfpContainer.parse(build(payload: payload));
      expect(c.schema, 1);
      expect(c.flags.has(MfpFlags.gzip), isTrue);
      expect(c.payload, payload);
      expect(c.abiHash, abiHash());
      expect(c.abi, 'sha256:${'ab' * 32}');
      expect(c.signature.length, kMfpSignatureLength);
    });

    test('an empty payload is legal', () {
      final c = MfpContainer.parse(build(payload: Uint8List(0)));
      expect(c.payload, isEmpty);
    });

    test('signedRegion excludes exactly the signature', () {
      final bytes = build();
      final c = MfpContainer.parse(bytes);
      expect(c.signedRegion.length, bytes.length - kMfpSignatureLength);
      expect(c.signedRegion, bytes.sublist(0, bytes.length - 64));
    });

    test('buildSignedRegion rejects a wrong-sized ABI hash', () {
      expect(
        () => MfpContainer.buildSignedRegion(
            payload: Uint8List(4), abiHash: Uint8List(16)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('malformed input', () {
    test('empty file', () {
      expect(() => MfpContainer.parse(Uint8List(0)),
          throwsA(isA<MfpFormatException>()));
    });

    test('shorter than the minimum', () {
      expect(() => MfpContainer.parse(Uint8List(kMfpMinLength - 1)),
          throwsA(isA<MfpFormatException>()));
    });

    test('wrong magic — an HTML error page served instead of a patch', () {
      final html = Uint8List.fromList(
          '<!doctype html><title>404</title>${' ' * 200}'.codeUnits);
      expect(
        () => MfpContainer.parse(html),
        throwsA(isA<MfpFormatException>()
            .having((e) => e.message, 'message', contains('MFP1 magic'))),
      );
    });

    test('payload length longer than the file — truncated download', () {
      final bytes = build();
      ByteData.view(bytes.buffer).setUint32(40, 999999, Endian.little);
      expect(
        () => MfpContainer.parse(bytes),
        throwsA(isA<MfpFormatException>()
            .having((e) => e.message, 'message', contains('declares'))),
      );
    });

    test('payload length shorter than the file — trailing junk appended', () {
      final bytes = build();
      ByteData.view(bytes.buffer).setUint32(40, 1, Endian.little);
      expect(
          () => MfpContainer.parse(bytes), throwsA(isA<MfpFormatException>()));
    });

    test('a newer container schema is refused', () {
      expect(() => MfpContainer.parse(build(schema: 2)),
          throwsA(isA<MfpFormatException>()));
    });
  });

  group('forward compatibility', () {
    test('a v2 patch needing the Flutter bridge is refused cleanly', () {
      // The whole reason bit 1 is reserved in v1: this must be a typed
      // rejection, not a crash halfway through loading.
      expect(
        () => MfpContainer.parse(build(flags: MfpFlags.flutterBridge)),
        throwsA(isA<UnsupportedFlagsException>()
            .having((e) => e.message, 'message', contains('newer marineford'))),
      );
    });

    test('unknown high flag bits are refused', () {
      expect(() => MfpContainer.parse(build(flags: const MfpFlags(1 << 9))),
          throwsA(isA<UnsupportedFlagsException>()));
    });

    test('a client that supports a bit accepts it', () {
      final c = MfpContainer.parse(
        build(flags: const MfpFlags(1 | 1 << 1)),
        supported: const MfpFlags(1 | 1 << 1),
      );
      expect(c.flags.has(MfpFlags.flutterBridge), isTrue);
    });

    test('flags report exactly which bits were not understood', () {
      expect(const MfpFlags(1 | 1 << 1 | 1 << 5).unsupportedBits,
          (1 << 1) | (1 << 5));
      expect(MfpFlags.gzip.unsupportedBits, 0);
    });
  });
}
