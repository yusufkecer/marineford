import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Number of buckets a device can fall into. Gives rollout percentages two
/// decimal places of resolution.
const int kRolloutBuckets = 10000;

/// Assigns a device a stable bucket in `[0, kRolloutBuckets)` for one patch.
///
/// The bucket is derived from the install id and the patch number, so it is:
///
/// * **stable** — the same device asked about the same patch always lands in
///   the same bucket, across restarts and reinstalls of the manifest;
/// * **independent per patch** — a device unlucky enough to be excluded from
///   patch 7 is not systematically excluded from patch 8;
/// * **uniform** — buckets come from a SHA-256 digest, so no install id
///   pattern (sequential ids, UUID v4, device ids) skews the distribution.
///
/// Stability is what makes staged rollout safe: raising the percentage only
/// ever adds devices. A device that already has the patch never loses it
/// because someone nudged the number up.
int rolloutBucket(String installId, int patchNumber) {
  final digest = sha256.convert(utf8.encode('$installId/$patchNumber'));
  final head = Uint8List.fromList(digest.bytes.sublist(0, 4));
  final value = ByteData.view(head.buffer).getUint32(0);
  return value % kRolloutBuckets;
}

/// Whether this device is inside a staged rollout of [fraction] for the given
/// patch.
///
/// [fraction] is clamped to `[0, 1]`. A fraction of `1.0` includes every
/// device and `0.0` includes none — both without calling into the hash.
bool isInRollout(String installId, int patchNumber, double fraction) {
  if (fraction >= 1.0) return true;
  if (fraction <= 0.0) return false;
  return rolloutBucket(installId, patchNumber) <
      (fraction * kRolloutBuckets).floor();
}
