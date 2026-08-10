import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Everything the client remembers between launches.
@immutable
final class PatchState {
  /// Creates a [PatchState].
  const PatchState({
    required this.installId,
    this.installed = 0,
    this.blocklist = const <int>{},
    this.booting,
    this.bootAttempts = 0,
    this.manifestEtag,
  });

  /// Stable random id for this install, used for rollout bucketing.
  ///
  /// Generated on first run and never sent anywhere — there is no server. It
  /// exists so that "25% of devices" means a consistent 25%.
  final String installId;

  /// Patch currently installed, or 0 for none.
  final int installed;

  /// Patches this device has given up on. Never loaded again.
  final Set<int> blocklist;

  /// Patch that started activating but never confirmed a healthy boot.
  ///
  /// Non-null at startup means the previous run did not get far enough to call
  /// `markBootSuccessful`. That is the crash-loop signal.
  final int? booting;

  /// How many times [booting] has been attempted.
  final int bootAttempts;

  /// ETag of the last manifest, so the usual check costs a 304 and no body.
  final String? manifestEtag;

  /// Returns a copy with the given fields replaced.
  ///
  /// [booting] and [manifestEtag] are nullable fields, so they take explicit
  /// `clear` flags rather than relying on null to mean "unchanged".
  PatchState copyWith({
    int? installed,
    Set<int>? blocklist,
    int? booting,
    bool clearBooting = false,
    int? bootAttempts,
    String? manifestEtag,
    bool clearEtag = false,
  }) =>
      PatchState(
        installId: installId,
        installed: installed ?? this.installed,
        blocklist: blocklist ?? this.blocklist,
        booting: clearBooting ? null : (booting ?? this.booting),
        bootAttempts: bootAttempts ?? this.bootAttempts,
        manifestEtag: clearEtag ? null : (manifestEtag ?? this.manifestEtag),
      );

  /// Reads state from JSON, falling back to defaults for anything unreadable.
  ///
  /// Never throws. A corrupt state file must not brick the app: the worst
  /// acceptable outcome is forgetting which patch was installed and starting
  /// over from the store build.
  static PatchState fromJson(Map<String, Object?> json, String fallbackId) {
    final installId = json['installId'];
    final blocklist = json['blocklist'];
    return PatchState(
      installId:
          installId is String && installId.isNotEmpty ? installId : fallbackId,
      installed: json['installed'] is int ? json['installed']! as int : 0,
      blocklist: blocklist is List
          ? <int>{
              for (final n in blocklist)
                if (n is int) n
            }
          : const <int>{},
      booting: json['booting'] is int ? json['booting']! as int : null,
      bootAttempts:
          json['bootAttempts'] is int ? json['bootAttempts']! as int : 0,
      manifestEtag: json['manifestEtag'] is String
          ? json['manifestEtag']! as String
          : null,
    );
  }

  /// Renders state to JSON.
  Map<String, Object?> toJson() => <String, Object?>{
        'installId': installId,
        'installed': installed,
        'blocklist': blocklist.toList()..sort(),
        if (booting != null) 'booting': booting,
        'bootAttempts': bootAttempts,
        if (manifestEtag != null) 'manifestEtag': manifestEtag,
      };

  @override
  String toString() => 'PatchState(installed: $installed, '
      'blocklist: $blocklist, booting: $booting/$bootAttempts)';
}

/// On-disk home for patches and the state that tracks them.
///
/// One directory per channel, so switching a build from `prod` to `beta` does
/// not make it inherit the other channel's installed patch.
final class PatchStore {
  /// Creates a store rooted at [root].
  PatchStore(this.root, {Random? random}) : _random = random ?? Random.secure();

  /// Directory holding `state.json` and `patches/`.
  final Directory root;

  final Random _random;

  File get _stateFile => File(p.join(root.path, 'state.json'));
  Directory get _patchDir => Directory(p.join(root.path, 'patches'));

  File _patchFile(int number) => File(p.join(_patchDir.path, '$number.mfp'));

  /// Reads persisted state, creating a fresh install id on first run.
  ///
  /// Returns defaults rather than throwing on a missing or corrupt file.
  Future<PatchState> readState() async {
    final fallbackId = _newInstallId();
    if (!_stateFile.existsSync()) return PatchState(installId: fallbackId);
    try {
      final decoded = jsonDecode(await _stateFile.readAsString());
      if (decoded is! Map<String, Object?>) {
        return PatchState(installId: fallbackId);
      }
      return PatchState.fromJson(decoded, fallbackId);
    } on Object {
      // Unreadable state is recoverable; a thrown exception here is not.
      return PatchState(installId: fallbackId);
    }
  }

  /// Persists [state], creating the directory if needed.
  Future<void> writeState(PatchState state) async {
    await root.create(recursive: true);
    await _writeAtomic(_stateFile, utf8.encode(jsonEncode(state.toJson())));
  }

  /// Writes a verified patch container to disk.
  ///
  /// Only call this after the signature checks out. The store does no
  /// verification of its own — mixing "where bytes live" with "which bytes are
  /// trustworthy" is how a verification step gets skipped by accident.
  Future<void> savePatch(int number, Uint8List bytes) async {
    await _patchDir.create(recursive: true);
    await _writeAtomic(_patchFile(number), bytes);
  }

  /// Reads a stored patch, or null if it is not there or cannot be read.
  Future<Uint8List?> readPatch(int number) async {
    final file = _patchFile(number);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// Deletes a stored patch if present.
  Future<void> deletePatch(int number) async {
    final file = _patchFile(number);
    if (file.existsSync()) {
      try {
        await file.delete();
      } on FileSystemException {
        // A patch we cannot delete is a disk problem, not a correctness one:
        // selection ignores files, it goes by state.
      }
    }
  }

  /// Patch numbers currently on disk, highest first.
  Future<List<int>> storedPatches() async {
    if (!_patchDir.existsSync()) return const <int>[];
    final numbers = <int>[];
    await for (final entity in _patchDir.list()) {
      if (entity is! File) continue;
      final name = p.basenameWithoutExtension(entity.path);
      final number = int.tryParse(name);
      if (number != null && p.extension(entity.path) == '.mfp') {
        numbers.add(number);
      }
    }
    numbers.sort((a, b) => b.compareTo(a));
    return numbers;
  }

  /// Keeps the [keep] highest-numbered patches and deletes the rest.
  ///
  /// Two is the useful default: the one running and the one to fall back to.
  Future<void> prune({int keep = 2}) async {
    final stored = await storedPatches();
    for (final number in stored.skip(keep)) {
      await deletePatch(number);
    }
  }

  /// Deletes everything. Used when the state is beyond repair.
  Future<void> clear() async {
    if (root.existsSync()) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    }
  }

  String _newInstallId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Writes via a temporary file and renames, so an interrupted write leaves
  /// the previous content rather than a half-file.
  Future<void> _writeAtomic(File file, List<int> bytes) async {
    final temp = File('${file.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }
}
