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

      Patch.resetForTesting();
      final next = makeClient(activation: PatchActivation.onNextLaunch);
      await next.start();
      expect(total(20, 22), 84);
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
      expect(third.state.blocklist, contains(7));
      expect(observer.ofType<PatchBlocklisted>(), isNotEmpty);
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
      expect(client.state.blocklist, isEmpty,
          reason: 'a manual rollback is not a verdict on the patch');
    });

    test('dispose closes the transport', () async {
      final client = makeClient();
      await client.start();
      client.dispose();
      expect(cdn.closeCount, 1);
    });
  });

  group('disk hygiene', () {
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
      expect(third.state.blocklist, isEmpty,
          reason: 'a surviving file means nothing gets wrongly blocklisted');
      expect(total(1, 1), 4);
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
      expect(client.state.lastSequence, 0);
    });

    test('a successful install records both', () async {
      cdn().etag = 'W/"v1"';
      await cdn().publish({7: await cdn().buildPatch(_patchSource)});
      final client = makeClient();
      await client.start();
      await client.checkForUpdate();
      expect(client.state.manifestEtag, 'W/"v1"');
      expect(client.state.lastSequence, greaterThan(0));
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
      expect(client.state.installed, 7);
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
