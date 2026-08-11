import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marineford/marineford.dart';
import 'package:marineford_core/marineford_core.dart';
import 'package:pub_semver/pub_semver.dart';

import 'support/fake_cdn.dart';

const _patchSource = '''
@RuntimeOverride('pricing#total', version: '>=1.0.0 <2.0.0')
int total(int a, int b) { return (a + b) * 2; }
''';

const _otherPatchSource = '''
@RuntimeOverride('pricing#total', version: '>=1.0.0 <2.0.0')
int total(int a, int b) { return (a + b) * 3; }
''';

/// Asserts every field of the client's persisted state, in memory and on disk.
///
/// Every blocker this suite let through was let through the same way: the test
/// checked what the call returned and stopped there. `selectPatch` was deciding
/// correctly, the assertion passed, and nobody asked what the next launch would
/// read. The sequence high-water mark was being written on a manifest the
/// client had just refused, and no test could have noticed, because no test
/// looked at it.
///
/// Two things make this close the gap by construction rather than by anyone
/// remembering. Every field is required, so a new field cannot be quietly
/// omitted from an existing assertion the way `lastSequence` was. And the check
/// runs against the file, not only the object: what the client believes is
/// worth nothing if the next launch reads something else, and a divergence
/// between the two is itself the bug in every crash-loop and replay defect
/// found here.
void expectState(
  MarinefordClient client,
  Directory root, {
  required int installed,
  required Set<int> blocklist,
  required int? booting,
  required int bootAttempts,
  required String? manifestEtag,
  required int lastSequence,
}) {
  final memory = client.state;
  expect(memory.installed, installed, reason: 'installed, in memory');
  expect(memory.blocklist, blocklist, reason: 'blocklist, in memory');
  expect(memory.booting, booting, reason: 'booting, in memory');
  expect(memory.bootAttempts, bootAttempts, reason: 'bootAttempts, in memory');
  expect(memory.manifestEtag, manifestEtag, reason: 'manifestEtag, in memory');
  expect(memory.lastSequence, lastSequence, reason: 'lastSequence, in memory');

  final file = File('${root.path}${Platform.pathSeparator}state.json');
  expect(file.existsSync(), isTrue,
      reason: 'state.json must exist; nothing survives a restart without it');

  // Read as raw JSON rather than through PatchState.fromJson, which is
  // deliberately forgiving of a corrupt file. Its tolerance would hide a write
  // that produced the wrong shape, and the written shape is the thing under
  // test.
  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  expect(json['installed'], installed, reason: 'installed, on disk');
  expect((json['blocklist']! as List).map((Object? n) => n! as int).toSet(),
      blocklist,
      reason: 'blocklist, on disk');
  expect(json['booting'], booting, reason: 'booting, on disk');
  expect(json['bootAttempts'], bootAttempts, reason: 'bootAttempts, on disk');
  expect(json['manifestEtag'], manifestEtag, reason: 'manifestEtag, on disk');
  expect(json['lastSequence'], lastSequence, reason: 'lastSequence, on disk');
  expect(json['installId'], isA<String>(),
      reason: 'a lost install id redraws the rollout bucket every launch');
}

