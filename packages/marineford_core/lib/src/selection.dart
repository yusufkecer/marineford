import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import 'abi.dart';
import 'manifest.dart';
import 'rollout.dart';

/// Everything about this device that the selection rules need.
@immutable
final class SelectionContext {
  /// Creates a [SelectionContext].
  const SelectionContext({
    required this.appId,
    required this.channel,
    required this.abi,
    required this.appVersion,
    required this.installId,
    this.installedPatch = 0,
    this.blocklist = const <int>{},
    this.lastSequence = 0,
  });

  /// Application id this build expects the manifest to be for.
  final String appId;

  /// Release channel this build expects the manifest to be for.
  ///
  /// Checked for the same reason as [appId], and more likely to be wrong. The
  /// client uses its channel only to name a directory on disk; the manifest URL
  /// is a separate field nobody cross-checks. So an app configured for `prod`
  /// whose URL ends in `/beta/manifest.json` installed beta patches, wrote them
  /// into the prod directory, and every layer agreed with every other. Beta code
  /// reaching a production user is the one thing the idea of a channel exists to
  /// prevent.
  final String channel;

  /// Fingerprint compiled into this build.
  final AbiFingerprint abi;

  /// Version of the app as shipped by the store.
  final Version appVersion;

  /// Stable per-install identifier used for rollout bucketing.
  ///
  /// It only has to be stable and unique-ish; it is never sent anywhere, since
  /// there is no server. It must genuinely persist, though — a device that
  /// invents a new one each launch redraws its rollout bucket each launch, and
  /// staged rollout stops meaning anything.
  final String installId;

  /// Patch currently installed, or `0` for none.
  final int installedPatch;

  /// Patches this device has locally decided never to load again.
  ///
  /// Populated by the crash-loop guard. Local, so one device's bad experience
  /// does not need a publisher round trip to take effect.
  final Set<int> blocklist;

  /// Highest manifest sequence this device has accepted.
  ///
  /// Anything strictly below this is stale and ignored. Without it, an attacker
  /// who controls the CDN can keep serving the last manifest published before a
  /// revocation, and the kill switch silently never arrives.
  ///
  /// Equal is accepted, not rejected. Re-reading an unchanged manifest is the
  /// ordinary case — it is what every check does when the publisher has not
  /// published since — and refusing it would cry wolf on the normal path and
  /// teach whoever reads the logs to ignore the warning that matters.
  final int lastSequence;
}

/// Why a patch was passed over. Carried on every decision so that
/// `marineford doctor` and observers can explain "nothing happened".
@immutable
final class PatchRejection {
  /// Creates a [PatchRejection] about a specific patch.
  const PatchRejection(int this.number, this.reason);

  /// Creates a [PatchRejection] about the manifest as a whole.
  const PatchRejection.manifest(this.reason) : number = null;

  /// The patch number that was skipped, or null when the rejection is about the
  /// manifest rather than any one patch.
  final int? number;

  /// Why, in words.
  final String reason;

  @override
  String toString() =>
      number == null ? 'manifest: $reason' : '#$number: $reason';
}

/// What the client should do about the manifest it just read.
sealed class PatchDecision {
  const PatchDecision({this.rejections = const <PatchRejection>[]});

  /// Patches that were considered and skipped, with reasons.
  final List<PatchRejection> rejections;
}

/// Download and install this patch.
final class ApplyPatch extends PatchDecision {
  /// Creates an [ApplyPatch] decision.
  const ApplyPatch(this.entry, {super.rejections});

  /// The patch to fetch.
  final PatchEntry entry;

  @override
  String toString() => 'ApplyPatch(#${entry.number})';
}

/// Discard the installed patch and go back to the code in the store binary.
///
/// Reached when the installed patch was revoked or locally blocklisted and no
/// eligible replacement exists.
final class RollBackToBase extends PatchDecision {
  /// Creates a [RollBackToBase] decision.
  const RollBackToBase(this.reason, {super.rejections});

  /// Why the rollback is happening.
  final String reason;

  @override
  String toString() => 'RollBackToBase($reason)';
}

/// Nothing to do. The manifest was read and understood; no patch applied.
final class StayOnCurrent extends PatchDecision {
  /// Creates a [StayOnCurrent] decision.
  const StayOnCurrent({super.rejections});

  @override
  String toString() => 'StayOnCurrent()';
}

/// The manifest itself was refused. Nothing in it was considered.
///
/// Kept distinct from [StayOnCurrent] because the two mean opposite things to a
/// caller that records progress. "I read this manifest and no patch applied" is
/// a result worth remembering — the ETag, the sequence. "I refused this
/// manifest" is not, and remembering it is exploitable: adopting a refused
/// manifest's sequence lets an attacker replay an old one twice, the first time
/// to walk the high-water mark down and the second to have it accepted.
///
/// Conflating them by looking at whether rejections is empty does not work
/// either: a manifest that was read perfectly well can still reject every patch
/// in it for ordinary reasons, like a staged rollout this device is outside of.
final class ManifestRejected extends PatchDecision {
  /// Creates a [ManifestRejected] decision.
  const ManifestRejected(this.reason);

