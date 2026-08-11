import 'dart:convert';
import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

final _abi = 'sha256:${'a' * 64}';
final _hash = 'b' * 64;

Map<String, Object?> patchJson({
  Object? number = 7,
  Object? url = 'p/7.mfp',
  Object? size = 1024,
  Object? sha256,
  Object? abi,
  Object? runtime = '>=1.0.0 <2.0.0',
  Object? rollout,
  Object? notes,
}) =>
    <String, Object?>{
      'number': number,
      'url': url,
      'size': size,
      'sha256': sha256 ?? _hash,
      'abi': abi ?? _abi,
      'runtime': runtime,
      if (rollout != null) 'rollout': rollout,
      if (notes != null) 'notes': notes,
    };

Map<String, Object?> manifestJson({
  Object? schema = 1,
  Object? app = 'com.example.app',
  Object? channel = 'prod',
  Object? sequence = 1,
  Object? generatedAt = '2026-08-10T12:00:00Z',
  Object? patches,
  Object? revoked,
}) =>
    <String, Object?>{
      'schema': schema,
      'app': app,
      'channel': channel,
      'sequence': sequence,
      'generatedAt': generatedAt,
      'patches': patches ?? [patchJson()],
      if (revoked != null) 'revoked': revoked,
    };

void main() {
  group('valid input', () {
    test('parses a complete manifest', () {
      final m = PatchManifest.fromJson(manifestJson(
        patches: [patchJson(rollout: 0.25, notes: 'pricing fix')],
        revoked: [5, 6],
      ));
      expect(m.appId, 'com.example.app');
      expect(m.channel, 'prod');
      expect(m.revoked, {5, 6});
      final p = m.patches.single;
      expect(p.number, 7);
      expect(p.rollout, 0.25);
      expect(p.notes, 'pricing fix');
      expect(p.runtime.allows(Version.parse('1.4.0')), isTrue);
    });

    test('rollout defaults to 1.0 and revoked to empty', () {
      final m = PatchManifest.fromJson(manifestJson());
      expect(m.patches.single.rollout, 1.0);
      expect(m.revoked, isEmpty);
    });

    test('unknown fields are ignored so newer publishers do not break us', () {
      final json = manifestJson(patches: [
        patchJson()..['somethingFromTheFuture'] = {'nested': true},
      ])
        ..['alsoNew'] = 42;
      expect(() => PatchManifest.fromJson(json), returnsNormally);
    });

    test('round-trips through toJson', () {
      final original = PatchManifest.fromJson(manifestJson(
        patches: [patchJson(rollout: 0.5)],
        revoked: [3],
      ));
      final again = PatchManifest.fromJson(original.toJson());
      expect(again.toJson(), original.toJson());
    });
  });

  group('schema gating', () {
    test('a newer schema is refused as unsupported, not malformed', () {
      expect(
        () => PatchManifest.fromJson(manifestJson(schema: 2)),
        throwsA(isA<UnsupportedSchemaException>()
            .having((e) => e.found, 'found', 2)
            .having((e) => e.maxSupported, 'maxSupported', 1)),
      );
    });

    test('schema 0 is malformed', () {
      expect(() => PatchManifest.fromJson(manifestJson(schema: 0)),
          throwsA(isA<ManifestFormatException>()));
    });
  });

  group('hostile and broken input', () {
    void rejects(String label, Map<String, Object?> json) {
      test(label, () {
        expect(() => PatchManifest.fromJson(json),
            throwsA(isA<MarinefordFormatException>()));
      });
    }

    test('not JSON at all', () {
      expect(
          () => SignedManifest.parse(
              Uint8List.fromList(utf8.encode('<html>404</html>'))),
          throwsA(isA<ManifestFormatException>()));
    });

    test('JSON but not an object', () {
      expect(
          () =>
              SignedManifest.parse(Uint8List.fromList(utf8.encode('[1,2,3]'))),
          throwsA(isA<ManifestFormatException>()));
    });

    rejects('missing sequence', manifestJson()..remove('sequence'));
    rejects('sequence zero', manifestJson(sequence: 0));
    rejects('sequence as string', manifestJson(sequence: '1'));

    rejects('missing schema', manifestJson()..remove('schema'));
    rejects('schema as string', manifestJson(schema: '1'));
    rejects('empty app id', manifestJson(app: ''));
    rejects('bad timestamp', manifestJson(generatedAt: 'yesterday'));
    rejects('patches not a list', manifestJson(patches: 'nope'));
    rejects('patch not an object', manifestJson(patches: ['nope']));
    rejects('revoked not a list', manifestJson(revoked: 5));
    rejects('revoked holds a string', manifestJson(revoked: ['5']));
    rejects('negative patch number',
        manifestJson(patches: [patchJson(number: -1)]));
    rejects('zero patch number', manifestJson(patches: [patchJson(number: 0)]));
    rejects('zero size', manifestJson(patches: [patchJson(size: 0)]));
    rejects('empty url', manifestJson(patches: [patchJson(url: '')]));
    rejects('short hash', manifestJson(patches: [patchJson(sha256: 'abc')]));
    rejects(
        'uppercase hash', manifestJson(patches: [patchJson(sha256: 'A' * 64)]));
    rejects('abi without prefix',
        manifestJson(patches: [patchJson(abi: 'a' * 64)]));
    rejects('abi with wrong algorithm',
        manifestJson(patches: [patchJson(abi: 'md5:${'a' * 64}')]));
    rejects('unparseable runtime constraint',
        manifestJson(patches: [patchJson(runtime: 'newer than 1')]));
    rejects(
        'rollout above 1', manifestJson(patches: [patchJson(rollout: 1.5)]));
    rejects(
        'rollout below 0', manifestJson(patches: [patchJson(rollout: -0.1)]));
    rejects('rollout as string',
        manifestJson(patches: [patchJson(rollout: '0.5')]));
    rejects('notes as number', manifestJson(patches: [patchJson(notes: 5)]));

    test('duplicate patch numbers are rejected', () {
      expect(
        () => PatchManifest.fromJson(
            manifestJson(patches: [patchJson(), patchJson()])),
        throwsA(isA<ManifestFormatException>()
            .having((e) => e.message, 'message', contains('more than once'))),
      );
    });
  });
}
