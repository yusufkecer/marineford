import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:test/test.dart';

void main() {
  final hex = 'a' * 64;

  group('parsing', () {
    test('round-trips through text', () {
      expect(AbiFingerprint.parse('sha256:$hex').toString(), 'sha256:$hex');
    });

    test('round-trips through bytes', () {
      final bytes = Uint8List(32)..fillRange(0, 32, 0xab);
      expect(AbiFingerprint.fromBytes(bytes).toBytes(), bytes);
      expect(AbiFingerprint.fromBytes(bytes).toString(), 'sha256:${'ab' * 32}');
    });

    test('text and bytes agree', () {
      final fromText = AbiFingerprint.parse('sha256:${'ab' * 32}');
      final fromBytes =
          AbiFingerprint.fromBytes(Uint8List(32)..fillRange(0, 32, 0xab));
      expect(fromText, fromBytes);
      expect(fromText.hashCode, fromBytes.hashCode);
    });
  });

  group('rejection', () {
    void rejects(String label, String value) {
      test(label, () {
        expect(() => AbiFingerprint.parse(value), throwsFormatException);
        expect(AbiFingerprint.tryParse(value), isNull);
      });
    }

    rejects('no prefix', hex);
    rejects('wrong algorithm', 'md5:$hex');
    rejects('uppercase hex', 'sha256:${'A' * 64}');
    rejects('too short', 'sha256:${'a' * 63}');
    rejects('too long', 'sha256:${'a' * 65}');
    rejects('empty', '');
    rejects('non-hex', 'sha256:${'g' * 64}');

    test('wrong byte length', () {
      // A truncated fingerprint must never silently become a different valid
      // one; that is precisely the comparison the whole mechanism rests on.
      expect(
          () => AbiFingerprint.fromBytes(Uint8List(31)), throwsFormatException);
      expect(
          () => AbiFingerprint.fromBytes(Uint8List(33)), throwsFormatException);
    });
  });

  group('comparison', () {
    test('a single differing byte is not equal', () {
      final a = AbiFingerprint.fromBytes(Uint8List(32));
      final b = AbiFingerprint.fromBytes(Uint8List(32)..[31] = 1);
      expect(a, isNot(b));
    });

    test('usable as a map key', () {
      final map = <AbiFingerprint, String>{
        AbiFingerprint.parse('sha256:$hex'): 'x',
      };
      expect(map[AbiFingerprint.parse('sha256:$hex')], 'x');
    });
  });

  test('the container and the manifest agree on one fingerprint', () {
    // The reason this type exists. The value used to be assembled separately in
    // the container header, the manifest, the generator and the CLI, and
    // nothing checked that the four agreed.
    final abi = AbiFingerprint.parse('sha256:${'cd' * 32}');
    final region = MfpContainer.buildSignedRegion(
      payload: Uint8List.fromList(<int>[1, 2, 3]),
      abi: abi,
    );
    final bytes =
        Uint8List.fromList(<int>[...region, ...Uint8List(kMfpSignatureLength)]);
    expect(MfpContainer.parse(bytes).abi, abi);
  });
}
