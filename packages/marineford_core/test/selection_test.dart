import 'package:marineford_core/marineford_core.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

final abiA = 'sha256:${'a' * 64}';
final abiB = 'sha256:${'b' * 64}';

PatchEntry entry(
  int number, {
  String? abi,
  String runtime = '>=1.0.0 <2.0.0',
  double rollout = 1.0,
}) =>
    PatchEntry(
      number: number,
      url: 'patches/$number.mfp',
      size: 1024,
      sha256: 'c' * 64,
      abi: abi ?? abiA,
      runtime: VersionConstraint.parse(runtime),
      rollout: rollout,
    );

PatchManifest manifest(
  List<PatchEntry> patches, {
  Set<int> revoked = const <int>{},
  String appId = 'com.example.app',
}) =>
    PatchManifest(
      schema: 1,
      appId: appId,
      channel: 'prod',
      generatedAt: DateTime.utc(2026, 8, 10),
      patches: patches,
      revoked: revoked,
    );

SelectionContext ctx({
  String appId = 'com.example.app',
  String? abi,
  String appVersion = '1.4.0',
  String installId = 'device-1',
  int installed = 0,
  Set<int> blocklist = const <int>{},
}) =>
    SelectionContext(
      appId: appId,
      abi: abi ?? abiA,
      appVersion: Version.parse(appVersion),
      installId: installId,
      installedPatch: installed,
      blocklist: blocklist,
    );

