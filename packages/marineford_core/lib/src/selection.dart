import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import 'manifest.dart';
import 'rollout.dart';

/// Everything about this device that the selection rules need.
@immutable
final class SelectionContext {
  /// Creates a [SelectionContext].
  const SelectionContext({
    required this.appId,
    required this.abi,
    required this.appVersion,
    required this.installId,
    this.installedPatch = 0,
    this.blocklist = const <int>{},
  });

  /// Application id this build expects the manifest to be for.
  final String appId;

  /// ABI fingerprint compiled into this build, as `sha256:<hex>`.
  final String abi;

  /// Version of the app as shipped by the store.
  final Version appVersion;

  /// Stable per-install identifier used for rollout bucketing.
  ///
  /// It only has to be stable and unique-ish; it is never sent anywhere, since
  /// there is no server. A random id generated on first launch is ideal.
  final String installId;

  /// Patch currently installed, or `0` for none.
  final int installedPatch;

  /// Patches this device has locally decided never to load again.
  ///
  /// Populated by the crash-loop guard. Local, so one device's bad experience
  /// does not need a publisher round trip to take effect.
  final Set<int> blocklist;
}

/// Why a patch was passed over. Carried on every decision so that
/// `marineford doctor` and observers can explain "nothing happened".
@immutable
final class PatchRejection {
  /// Creates a [PatchRejection].
  const PatchRejection(this.number, this.reason);

  /// The patch number that was skipped.
  final int number;

  /// Why, in words.
  final String reason;

  @override
  String toString() => '#$number: $reason';
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

/// Nothing to do.
final class StayOnCurrent extends PatchDecision {
  /// Creates a [StayOnCurrent] decision.
  const StayOnCurrent({super.rejections});

  @override
  String toString() => 'StayOnCurrent()';
}

/// Decides what to do with [manifest] on this device.
///
/// Pure and synchronous by design: this is where every safety rule that keeps a
/// bad patch off a device lives, so it has to be exhaustively testable without
/// a network, a disk, or a clock.
///
/// The rules, in order:
///
/// 1. A manifest for a different app is ignored outright.
/// 2. A patch must match the ABI fingerprint compiled into this build.
///    Semver alone does not catch a renamed method; the fingerprint does.
/// 3. A patch must satisfy its own `runtime` constraint against [
///    SelectionContext.appVersion].
/// 4. Revoked and locally blocklisted patches are never eligible.
/// 5. The device must fall inside the patch's staged rollout.
/// 6. Among what is left, the highest number wins.
/// 7. That number must be greater than what is installed — unless the installed
///    patch is itself revoked or blocklisted, which is the one case where
///    moving backwards is correct.
///
/// Rule 7 is the anti-rollback rule. Without it, an attacker who controls the
/// CDN could serve an old, validly signed, known-broken patch forever.
PatchDecision selectPatch(PatchManifest manifest, SelectionContext context) {
  final rejections = <PatchRejection>[];

  if (manifest.appId != context.appId) {
    // Deliberately *not* a rollback. Reading the wrong manifest means a
    // misconfigured CDN path or a signing key shared across apps — neither is
    // an attack that discarding the installed patch would mitigate, and
    // treating it as one hands anyone who can swap manifests a way to force
    // every device back onto the buggy store build. Do nothing, loudly.
    return StayOnCurrent(rejections: [
      PatchRejection(
        0,
        'manifest is for "${manifest.appId}" but this app is '
        '"${context.appId}"; ignoring the whole manifest',
      ),
    ]);
  }

  final installedIsDead = context.installedPatch > 0 &&
      (manifest.revoked.contains(context.installedPatch) ||
          context.blocklist.contains(context.installedPatch));

  final eligible = <PatchEntry>[];
  for (final entry in manifest.patches) {
    final reason = _rejectionReason(entry, manifest, context);
    if (reason != null) {
      rejections.add(PatchRejection(entry.number, reason));
    } else {
      eligible.add(entry);
    }
  }

  PatchEntry? best;
  for (final entry in eligible) {
    if (best == null || entry.number > best.number) best = entry;
  }

  if (installedIsDead) {
    final reason = manifest.revoked.contains(context.installedPatch)
        ? 'patch #${context.installedPatch} was revoked by the publisher'
        : 'patch #${context.installedPatch} is locally blocklisted after '
            'repeated failures';
    if (best != null && best.number != context.installedPatch) {
      return ApplyPatch(best, rejections: rejections);
    }
    return RollBackToBase(reason, rejections: rejections);
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