void main() {
  late Directory root;
  late FakeCdn cdn;
  late RecordingObserver observer;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('marineford_client_test');
    cdn = await FakeCdn.create();
    observer = RecordingObserver();
  });

  tearDown(() {
    Patch.resetForTesting();
    // Windows keeps a handle open briefly after the last read; a failed cleanup
    // of a temp directory is not a test failure.
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // ignored
    }
  });

  MarinefordClient makeClient({
    String appVersion = '1.4.0',
    String? abi,
    PatchActivation activation = PatchActivation.immediate,
    int maxBootAttempts = 2,
    int failureThreshold = 5,
  }) =>
      MarinefordClient(
        config: MarinefordConfig(
          appId: 'com.example.app',
          appVersion: Version.parse(appVersion),
          abi: abi ?? cdn.abi.toString(),
          manifestUrl: cdn.manifestUrl,
          publicKey: cdn.publicKey,
          activation: activation,
          autoConfirmBootAfter: null,
          maxBootAttempts: maxBootAttempts,
          failureThreshold: failureThreshold,
          observer: observer,
        ),
        store: PatchStore(root),
        transport: cdn,
      );

  /// Calls the patched function the way a generated shim would.
  int total(int a, int b) {
    final slot = Patch.slot('pricing#total');
    if (slot != null) {
      final result = Patch.invoke2(slot, a, b, 'pricing#total');
      if (result != null) return result as int;
    }
    return a + b; // the original
  }

  _rejectedManifestState(
    root: () => root,
    cdn: () => cdn,
    makeClient: makeClient,
    total: total,
  );

  _gaps(
    root: () => root,
    cdn: () => cdn,
    observer: () => observer,
    makeClient: makeClient,
    total: total,
  );

  group('happy path', () {
    test('downloads, verifies, installs and dispatches', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();

      expect(total(20, 22), 42, reason: 'no patch yet');

      final decision = await client.checkForUpdate();
      expect(decision, isA<ApplyPatch>());
      expect(total(20, 22), 84, reason: 'the patch doubles the total');
      expect(client.activePatch, 7);

      expect(observer.ofType<PatchInstalled>().single.number, 7);
      expect(observer.ofType<PatchActivated>().single.number, 7);

      expectState(client, root,
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('the patch survives a restart', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final first = makeClient();
      await first.start();
      await first.checkForUpdate();
      await first.markBootSuccessful();
      Patch.resetForTesting();

      final second = makeClient();
      await second.start();
      expect(total(20, 22), 84,
          reason: 'an installed patch must come back on the next launch');
      expect(second.activePatch, 7);
      // The second run reads from disk; it must not re-download.
      expect(cdn.requests.where((r) => r.endsWith('.mfp')).length, 1);

      // Re-armed, not inherited. markBootSuccessful cleared the token at the
      // end of the first run; activating the patch again puts it back on trial
      // for this run, because a patch that survived one launch can still take
      // down the next. The count starts from one each time — that is what makes
      // the guard measure consecutive failures rather than lifetime ones.
      expectState(second, root,
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('onNextLaunch leaves the running app alone', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient(activation: PatchActivation.onNextLaunch);
      await client.start();
      await client.checkForUpdate();

      expect(total(20, 22), 42,
          reason: 'the download must not change behaviour mid-session');
      expect(observer.ofType<PatchInstalled>(), hasLength(1));
      expect(observer.ofType<PatchActivated>(), isEmpty);

      // Installed but deliberately not booting: nothing was activated this
      // session, so there is no launch to judge healthy or otherwise.
      expectState(client, root,
          installed: 7,
          blocklist: const <int>{},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 1);

      Patch.resetForTesting();
      final next = makeClient(activation: PatchActivation.onNextLaunch);
      await next.start();
      expect(total(20, 22), 84);

      expectState(next, root,
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('a newer patch replaces an older one', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(total(1, 1), 4);

      await cdn.publish({
        7: await cdn.buildPatch(_patchSource),
        8: await cdn.buildPatch(_otherPatchSource),
      });
      await client.checkForUpdate();
      expect(total(1, 1), 6);
      expect(client.activePatch, 8);

      // The second publish advances the sequence, and the boot token moves to
      // the patch that is now on trial rather than staying on the old one.
      expectState(client, root,
          installed: 8,
          blocklist: const <int>{},
          booting: 8,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 2);
    });

    test('a second check with an unchanged manifest costs one 304', () async {
      cdn.etag = 'W/"v7"';
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      cdn.requests.clear();
      final decision = await client.checkForUpdate();
      expect(decision, isA<StayOnCurrent>());
      expect(cdn.requests, ['/prod/manifest.json'],
          reason: 'a 304 must not pull the signature or any patch');

      // A 304 returns before the decision switch, so nothing it might have
      // written can have moved.
      expectState(client, root,
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: 'W/"v7"',
          lastSequence: 1);
    });
  });

  group('refusing bad patches', () {
    test('a tampered container is refused and blocklisted', () async {
      final good = await cdn.buildPatch(_patchSource);
      await cdn.publish({7: good});
      // Flip a byte inside the payload but keep the manifest hash honest, so
      // the only thing that can catch this is the signature.
      final tampered = Uint8List.fromList(good);
      tampered[60] ^= 0x01;
      await cdn.publish({7: tampered});

      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      expect(total(20, 22), 42);
      expect(client.activePatch, 0);
      expect(observer.ofType<PatchBlocklisted>().single.reason,
          contains('signature'));

      // Blocklisted, because these bytes will never be acceptable and fetching
      // them again cannot change that. The sequence stays at zero: the decision
      // was never carried out, so the manifest is not recorded as handled and
      // the next check will look at it again.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{7},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 0);
    });

    test('a hash mismatch is caught before anything is parsed', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      cdn.corrupt('/prod/7.mfp', Uint8List.fromList(List.filled(200, 0x41)));

      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      expect(client.activePatch, 0);
      final rejected = observer.ofType<PatchRejectedEvent>().last;
      expect(rejected.reason, anyOf(contains('sha256'), contains('bytes')));

      // Not blocklisted, and the difference from the tampered case is the whole
      // point. A hash mismatch says the *transfer* was wrong — a truncated
      // response, a cache serving something stale — and the bytes on the CDN
      // may well be fine. Remembering this patch as broken would refuse a good
      // one forever over one bad download. A signature failure is the opposite:
      // those bytes are not acceptable and never will be.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 0);
    });

    test('a patch for a different ABI is refused', () async {
      final otherAbi = AbiFingerprint.parse('sha256:${'b' * 64}');
      await cdn.publish(
        {7: await cdn.buildPatch(_patchSource, abiOverride: otherAbi)},
        abiPerPatch: {7: otherAbi},
      );
      final client = makeClient();
      await client.start();
      final decision = await client.checkForUpdate();

      expect(decision, isA<StayOnCurrent>());
      expect(decision.rejections.single.reason, contains('ABI'));
      expect(client.activePatch, 0);

      // Nothing was wrong with the *manifest*, so the sequence advances and a
      // later manifest is still expected. What must not happen is a blocklist
      // entry: the patch is fine, it is simply for a different build, and
      // remembering it as broken would refuse it forever on the build it fits.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('a v2 patch needing the Flutter bridge is refused, not crashed on',
        () async {
      final patch =
          await cdn.buildPatch(_patchSource, flags: const MfpFlags(1 | 1 << 1));
      await cdn.publish({7: patch});

      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      expect(client.activePatch, 0);
      expect(observer.ofType<PatchBlocklisted>().single.reason,
          contains('newer marineford'));
    });

    test('a manifest signed by the wrong key is ignored', () async {
      // A whole channel published by someone else's key, served at our URL.
      final impostor = await FakeCdn.create(abi: cdn.abi);
      await impostor.publish({7: await impostor.buildPatch(_patchSource)});
      cdn.corrupt(
          '/prod/manifest.json', (await impostor.get(cdn.manifestUrl)).body);

      final client = makeClient();
      await client.start();
      final decision = await client.checkForUpdate();

      expect(decision, isA<StayOnCurrent>());
      expect(observer.ofType<PatchRejectedEvent>().last.reason,
          contains('signature'));
      expect(impostor.publicKey, isNot(cdn.publicKey));

      // A manifest that failed verification must leave no trace at all — not
      // its sequence, which would let a replay walk the high-water mark, and
      // not its ETag, which would turn every later check into a 304 and make
      // the refusal permanent.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 0);
    });

    test('a patch outside the app version range is refused', () async {
      await cdn.publish(
        {7: await cdn.buildPatch(_patchSource)},
        runtime: '>=2.0.0 <3.0.0',
      );
      final client = makeClient(appVersion: '1.4.0');
      await client.start();
      final decision = await client.checkForUpdate();

      expect(decision, isA<StayOnCurrent>());
      expect(decision.rejections.single.reason, contains('requires app'));
    });

    test('a revoked patch is rolled back', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(total(1, 1), 4);

      await cdn.publish({7: await cdn.buildPatch(_patchSource)}, revoked: {7});
      final decision = await client.checkForUpdate();

      expect(decision, isA<RollBackToBase>());
      expect(total(1, 1), 2, reason: 'the original code must be back');
      expect(client.activePatch, 0);

      // A revocation is the publisher's decision, not this device's, so the
      // patch is uninstalled but not blocklisted — a later manifest that
      // un-revokes it can bring it back. The boot token has to be cleared with
      // it, or the next launch counts a failure against a patch that is no
      // longer even installed.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 2);
    });
  });

  group('network problems never break the app', () {
    test('a 500 on the manifest leaves everything alone', () async {
      cdn.manifestStatusOverride = 500;
      final client = makeClient();
      await client.start();
      final decision = await client.checkForUpdate();

      expect(decision, isA<StayOnCurrent>());
      expect(observer.ofType<PatchCheckFailed>(), hasLength(1));
    });

    test('a network failure mid-check leaves everything alone', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      cdn.failOnce.add('/prod/manifest.json');

      final client = makeClient();
      await client.start();
      expect(await client.checkForUpdate(), isA<StayOnCurrent>());
      expect(observer.ofType<PatchCheckFailed>(), hasLength(1));
    });

    test('a missing patch file leaves the previous one running', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(total(1, 1), 4);

      await cdn.publish({
        7: await cdn.buildPatch(_patchSource),
        8: await cdn.buildPatch(_otherPatchSource),
      });
      cdn.remove('/prod/8.mfp');
      await client.checkForUpdate();

      expect(total(1, 1), 4, reason: 'patch 7 must keep running');
    });

    test('garbage instead of a manifest is refused', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      cdn.corrupt('/prod/manifest.json',
          Uint8List.fromList('<html>504</html>'.codeUnits));

      final client = makeClient();
      await client.start();
      expect(await client.checkForUpdate(), isA<StayOnCurrent>());
    });
  });

  group('crash-loop guard', () {
    Future<void> simulateFailedBoot(MarinefordClient client) async {
      // Activation writes the boot token; never calling markBootSuccessful is
      // what a crash before the app became usable looks like.
      Patch.resetForTesting();
    }

    test('two failed boots blocklist the patch for good', () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});

      final first = makeClient();
      await first.start();
      await first.checkForUpdate();
      expect(total(1, 1), 4);
      await simulateFailedBoot(first);

      final second = makeClient();
      await second.start();
      expect(total(1, 1), 4, reason: 'one failure earns a retry');
      await simulateFailedBoot(second);

      final third = makeClient();
      await third.start();
      expect(total(1, 1), 2,
          reason: 'after the second failed boot the patch is abandoned');
      expect(observer.ofType<PatchBlocklisted>(), isNotEmpty);

      // The guard's whole job is to leave a record that outlives the process.
      // Checking only that the third run fell back would pass just as well if
      // the blocklist were never written, and the fourth launch would install
      // the patch all over again.
      expectState(third, root,
          installed: 0,
          blocklist: const <int>{7},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('a blocklisted patch is not reinstalled from the same manifest',
        () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      for (var i = 0; i < 3; i++) {
        final client = makeClient();
        await client.start();
        await client.checkForUpdate();
        Patch.resetForTesting();
      }

      final client = makeClient();
      await client.start();
      final decision = await client.checkForUpdate();
      expect(decision, isA<StayOnCurrent>());
      expect(decision.rejections.single.reason, contains('blocklisted'));
      expect(total(1, 1), 2);

      // Refusing the patch is not enough on its own: the refusal has to be
      // durable, and re-reading the same manifest must not quietly re-arm a
      // boot attempt for something that is never going to be installed.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{7},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('a healthy boot clears the token so the count does not creep up',
        () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      for (var i = 0; i < 5; i++) {
        final client = makeClient();
        await client.start();
        await client.checkForUpdate();
        await client.markBootSuccessful();
        expect(client.state.booting, isNull);
        expect(client.state.blocklist, isEmpty);
        Patch.resetForTesting();
      }
      final client = makeClient();
      await client.start();
      expect(total(1, 1), 4, reason: 'five healthy runs must not blocklist');

      // The defect this covers cleared the boot token on the retry path, so
      // bootAttempts reset on every launch and the count never reached the
      // threshold. It shows up only as a number on disk — the patch kept
      // working, which is exactly why nothing else noticed.
      expectState(client, root,
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 1);
    });
  });

  group('runtime failures', () {
    const throwingPatch = '''
@RuntimeOverride('pricing#total', version: '>=1.0.0 <2.0.0')
int total(int a, int b) { return a ~/ 0; }
''';

    test('a throwing patch falls back and is eventually abandoned', () async {
      await cdn.publish({7: await cdn.buildPatch(throwingPatch)});
      final client = makeClient(failureThreshold: 3);
      await client.start();
      await client.checkForUpdate();

      expect(total(1, 1), 2, reason: 'the original result, not a crash');
      expect(total(1, 1), 2);
      expect(total(1, 1), 2);

      expect(Patch.isActive, isFalse);
      expect(observer.ofType<PatchFailure>(), hasLength(3));
      await pumpEventQueue();
      expect(
          observer.ofType<PatchBlocklisted>().single.reason, contains('threw'));

      // The event fires synchronously; the write that backs it does not, and
      // pumping the event queue is not enough to land a file write. Waiting on
      // the event alone is what let this test pass while the durable half of
      // the decision was still in flight.
      await client.settled;

      // Dropping the patch for the rest of the session is only half of it. If
      // the verdict is not written down, the next launch installs the same
      // throwing patch and pays the failures again, forever.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{7},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 1);
    });
  });

  group('manual control', () {
    test('rollback returns to the original code without blocklisting',
        () async {
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(total(1, 1), 4);

      await client.rollback();
      expect(total(1, 1), 2);

      // A manual rollback is not a verdict on the patch: nothing is
      // blocklisted, so the same manifest can install it again. The sequence
      // stays where the successful check left it, because the rollback did not
      // read a manifest at all.
      expectState(client, root,
          installed: 0,
          blocklist: const <int>{},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('dispose closes the transport', () async {
      final client = makeClient();
      await client.start();
      client.dispose();
      expect(cdn.closeCount, 1);
    });
  });

  group('disk hygiene', () {
    test('a check that changes nothing does not rewrite the state file',
        () async {
      // The common case by a wide margin: the app checks, the manifest is the
      // one it already acted on, and there is nothing to do. Rewriting an
      // identical file costs a create, an fsync and a rename each time.
      //
      // Proved by leaving a marker in the file that the client's in-memory
      // state does not contain. If a write happens the marker is gone; if it
      // survives, the client genuinely left the disk alone.
      await cdn.publish({7: await cdn.buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      final file = File('${root.path}${Platform.pathSeparator}state.json');
      final saved = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      file.writeAsStringSync(jsonEncode(<String, Object?>{
        ...saved,
        'canary': 'untouched',
      }));

      expect(await client.checkForUpdate(), isA<StayOnCurrent>());

      expect(
        jsonDecode(file.readAsStringSync()),
        containsPair('canary', 'untouched'),
      );
    });

    test('a check that does change something still writes', () async {
      // The other half. A guard that skipped too much would be far worse than
      // the write it saves: the sequence and the ETag are what stop a replay
      // and a redundant download.
      await cdn.publish({7: await cdn.buildPatch(_patchSource)}, sequence: 3);
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      await cdn
          .publish({8: await cdn.buildPatch(_otherPatchSource)}, sequence: 4);
      await client.checkForUpdate();

      final file = File('${root.path}${Platform.pathSeparator}state.json');
      expect(
        jsonDecode(file.readAsStringSync()),
        allOf(containsPair('lastSequence', 4), containsPair('installed', 8)),
      );
    });

    test('only the two newest patches are kept', () async {
      final store = PatchStore(root);
      for (var n = 5; n <= 9; n++) {
        await cdn.publish({n: await cdn.buildPatch(_patchSource)});
        final client = makeClient();
        await client.start();
        await client.checkForUpdate();
        await client.markBootSuccessful();
        Patch.resetForTesting();
      }
      expect(await store.storedPatches(), hasLength(lessThanOrEqualTo(2)));
    });

    test('pruning never deletes the patch that was just installed', () async {
      // The case ranking by number alone gets wrong. After a revocation the
      // client moves *backwards*, so the newly installed patch is no longer the
      // highest on disk — and deleting it makes the next launch find the file
      // missing and blocklist a patch that was never broken.
      final store = PatchStore(root);
      final good = await cdn.buildPatch(_patchSource);
      final newer = await cdn.buildPatch(_otherPatchSource);

      await cdn.publish({4: good, 7: newer});
      final first = makeClient();
      await first.start();
      await first.checkForUpdate();
      await first.markBootSuccessful();
      expect(first.state.installed, 7);
      Patch.resetForTesting();

      await cdn.publish({4: good, 7: newer}, revoked: {7});
      final second = makeClient();
      await second.start();
      await second.checkForUpdate();
      expect(second.state.installed, 4);
      expect(await store.readPatch(4), isNotNull,
          reason: 'the patch the client just rolled back onto must survive');
      Patch.resetForTesting();

      final third = makeClient();
      await third.start();
      expect(total(1, 1), 4);

      // The whole defect was a blocklist entry appearing for a patch that had
      // never misbehaved, one launch after a rollback deleted its file. It is
      // invisible in this session's behaviour and visible only here.
      //
      // Two boot attempts on #4, not one: the second run installed it and never
      // confirmed a healthy boot, so this run is its second trial. That is the
      // guard working — an unconfirmed launch is exactly what it counts.
      expectState(third, root,
          installed: 4,
          blocklist: const <int>{},
          booting: 4,
          bootAttempts: 2,
          manifestEtag: null,
          lastSequence: 2);
    });
  });
}

/// Gaps the review named, each pinned to the defect it covers.
void _gaps({
  required Directory Function() root,
  required FakeCdn Function() cdn,
  required RecordingObserver Function() observer,
  required MarinefordClient Function({
    String appVersion,
    String? abi,
    PatchActivation activation,
    int maxBootAttempts,
    int failureThreshold,
  }) makeClient,
  required int Function(int, int) total,
}) {
  group('a failed download does not wedge the device', () {
    test('the ETag is not recorded until the decision is carried out',
        () async {
      // The bug: the ETag was written before the download ran. A transient
      // failure then left the client sending If-None-Match for a manifest it
      // never finished with, getting a 304 forever, and never retrying.
      cdn().etag = 'W/"v1"';
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      cdn().failOnce.add('/prod/7.mfp');

      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(client.state.manifestEtag, isNull,
          reason: 'nothing was installed, so nothing should be remembered');
      expect(total(1, 1), 2);

      // Second attempt, same unchanged manifest. It must actually retry.
      final decision = await client.checkForUpdate();
      expect(decision, isA<ApplyPatch>());
      expect(total(1, 1), 4);
    });

    test('a rejected patch does not advance the sequence either', () async {
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      cdn().corrupt('/prod/7.mfp', Uint8List.fromList(List.filled(200, 0x41)));

      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      // The pair that has to move together. Recording the sequence for a
      // manifest whose patch never installed would mark it handled, and the
      // retry would then find nothing left to do.
      expectState(client, root(),
          installed: 0,
          blocklist: const <int>{},
          booting: null,
          bootAttempts: 0,
          manifestEtag: null,
          lastSequence: 0);
    });

    test('a successful install records both', () async {
      cdn().etag = 'W/"v1"';
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      expectState(client, root(),
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: 'W/"v1"',
          lastSequence: 1);
    });
  });

  group('concurrent checks', () {
    test('overlapping calls share one check rather than racing', () async {
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();

      final results = await Future.wait(<Future<PatchDecision>>[
        client.checkForUpdate(),
        client.checkForUpdate(),
        client.checkForUpdate(),
      ]);

      expect(results.every((d) => d is ApplyPatch), isTrue);
      expect(
        cdn().requests.where((r) => r.endsWith('manifest.json')).length,
        1,
        reason: 'three overlapping calls must not fetch three times, and must '
            'not read-modify-write the same state concurrently',
      );

      // One check's worth of state, not three interleaved read-modify-writes
      // racing to clobber each other's fields.
      expectState(client, root(),
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 1);
    });

    test('a later call still runs after the first completes', () async {
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      cdn().requests.clear();
      await client.checkForUpdate();
      expect(cdn().requests, isNotEmpty);
    });
  });

  group('a throwing observer cannot break the client', () {
    test('the patch still installs and dispatches', () async {
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      final client = MarinefordClient(
        config: MarinefordConfig(
          appId: 'com.example.app',
          appVersion: Version.parse('1.4.0'),
          abi: cdn().abi.toString(),
          manifestUrl: cdn().manifestUrl,
          publicKey: cdn().publicKey,
          activation: PatchActivation.immediate,
          autoConfirmBootAfter: null,
          observer: _ThrowingObserver(),
        ),
        store: PatchStore(root()),
        transport: cdn(),
      );
      await client.start();
      expect(await client.checkForUpdate(), isA<ApplyPatch>());
      expect(total(1, 1), 4);
    });
  });
}

final class _ThrowingObserver implements PatchObserver {
  @override
  void onEvent(PatchEvent event) => throw StateError('observer is broken');
}

/// Second review round: what a rejected manifest leaves behind.
void _rejectedManifestState({
  required Directory Function() root,
  required FakeCdn Function() cdn,
  required MarinefordClient Function({
    String appVersion,
    String? abi,
    PatchActivation activation,
    int maxBootAttempts,
    int failureThreshold,
  }) makeClient,
  required int Function(int, int) total,
}) {
  group('a rejected manifest changes nothing', () {
    test('a stale manifest cannot lower the sequence high-water mark',
        () async {
      // Two-step replay. Serving a pre-revocation manifest once was supposed to
      // be refused; if the refusal still records that manifest's sequence, the
      // second serving of the very same bytes is accepted and the revocation
      // never arrives. The defence would destroy itself after one attempt.
      await cdn()
          .publish({7: await cdn().buildPatch(_patchSource)}, sequence: 9);
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(client.state.lastSequence, 9);
      expect(total(1, 1), 4);

      // The attacker replays an older, still validly signed manifest.
      await cdn().publish({7: await cdn().buildPatch(_patchSource)},
          revoked: <int>{}, sequence: 5);
      final first = await client.checkForUpdate();
      expect(first, isA<ManifestRejected>());
      expect(client.state.lastSequence, 9,
          reason: 'refusing a manifest must not adopt its sequence');

      // Same bytes again. Still refused.
      final second = await client.checkForUpdate();
      expect(second, isA<ManifestRejected>());
      expect((second as ManifestRejected).reason, contains('stale'));

      // Not one field: the entire record has to be where the accepted manifest
      // left it. A refusal that moved anything at all — the ETag, the boot
      // token, the installed number — would be a refusal that the attacker got
      // something out of.
      expectState(client, root(),
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 9);
    });

    test('a manifest for another app cannot move this app\'s sequence',
        () async {
      await cdn()
          .publish({7: await cdn().buildPatch(_patchSource)}, sequence: 9);
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      await cdn().publish({7: await cdn().buildPatch(_patchSource)},
          appId: 'com.other.app', sequence: 2);
      await client.checkForUpdate();

      expectState(client, root(),
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 9);
    });

    test('a refused manifest does not record its ETag either', () async {
      cdn().etag = 'W/"good"';
      await cdn()
          .publish({7: await cdn().buildPatch(_patchSource)}, sequence: 9);
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();

      cdn().etag = 'W/"stale"';
      await cdn()
          .publish({7: await cdn().buildPatch(_patchSource)}, sequence: 5);
      await client.checkForUpdate();

      // Caching a manifest the client refused would make the refusal permanent:
      // every later check becomes a 304 and the real manifest never gets read.
      expectState(client, root(),
          installed: 7,
          blocklist: const <int>{},
          booting: 7,
          bootAttempts: 1,
          manifestEtag: 'W/"good"',
          lastSequence: 9);
    });

    test('a CDN that stops sending ETags does not leave a stale one behind',
        () async {
      // copyWith treats null as "unchanged", which is why it has an explicit
      // clear flag. A caller that forgets it leaves the device sending
      // If-None-Match for a manifest the server no longer tags.
      cdn().etag = 'W/"v1"';
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(client.state.manifestEtag, 'W/"v1"');

      cdn().etag = null;
      await cdn().publish({8: await cdn().buildPatch(_otherPatchSource)});
      await client.checkForUpdate();

      // The server stopped tagging; the client must stop asking.
      expectState(client, root(),
          installed: 8,
          blocklist: const <int>{},
          booting: 8,
          bootAttempts: 1,
          manifestEtag: null,
          lastSequence: 2);
    });
  });
}