void main() {
  group('happy path', () {
    test('picks the highest eligible patch', () {
      final d = selectPatch(manifest([entry(3), entry(7), entry(5)]), ctx());
      expect(d, isA<ApplyPatch>());
      expect((d as ApplyPatch).entry.number, 7);
    });

    test('stays put when the newest is already installed', () {
      final d = selectPatch(manifest([entry(7)]), ctx(installed: 7));
      expect(d, isA<StayOnCurrent>());
    });

    test('stays put when the manifest is empty', () {
      expect(selectPatch(manifest([]), ctx()), isA<StayOnCurrent>());
    });
  });

  group('ABI fingerprint', () {
    test('refuses a patch built against a different ABI', () {
      final d = selectPatch(manifest([entry(7, abi: abiB)]), ctx());
      expect(d, isA<StayOnCurrent>());
      expect(d.rejections.single.reason, contains('built against ABI'));
    });

    test('an ABI mismatch does not shadow an older matching patch', () {
      final d = selectPatch(manifest([entry(9, abi: abiB), entry(4)]), ctx());
      expect((d as ApplyPatch).entry.number, 4);
    });
  });

  group('version constraint', () {
    test('refuses a patch for a newer app', () {
      final d = selectPatch(
          manifest([entry(7, runtime: '>=2.0.0')]), ctx(appVersion: '1.4.0'));
      expect(d, isA<StayOnCurrent>());
      expect(d.rejections.single.reason, contains('requires app'));
    });

    test('boundaries are exclusive at the top', () {
      expect(
        selectPatch(manifest([entry(7, runtime: '>=1.0.0 <2.0.0')]),
            ctx(appVersion: '2.0.0')),
        isA<StayOnCurrent>(),
      );
      expect(
        selectPatch(manifest([entry(7, runtime: '>=1.0.0 <2.0.0')]),
            ctx(appVersion: '1.9.9')),
        isA<ApplyPatch>(),
      );
    });
  });

  group('anti-rollback', () {
    test('never moves to a lower patch number', () {
      final d = selectPatch(manifest([entry(3)]), ctx(installed: 7));
      expect(d, isA<StayOnCurrent>());
    });

    test('a replayed older patch cannot displace a newer installed one', () {
      // A compromised CDN drops #7 from the manifest and serves only #3.
      final d = selectPatch(manifest([entry(3)]), ctx(installed: 7));
      expect(d, isA<StayOnCurrent>(),
          reason: 'serving an old signed patch must not downgrade the device');
    });
  });

  group('revocation', () {
    test('a revoked patch is never selected', () {
      final d = selectPatch(manifest([entry(7)], revoked: {7}), ctx());
      expect(d, isA<StayOnCurrent>());
      expect(d.rejections.single.reason, contains('revoked'));
    });

    test(
        'revoking the installed patch falls back to base when nothing else '
        'is eligible', () {
      final d =
          selectPatch(manifest([entry(7)], revoked: {7}), ctx(installed: 7));
      expect(d, isA<RollBackToBase>());
      expect((d as RollBackToBase).reason, contains('revoked'));
    });

    test('revoking the installed patch moves down to an older good one', () {
      final d = selectPatch(
          manifest([entry(4), entry(7)], revoked: {7}), ctx(installed: 7));
      expect(d, isA<ApplyPatch>());
      expect((d as ApplyPatch).entry.number, 4,
          reason: 'moving backwards is correct only when revoked');
    });
  });

  group('local blocklist', () {
    test('a blocklisted patch is never selected', () {
      final d = selectPatch(manifest([entry(7)]), ctx(blocklist: {7}));
      expect(d, isA<StayOnCurrent>());
      expect(d.rejections.single.reason, contains('blocklisted'));
    });

    test('a blocklisted installed patch triggers rollback', () {
      final d =
          selectPatch(manifest([entry(7)]), ctx(installed: 7, blocklist: {7}));
      expect(d, isA<RollBackToBase>());
      expect((d as RollBackToBase).reason, contains('blocklisted'));
    });
  });

  group('app id', () {
    test('a manifest for another app is ignored, not acted on', () {
      final d = selectPatch(
          manifest([entry(7)], appId: 'com.other.app'), ctx(installed: 3));
      expect(d, isA<StayOnCurrent>());
      expect(d.rejections.single.reason, contains('com.other.app'));
    });

    test('a wrong-app manifest cannot be used to force a downgrade', () {
      // If this returned RollBackToBase, anyone who can swap the manifest file
      // could push every device back onto the buggy store build.
      final d =
          selectPatch(manifest([], appId: 'com.other.app'), ctx(installed: 9));
      expect(d, isA<StayOnCurrent>(),
          reason: 'the installed patch must survive a misdirected manifest');
    });
  });

  group('staged rollout', () {
    test('rollout 0 excludes everyone, rollout 1 includes everyone', () {
      for (var i = 0; i < 50; i++) {
        final c = ctx(installId: 'device-$i');
        expect(selectPatch(manifest([entry(7, rollout: 0)]), c),
            isA<StayOnCurrent>());
        expect(selectPatch(manifest([entry(7, rollout: 1)]), c),
            isA<ApplyPatch>());
      }
    });

    test('a device keeps the same answer across calls', () {
      final c = ctx(installId: 'stable-device');
      final first = selectPatch(manifest([entry(7, rollout: 0.5)]), c);
      for (var i = 0; i < 20; i++) {
        expect(selectPatch(manifest([entry(7, rollout: 0.5)]), c).runtimeType,
            first.runtimeType);
      }
    });

    test('raising the percentage only ever adds devices', () {
      // The property that makes staged rollout safe: nobody loses a patch
      // because someone nudged the number up.
      const ids = 400;
      var previous = <int>{};
      for (final pct in [0.1, 0.25, 0.5, 0.75, 1.0]) {
        final included = <int>{};
        for (var i = 0; i < ids; i++) {
          if (isInRollout('device-$i', 7, pct)) included.add(i);
        }
        expect(included.containsAll(previous), isTrue,
            reason: 'a device included at a lower percentage was dropped at '
                '$pct');
        previous = included;
      }
      expect(previous.length, ids);
    });

    test('distribution is roughly uniform', () {
      const ids = 4000;
      var included = 0;
      for (var i = 0; i < ids; i++) {
        if (isInRollout('device-$i', 7, 0.25)) included++;
      }
      expect(included / ids, closeTo(0.25, 0.03));
    });

    test('buckets differ between patches for the same device', () {
      final buckets = {for (var n = 1; n <= 20; n++) rolloutBucket('d', n)};
      expect(buckets.length, greaterThan(15),
          reason: 'a device unlucky on one patch must not be systematically '
              'unlucky on the next');
    });
  });

  test('rejections are reported for every skipped patch', () {
    final d = selectPatch(
      manifest([
        entry(9, abi: abiB),
        entry(8, runtime: '>=9.0.0'),
        entry(7, rollout: 0),
      ]),
      ctx(),
    );
    expect(d, isA<StayOnCurrent>());
    expect(d.rejections.map((r) => r.number), [9, 8, 7]);
  });
}
