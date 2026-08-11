import 'package:dart_eval/dart_eval_bridge.dart' show EvalPlugin;
import 'package:dart_eval/dart_eval_security.dart' show Permission;
import 'package:marineford_core/marineford_core.dart' show AbiFingerprint;
import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import 'observer.dart';
import 'transport.dart';

/// When a downloaded patch starts dispatching.
enum PatchActivation {
  /// Activate as soon as the download is verified.
  ///
  /// Sound in v1: activation is a dispatch-table swap and measured 0.74ms.
  /// Functions already executing keep their original body; the next call goes
  /// to the patch.
  immediate,

  /// Leave the patch on disk and activate it during the next launch.
  ///
  /// The conservative default. Nothing changes under a running screen, and the
  /// crash-loop guard gets a clean boot to observe.
  onNextLaunch,
}

/// How to reach and trust patches.
@immutable
final class MarinefordConfig {
  /// Creates a [MarinefordConfig].
  ///
  /// Throws [FormatException] if [abi] is not a well-formed fingerprint. Not
  /// const, so this validation happens here rather than the first time a patch
  /// silently fails to match.
  MarinefordConfig({
    required this.appId,
    required this.appVersion,
    required this.abi,
    required this.manifestUrl,
    required this.publicKey,
    this.channel = 'prod',
    this.activation = PatchActivation.onNextLaunch,
    this.autoConfirmBootAfter = const Duration(seconds: 3),
    this.maxBootAttempts = 2,
    this.failureThreshold = 5,
    this.retainPatches = 2,
    this.observer,
    this.transport,
    this.plugins = const <EvalPlugin>[],
    this.permissions = const <Permission>[],
  }) : fingerprint = AbiFingerprint.parse(abi);

  /// Application id. Must match the manifest, or the manifest is ignored.
  final String appId;

  /// Version of this build, as shipped by the store.
  final Version appVersion;

  /// ABI fingerprint generated into this build as `kMarinefordAbi`.
  ///
  /// A patch whose fingerprint differs is never loaded. This is what catches
  /// the case semver cannot: a method signature that changed between builds.
  ///
  /// Validated at construction rather than at first use: a malformed value here
  /// is a build-configuration mistake, and finding out about it when the first
  /// patch silently fails to match is far too late.
  final String abi;

  /// [abi], parsed and validated at construction.
  final AbiFingerprint fingerprint;

  /// Where `manifest.json` lives. `manifest.json.sig` must sit beside it.
  final Uri manifestUrl;

  /// Base64 Ed25519 public key, as printed by `marineford init`.
  final String publicKey;

  /// Release channel. Also the on-disk directory name.
  final String channel;

  /// When a verified patch starts dispatching.
  final PatchActivation activation;

  /// How long after activation to declare the boot healthy on its own.
  ///
  /// Set to null to take responsibility yourself with `markBootSuccessful`,
  /// which is better if your app has a meaningful "we got to the home screen"
  /// moment — a timer cannot tell a working app from one stuck on a spinner.
  final Duration? autoConfirmBootAfter;

  /// Failed boots before a patch is blocklisted for good.
  final int maxBootAttempts;

  /// Runtime failures before a patch is dropped for the rest of the session.
  final int failureThreshold;

  /// How many patch files to keep. Two gives you something to roll back to.
  final int retainPatches;

  /// Where to send [PatchEvent]s.
  ///
  /// With static hosting there is nothing reporting back to you. If you skip
  /// this, a patch that fails on every device in the field is invisible.
  final PatchObserver? observer;

  /// Transport override. Defaults to [HttpPatchTransport].
  final PatchTransport? transport;

  /// Bridges exposed to interpreted code.
  ///
  /// Empty by default, and that default matters: a patch can only reach the
  /// arguments it is handed and the bridges you list here. Adding a bridge
  /// grants that capability to anyone who can publish a patch, so add the app's
  /// own domain classes and stop there.
  ///
  /// A bridge you write yourself has no permission checks in it. Whatever it
  /// exposes is exposed unconditionally — [permissions] governs `dart:io`, not
  /// your code.
  final List<EvalPlugin> plugins;

  /// Capabilities granted to interpreted code, on top of nothing.
  ///
  /// Empty means a patch cannot read a file, open a socket, or start a process.
  /// That is enforced by dart_eval, which is default-deny and checks
  /// `assertPermission` before each of those — plus marineford's own sandbox
  /// plugin, which covers the `dart:io` entry points dart_eval forgot to check.
  ///
  /// This field exists so the answer lives here rather than in dart_eval's
  /// defaults. Relying on someone else's default meant that if it ever changed,
  /// every app using marineford would inherit the change without a line of code
  /// moving — and the sandbox is the part of this library least able to afford
  /// a surprise.
  ///
  /// Granting anything widens the blast radius of a stolen signing key from
  /// "the bodies of marked functions" to whatever you grant. If a patch needs
  /// to read one specific file, grant exactly that path; the alternative people
  /// reach for otherwise is a hand-written bridge, which has no checks at all.
  final List<Permission> permissions;
}
