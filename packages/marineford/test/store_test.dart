import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marineford/marineford.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late PatchStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('marineford_store_test');
    store = PatchStore(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('state', () {
    test('a fresh store invents a stable install id', () async {
      final first = await store.readState();
      expect(first.installId, isNotEmpty);
      expect(first.installed, 0);
      expect(first.blocklist, isEmpty);

      await store.writeState(first);
      final second = await store.readState();
      expect(second.installId, first.installId,
          reason: 'the id must survive restarts or rollout buckets move');
    });

    test('round-trips every field', () async {
      final original = PatchState(
        installId: 'abc',
        installed: 7,
        blocklist: {3, 5},
        booting: 7,
        bootAttempts: 2,
        manifestEtag: 'W/"tag"',
      );
      await store.writeState(original);
      final read = await store.readState();
      expect(read.installId, 'abc');
      expect(read.installed, 7);
      expect(read.blocklist, {3, 5});
      expect(read.booting, 7);
      expect(read.bootAttempts, 2);
      expect(read.manifestEtag, 'W/"tag"');
    });

    test('copyWith can clear the nullable fields', () {
      const original = PatchState(
          installId: 'a', booting: 7, bootAttempts: 3, manifestEtag: 'x');
      expect(original.copyWith(clearBooting: true).booting, isNull);
      expect(original.copyWith(clearEtag: true).manifestEtag, isNull);
      expect(original.copyWith(installed: 9).booting, 7,
          reason: 'unrelated fields must survive');
    });

    group('corrupt state must never brick the app', () {
      Future<void> writeRaw(String content) async {
        await root.create(recursive: true);
        File(p.join(root.path, 'state.json')).writeAsStringSync(content);
      }

      test('truncated JSON falls back to defaults', () async {
        await writeRaw('{"installed": 7, "blockl');
        final state = await store.readState();
        expect(state.installed, 0);
        expect(state.installId, isNotEmpty);
      });

      test('JSON of the wrong shape falls back to defaults', () async {
        await writeRaw('[1,2,3]');
        expect((await store.readState()).installed, 0);
      });

      test('fields of the wrong type are ignored individually', () async {
        await writeRaw(jsonEncode({
          'installId': 42,
          'installed': 'seven',
          'blocklist': ['three', 4],
          'bootAttempts': null,
        }));
        final state = await store.readState();
        expect(state.installId, isNotEmpty);
        expect(state.installed, 0);
        expect(state.blocklist, {4},
            reason: 'a junk entry should not discard the valid ones');
        expect(state.bootAttempts, 0);
      });

      test('an empty file falls back to defaults', () async {
        await writeRaw('');
        expect((await store.readState()).installed, 0);
      });
    });

    test('a write survives being interrupted', () async {
      await store.writeState(const PatchState(installId: 'a', installed: 1));
      // Simulate a crash mid-write: a stray .part file must not be picked up.
      File(p.join(root.path, 'state.json.part')).writeAsStringSync('garbage');
      final state = await store.readState();
      expect(state.installed, 1);
    });
  });

  group('patch files', () {
    Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 7));

    test('save, read and delete', () async {
      await store.savePatch(3, bytes(100));
      expect((await store.readPatch(3))?.length, 100);
      await store.deletePatch(3);
      expect(await store.readPatch(3), isNull);
    });

    test('reading a patch that was never written returns null', () async {
      expect(await store.readPatch(99), isNull);
    });

    test('deleting a patch that is not there is not an error', () async {
      await expectLater(store.deletePatch(99), completes);
    });

    test('stored patches come back highest first', () async {
      for (final n in [2, 9, 5]) {
        await store.savePatch(n, bytes(10));
      }
      expect(await store.storedPatches(), [9, 5, 2]);
    });

    test('prune keeps the newest and drops the rest', () async {
      for (final n in [1, 2, 3, 4, 5]) {
        await store.savePatch(n, bytes(10));
      }
      await store.prune(keep: 2);
      expect(await store.storedPatches(), [5, 4],
          reason: 'two is enough: the one running and one to fall back to');
    });

    test('prune on an empty store does nothing', () async {
      await expectLater(store.prune(), completes);
    });

    test('unrelated files in the patch directory are ignored', () async {
      await store.savePatch(1, bytes(10));
      File(p.join(root.path, 'patches', 'notes.txt')).writeAsStringSync('hi');
      File(p.join(root.path, 'patches', 'x.mfp')).writeAsStringSync('hi');
      expect(await store.storedPatches(), [1]);
    });

    test('clear removes everything', () async {
      await store.savePatch(1, bytes(10));
      await store.writeState(const PatchState(installId: 'a'));
      await store.clear();
      expect(root.existsSync(), isFalse);
    });
  });
}
