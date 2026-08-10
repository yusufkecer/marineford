import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:path/path.dart' as p;

import 'config.dart';

/// Where published patches go.
///
/// One small interface with one shipped implementation. marineford publishes
/// to static files on purpose, so this is not a plugin system waiting to happen
/// — it exists so that "upload to S3" and "copy to a folder" cannot drift apart
/// in how they lay a channel out.
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
/// Useful for testing the whole pipeline without a network, and for anyone
/// syncing a folder to their own host.
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
/// Both sides of publishing go through `marineford_core`, so the manifest a command
/// writes is validated by exactly the code the device will validate it with.
/// A manifest this class produces and cannot read back is a bug caught here
/// rather than on a phone.
final class ChannelPublisher {
  /// Creates a [ChannelPublisher].
  const ChannelPublisher({
    required this.target,
    required this.project,
    required this.channel,
  });

  /// Where to write.
  final PublishTarget target;

  /// The project being published.
  final MarinefordProject project;

  /// Channel name.
  final String channel;

  /// Reads the current manifest, or an empty one if there is none yet.
  Future<PatchManifest> read() async {
    final bytes = await target.get('manifest.json');
    if (bytes == null) {
      return PatchManifest(
        schema: 1,
        appId: project.appId,
        channel: channel,
        generatedAt: DateTime.now().toUtc(),
        patches: const <PatchEntry>[],
      );
    }
    final manifest = PatchManifest.parse(utf8.decode(bytes));
    if (manifest.appId != project.appId) {
      throw CliException(
        'the manifest at ${target.describe('manifest.json')} belongs to '
        '"${manifest.appId}", but this project is "${project.appId}"',
        hint: 'Publishing would replace another app\'s patches. Check '
            '`app_id` in marineford.yaml and the target path.',
      );
    }
    return manifest;
  }

  /// Writes [manifest] and its detached signature.
  ///
  /// The signature covers the exact bytes written, which is why the encoding
  /// happens once here and the same buffer is both signed and uploaded — a
  /// re-encode between the two would eventually differ by a space and fail
  /// verification on every device at once.
  Future<void> write(PatchManifest manifest, PatchSigner signer) async {
    final bytes = Uint8List.fromList(utf8
        .encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson())));

    // Prove the device-side parser accepts what we are about to publish.
    PatchManifest.parse(utf8.decode(bytes));

    await target.put('manifest.json', bytes);
    await target.put('manifest.json.sig', await signer.sign(bytes));
  }

  /// Adds or replaces a patch entry and returns the new manifest.
  PatchManifest withPatch(PatchManifest manifest, PatchEntry entry) {
    final patches = <PatchEntry>[
      for (final existing in manifest.patches)
        if (existing.number != entry.number) existing,
      entry,
    ]..sort((a, b) => b.number.compareTo(a.number));
    return PatchManifest(
      schema: manifest.schema,
      appId: manifest.appId,
      channel: manifest.channel,
      generatedAt: DateTime.now().toUtc(),
      patches: patches,
      revoked: manifest.revoked,
    );
  }

  /// Returns a manifest with [numbers] added to the revoked list.
  PatchManifest withRevoked(PatchManifest manifest, Set<int> numbers) =>
      PatchManifest(
        schema: manifest.schema,
        appId: manifest.appId,
        channel: manifest.channel,
        generatedAt: DateTime.now().toUtc(),
        patches: manifest.patches,
        revoked: <int>{...manifest.revoked, ...numbers},
      );

  /// Returns a manifest with [number]'s rollout fraction changed.
  PatchManifest withRollout(
      PatchManifest manifest, int number, double fraction) {
    final target =
        manifest.patches.where((entry) => entry.number == number).firstOrNull;
    if (target == null) {
      throw CliException('patch #$number is not in the $channel manifest');
    }
    return PatchManifest(
      schema: manifest.schema,
      appId: manifest.appId,
      channel: manifest.channel,
      generatedAt: DateTime.now().toUtc(),
      patches: <PatchEntry>[
        for (final entry in manifest.patches)
          if (entry.number == number)
            PatchEntry(
              number: entry.number,
              url: entry.url,
              size: entry.size,
              sha256: entry.sha256,
              abi: entry.abi,
              runtime: entry.runtime,
              rollout: fraction,
              notes: entry.notes,
            )
          else
            entry,
      ],
      revoked: manifest.revoked,
    );
  }

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