  /// Why the manifest as a whole was refused.
  final String reason;

  @override
  String toString() => 'ManifestRejected($reason)';
}

/// Decides what to do with [manifest] on this device.
///
/// Pure and synchronous by design: this is where every safety rule that keeps a
/// bad patch off a device lives, so it has to be exhaustively testable without
/// a network, a disk, or a clock.
///
/// The rules, in order:
///
/// 1. A manifest for a different app, or a different channel, is ignored
///    outright.
/// 2. A manifest *below* the highest sequence already accepted is stale and
///    ignored — signatures never expire, so replay is otherwise free. Equal is
///    fine and common: re-reading an unchanged manifest is the normal case, and
///    calling that an attack would cry wolf on every check.
/// 3. A patch must match the fingerprint compiled into this build. Semver alone
///    does not catch a renamed method; the fingerprint does.
/// 4. A patch must satisfy its own `runtime` constraint.
/// 5. Revoked and locally blocklisted patches are never eligible.
/// 6. The device must fall inside the patch's staged rollout.
/// 7. Among what is left, the highest number wins.
/// 8. That number must be greater than what is installed — unless the installed
///    patch is itself revoked or blocklisted, which is the one case where
///    moving backwards is correct.
///
/// Rule 8 is the anti-rollback rule. Without it, an attacker who controls the
/// CDN could serve an old, validly signed, known-broken patch forever.
PatchDecision selectPatch(PatchManifest manifest, SelectionContext context) {
  if (manifest.appId != context.appId) {
    // Deliberately *not* a rollback. Reading the wrong manifest means a
    // misconfigured CDN path or a signing key shared across apps — neither is
    // an attack that discarding the installed patch would mitigate, and
    // treating it as one hands anyone who can swap manifests a way to force
    // every device back onto the buggy store build. Do nothing, loudly.
    return ManifestRejected(
      'this manifest is for "${manifest.appId}" but this app is '
      '"${context.appId}"; ignoring all of it',
    );
  }

  if (manifest.channel != context.channel) {
    // The same argument as the app id, and a mistake that is easier to make.
    // Nothing else compares the two: the channel names a directory on disk, the
    // manifest URL is configured separately, and neither knows about the other.
    // A `prod` build pointed at a beta URL would install beta patches and file
    // them under prod, with every layer agreeing.
    //
    // Refused rather than rolled back, for the same reason as the app id: a
    // rollback here would let anyone who can swap a manifest push every device
    // back onto the store build.
    return ManifestRejected(
      'this manifest is for channel "${manifest.channel}" but this build '
      'follows "${context.channel}"; ignoring all of it',
    );
  }

  if (manifest.sequence < context.lastSequence) {
    // Strictly older, which a publisher never produces: the sequence only goes
    // up. Someone is serving a manifest from before something changed — most
    // usefully, from before a revocation.
    return ManifestRejected(
      'sequence ${manifest.sequence} is older than the last accepted '
      '${context.lastSequence}; this manifest is stale and may be a replay',
    );
  }

  final rejections = <PatchRejection>[];
  final installedIsDead = context.installedPatch > 0 &&
      (manifest.revoked.contains(context.installedPatch) ||
          context.blocklist.contains(context.installedPatch));

  PatchEntry? best;
  for (final entry in manifest.patches) {
    final reason = _rejectionReason(entry, manifest, context);
    if (reason != null) {
      rejections.add(PatchRejection(entry.number, reason));
    } else if (best == null || entry.number > best.number) {
      best = entry;
    }
  }

  if (installedIsDead) {
    // `best` cannot be the installed patch here: a revoked or blocklisted
    // patch is never eligible, so it was filtered out above.
    if (best != null) return ApplyPatch(best, rejections: rejections);
    return RollBackToBase(
      manifest.revoked.contains(context.installedPatch)
          ? 'patch #${context.installedPatch} was revoked by the publisher'
          : 'patch #${context.installedPatch} is locally blocklisted after '
              'repeated failures',
      rejections: rejections,
    );
  }

  if (best != null && best.number > context.installedPatch) {
    return ApplyPatch(best, rejections: rejections);
  }
  return StayOnCurrent(rejections: rejections);
}

String? _rejectionReason(
  PatchEntry entry,
  PatchManifest manifest,
  SelectionContext context,
) {
  if (manifest.revoked.contains(entry.number)) {
    return 'revoked by the publisher';
  }
  if (context.blocklist.contains(entry.number)) {
    return 'locally blocklisted after repeated failures';
  }
  if (entry.abi != context.abi) {
    return 'built against ABI ${entry.abi}, this build is ${context.abi}';
  }
  if (!entry.runtime.allows(context.appVersion)) {
    return 'requires app ${entry.runtime}, this app is ${context.appVersion}';
  }
  if (!isInRollout(context.installId, entry.number, entry.rollout)) {
    return 'this device is outside the '
        '${(entry.rollout * 100).toStringAsFixed(1)}% rollout';
  }
  return null;
}
