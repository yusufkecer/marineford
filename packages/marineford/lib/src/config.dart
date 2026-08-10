import 'package:dart_eval/dart_eval_bridge.dart' show EvalPlugin;
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
  const MarinefordConfig({
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
  });

  /// Application id. Must match the manifest, or the manifest is ignored.
  final String appId;

  /// Version of this build, as shipped by the store.
  final Version appVersion;

  /// ABI fingerprint generated into this build as `kMarinefordAbi`.
  ///
  /// A patch whose fingerprint differs is never loaded. This is what catches
  /// the case semver cannot: a method signature that changed between builds.
  final String abi;

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
  /// Empty by default, and that default matters: a patch can only touch what
  /// you list here. Adding a bridge grants that capability to anyone who can
  /// publish a patch, so add the app's own domain classes and stop there —
  /// not file system, network, or platform channel wrappers.
  final List<EvalPlugin> plugins;
}
