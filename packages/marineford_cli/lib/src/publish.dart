import 'dart:io';
import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:path/path.dart' as p;

import 'config.dart';

/// Where published patches go.
///
/// One small interface with one shipped implementation. marineford publishes to
/// static files on purpose, so this is not a plugin system waiting to happen —
/// it exists so that "copy to a folder" and whatever you sync that folder with
/// cannot drift apart in how they lay a channel out.
abstract interface class PublishTarget {
  /// Writes [bytes] to [path], relative to the channel root.
  Future<void> put(String path, Uint8List bytes);

  /// Reads [path] back, or null if it is not there.
  Future<Uint8List?> get(String path);

  /// Human-readable location, for the command's output.
  String describe(String path);
}

/// Publishes into a local directory.
///
/// The only target, and deliberately so. A channel is three kinds of file on a
/// static host; every object store, CDN and web server already has a good tool
/// for uploading a directory, and none of them need this project to reimplement
/// their auth.
final class DirectoryTarget implements PublishTarget {
  /// Creates a [DirectoryTarget] rooted at [root].
  DirectoryTarget(this.root);

  /// The channel directory.
  final Directory root;

  @override
  Future<void> put(String path, Uint8List bytes) async {
    final file = File(p.join(root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> get(String path) async {
    final file = File(p.join(root.path, path));
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  @override
  String describe(String path) => p.join(root.path, path);
}

/// Reads and writes the manifest for one channel.
///
/// Both sides of publishing go through `marineford_core`, so the manifest a
/// command writes is validated by exactly the code the device will validate it
/// with. A manifest this class produces and cannot read back is a bug caught
/// here rather than on a phone.
final class ChannelPublisher {
  /// Creates a [ChannelPublisher].
  const ChannelPublisher({
    required this.target,
    required this.project,
    required this.channel,
  });

  /// Name of the single file a channel consists of, besides its patches.
  static const String manifestFile = 'manifest.json';

  /// Where to write.
  final PublishTarget target;

  /// The project being published.
  final MarinefordProject project;

  /// Channel name.
  final String channel;

  /// Reads the current manifest, or an empty one if there is none yet.
  ///
  /// Does not verify the signature: this is the publisher, and it is about to
  /// replace whatever is there with something it signs itself. Reading is only
  /// to learn the next sequence and patch number.
  Future<PatchManifest> read() async {
    final bytes = await target.get(manifestFile);
    if (bytes == null) {
      return PatchManifest(
        schema: 1,
        appId: project.appId,
        channel: channel,
        sequence: 0,
        generatedAt: DateTime.now().toUtc(),
        patches: const <PatchEntry>[],
      );
    }
    final manifest = SignedManifest.parse(bytes).manifest;
    if (manifest.appId != project.appId) {
      throw CliException(
        'the manifest at ${target.describe(manifestFile)} belongs to '
        '"${manifest.appId}", but this project is "${project.appId}"',
        hint: 'Publishing would replace another app\'s patches. Check '
            '`app_id` in marineford.yaml and the target path.',
      );
    }
    return manifest;
  }

  /// Signs [manifest] and writes it as a single file.
  ///
  /// One file, one write. Publishing the manifest and its signature separately
  /// leaves a window in which the new manifest is up and the old signature is
  /// not — during which every device rejects the channel — and a failed second
  /// upload leaves it that way until someone notices.
  Future<void> write(PatchManifest manifest, PatchSigner signer) async {
    final signedBytes = SignedManifest.bytesToSign(manifest);
    final signature = await signer.sign(signedBytes);
    final envelope = SignedManifest.encode(signedBytes, signature);

    // Read it back the way a device would, including the signature check. If
    // this fails, the channel was about to break for everyone.
    final parsed = SignedManifest.parse(envelope);
    final verifier = PatchVerifier(signer.publicKey);
    if (!await verifier.verify(parsed.signedBytes, parsed.signature)) {
      throw const CliException(
        'the manifest failed its own signature check before upload',
        hint: 'This is a bug in marineford, not in your project. Nothing was '
            'written.',
      );
    }

    await target.put(manifestFile, envelope);
  }

  /// Adds or replaces a patch entry and returns the new manifest.
  PatchManifest withPatch(PatchManifest manifest, PatchEntry entry) => _next(
        manifest,
        patches: <PatchEntry>[
          for (final existing in manifest.patches)
            if (existing.number != entry.number) existing,
          entry,
        ]..sort((a, b) => b.number.compareTo(a.number)),
      );

  /// Returns a manifest with [numbers] added to the revoked list.
  PatchManifest withRevoked(PatchManifest manifest, Set<int> numbers) =>
      _next(manifest, revoked: <int>{...manifest.revoked, ...numbers});

  /// Returns a manifest with [number]'s rollout fraction changed.
  PatchManifest withRollout(
      PatchManifest manifest, int number, double fraction) {
    if (!manifest.patches.any((entry) => entry.number == number)) {
      throw CliException('patch #$number is not in the $channel manifest');
    }
    return _next(
      manifest,
      patches: <PatchEntry>[
        for (final entry in manifest.patches)
          if (entry.number == number)
            entry.copyWith(rollout: fraction)
          else
            entry,
      ],
    );
  }

  /// Every change bumps the sequence. Devices refuse anything not newer than
  /// what they have already accepted, so a manifest published without advancing
  /// it would be indistinguishable from a replay and simply ignored.
  PatchManifest _next(
    PatchManifest manifest, {
    List<PatchEntry>? patches,
    Set<int>? revoked,
  }) =>
      PatchManifest(
        schema: manifest.schema,
        appId: manifest.appId,
        channel: manifest.channel,
        sequence: manifest.sequence + 1,
        generatedAt: DateTime.now().toUtc(),
        patches: patches ?? manifest.patches,
        revoked: revoked ?? manifest.revoked,
      );

  /// The next free patch number.
  int nextNumber(PatchManifest manifest) {
    var highest = 0;
    for (final entry in manifest.patches) {
      if (entry.number > highest) highest = entry.number;
    }
    for (final revoked in manifest.revoked) {
      if (revoked > highest) highest = revoked;
    }
    return highest + 1;
  }
}
