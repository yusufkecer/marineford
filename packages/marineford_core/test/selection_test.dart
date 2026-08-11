import 'package:marineford_core/marineford_core.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

final abiA = AbiFingerprint.parse("sha256:${"a" * 64}");
final abiB = AbiFingerprint.parse("sha256:${"b" * 64}");

PatchEntry entry(
  int number, {
  AbiFingerprint? abi,
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
  String channel = 'prod',
  int sequence = 1,
}) =>
    PatchManifest(
      schema: 1,
      appId: appId,
      channel: channel,
      sequence: sequence,
      generatedAt: DateTime.utc(2026, 8, 10),
      patches: patches,
      revoked: revoked,
    );

SelectionContext ctx({
  String appId = 'com.example.app',
  String channel = 'prod',
  AbiFingerprint? abi,
  String appVersion = '1.4.0',
  String installId = 'device-1',
  int installed = 0,
  Set<int> blocklist = const <int>{},
  int lastSequence = 0,
}) =>
    SelectionContext(
      appId: appId,
      channel: channel,
      abi: abi ?? abiA,
      appVersion: Version.parse(appVersion),
      installId: installId,
      installedPatch: installed,
      blocklist: blocklist,
      lastSequence: lastSequence,
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
      expect(d, isA<ManifestRejected>());
      expect((d as ManifestRejected).reason, contains('com.other.app'));
    });

    test('a wrong-app manifest cannot be used to force a downgrade', () {
      // If this returned RollBackToBase, anyone who can swap the manifest file
      // could push every device back onto the buggy store build.
      final d =
          selectPatch(manifest([], appId: 'com.other.app'), ctx(installed: 9));
      expect(d, isA<ManifestRejected>(),
          reason: 'the installed patch must survive a misdirected manifest');
    });
  });

  group('channel', () {
    test('a manifest for another channel is ignored', () {
      // Nothing else compares these. The client's channel names a directory on
      // disk; the manifest URL is configured separately and neither knows about
      // the other. A prod build pointed at a beta URL installed beta patches
      // and filed them under prod, with every layer agreeing.
      final d = selectPatch(
          manifest([entry(7)], channel: 'beta'), ctx(channel: 'prod'));
      expect(d, isA<ManifestRejected>());
      expect((d as ManifestRejected).reason, contains('beta'));
    });

    test('the matching channel is accepted', () {
      final d = selectPatch(
          manifest([entry(7)], channel: 'beta'), ctx(channel: 'beta'));
      expect(d, isA<ApplyPatch>());
    });

    test('a wrong-channel manifest cannot force a downgrade either', () {
      // Same reasoning as the app id: a rollback here would let anyone who can
      // swap a manifest push every device back onto the store build.
      final d = selectPatch(
          manifest([], channel: 'beta'), ctx(channel: 'prod', installed: 9));
      expect(d, isA<ManifestRejected>());
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

  _gaps();

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

/// The gaps the review named, each pinned to the defect it covers.
void _gaps() {
  group('stale manifests', () {
    test('the same sequence is not treated as an attack', () {
      // Re-reading an unchanged manifest is the normal case, not a replay.
      // The decision still stands; nothing about it is suspicious.
      final d =
          selectPatch(manifest([entry(7)], sequence: 5), ctx(lastSequence: 5));
      expect(d, isA<ApplyPatch>());
      expect(d.rejections, isEmpty);
    });

    test('a manifest below the accepted sequence is ignored', () {
      final d =
          selectPatch(manifest([entry(7)], sequence: 3), ctx(lastSequence: 5));
      expect(d, isA<ManifestRejected>());
    });

    test('replaying a pre-revocation manifest cannot un-revoke a patch', () {
      // The attack the sequence exists for. Signatures never expire, so an
      // attacker holding the manifest published just before a revocation could
      // otherwise serve it forever and the kill switch would never arrive.
      final beforeRevocation = manifest([entry(7)], sequence: 4);
      final d =
          selectPatch(beforeRevocation, ctx(installed: 7, lastSequence: 5));
      expect(d, isA<ManifestRejected>());
      expect((d as ManifestRejected).reason, contains('replay'));
    });

    test('a newer sequence is accepted', () {
      final d =
          selectPatch(manifest([entry(7)], sequence: 6), ctx(lastSequence: 5));
      expect(d, isA<ApplyPatch>());
    });

    test('a wholesale refusal is its own decision, not a patch rejection', () {
      // The distinction the client depends on: "I read this and nothing
      // applied" is worth recording, "I refused this" is not.
      final d = selectPatch(manifest([], sequence: 1), ctx(lastSequence: 9));
      expect(d, isA<ManifestRejected>());
      expect(d.rejections, isEmpty);
    });
  });

  group('revoked and blocklisted together', () {
    test('a patch both revoked and blocklisted is rejected once', () {
      final d =
          selectPatch(manifest([entry(7)], revoked: {7}), ctx(blocklist: {7}));
      expect(d, isA<StayOnCurrent>());
      expect(d.rejections, hasLength(1));
    });

    test('the installed patch being both still rolls back', () {
      final d = selectPatch(manifest([entry(7)], revoked: {7}),
          ctx(installed: 7, blocklist: {7}));
      expect(d, isA<RollBackToBase>());
      // Revocation is the publisher's verdict and the more useful one to
      // report when both apply.
      expect((d as RollBackToBase).reason, contains('revoked'));
    });
  });

  group('empty manifests', () {
    test('an empty manifest with the installed patch revoked rolls back', () {
      final d = selectPatch(manifest([], revoked: {7}), ctx(installed: 7));
      expect(d, isA<RollBackToBase>());
    });

    test('an empty manifest with nothing installed does nothing', () {
      expect(selectPatch(manifest([]), ctx()), isA<StayOnCurrent>());
    });

    test('an empty manifest does not disturb a healthy installed patch', () {
      expect(
          selectPatch(manifest([]), ctx(installed: 7)), isA<StayOnCurrent>());
    });
  });

  group('rollout boundaries', () {
    test('a NaN rollout is refused at parse time, never reaching selection',
        () {
      expect(
        () => PatchEntry.fromJson(<String, Object?>{
          'number': 1,
          'url': 'a.mfp',
          'size': 10,
          'sha256': 'c' * 64,
          'abi': abiA.toString(),
          'runtime': '>=1.0.0',
          'rollout': double.nan,
        }),
        throwsA(isA<ManifestFormatException>()),
      );
    });

    test('exactly 0 and exactly 1 behave as the extremes', () {
      for (var i = 0; i < 30; i++) {
        final c = ctx(installId: 'device-$i');
        expect(selectPatch(manifest([entry(7, rollout: 0.0)]), c),
            isA<StayOnCurrent>());
        expect(selectPatch(manifest([entry(7, rollout: 1.0)]), c),
            isA<ApplyPatch>());
      }
    });

    test('a bucket exactly on the boundary is excluded, not included', () {
      // isInRollout is `bucket < fraction * buckets`, so a device whose bucket
      // equals the cutoff must be out. Off by one here silently shifts every
      // rollout percentage by one ten-thousandth of the population.
      const id = 'boundary-probe';
      final bucket = rolloutBucket(id, 1);
      final exact = bucket / kRolloutBuckets;
      expect(isInRollout(id, 1, exact), isFalse);
      expect(isInRollout(id, 1, (bucket + 1) / kRolloutBuckets), isTrue);
    });
  });
}
