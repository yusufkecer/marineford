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
    this.lastSequence = 0,
  });

  /// Stable random id for this install, used for rollout bucketing.
  ///
  /// Generated on first run and never sent anywhere — there is no server. It
  /// exists so that "25% of devices" means a consistent 25%, which only holds
  /// if it genuinely survives restarts; see [PatchStore.readState].
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

  /// ETag of the last manifest the client fully acted on.
  ///
  /// Only recorded once the decision has been carried out. Recording it earlier
  /// means a failed download leaves the client sending `If-None-Match` for a
  /// manifest it never finished processing, getting a 304, and never retrying.
  final String? manifestEtag;

  /// Highest manifest sequence accepted so far.
  ///
  /// Anything strictly below this is stale — equal is the ordinary case of
  /// re-reading an unchanged manifest. Signatures never expire, so without this
  /// an old manifest can be replayed forever, including one published before a
  /// revocation.
  final int lastSequence;

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
    int? lastSequence,
  }) =>
      PatchState(
        installId: installId,
        installed: installed ?? this.installed,
        blocklist: blocklist ?? this.blocklist,
        booting: clearBooting ? null : (booting ?? this.booting),
        bootAttempts: bootAttempts ?? this.bootAttempts,
        manifestEtag: clearEtag ? null : (manifestEtag ?? this.manifestEtag),
        // Monotonic, enforced here rather than at the call site.
        //
        // The high-water mark is the entire anti-replay defence, and a caller
        // that lowers it — even while *refusing* the manifest that carried the
        // lower number — hands an attacker a two-step replay: serve the old
        // manifest once to drag the mark down, serve it again to have it
        // accepted. Making the field incapable of going backwards means nobody
        // has to remember this at any of the places that write state.
        lastSequence: lastSequence == null || lastSequence < this.lastSequence
            ? this.lastSequence
            : lastSequence,
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
      lastSequence:
          json['lastSequence'] is int ? json['lastSequence']! as int : 0,
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
        'lastSequence': lastSequence,
      };

  /// Value equality, so a caller can tell whether anything actually changed.
  ///
  /// Worth having because the alternative is writing the file on every manifest
  /// check. Each write is a create, an fsync and a rename — and the common case,
  /// by a wide margin, is a check that changes nothing at all.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PatchState &&
          installId == other.installId &&
          installed == other.installed &&
          booting == other.booting &&
          bootAttempts == other.bootAttempts &&
          manifestEtag == other.manifestEtag &&
          lastSequence == other.lastSequence &&
          blocklist.length == other.blocklist.length &&
          blocklist.containsAll(other.blocklist);

  @override
  int get hashCode => Object.hash(
        installId,
        installed,
        booting,
        bootAttempts,
        manifestEtag,
        lastSequence,
        Object.hashAllUnordered(blocklist),
      );

  @override
  String toString() => 'PatchState(installed: $installed, seq: $lastSequence, '
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

  /// Reads persisted state, creating and **saving** a fresh install id on first
  /// run.
  ///
  /// The save is the point. An id that is invented on every read but never
  /// written puts the device in a different rollout bucket on every launch, so
  /// a 10% rollout becomes a 10% chance per launch rather than a stable 10% of
  /// devices — and "raising the percentage only ever adds devices", the
  /// property staged rollout rests on, stops being true.
  ///
  /// Returns defaults rather than throwing on a missing or corrupt file.
  Future<PatchState> readState() async {
    final raw = await _readJsonOrNull();
    if (raw == null) {
      final fresh = PatchState(installId: _newInstallId());
      await writeState(fresh);
      return fresh;
    }

    final stored = raw['installId'];
    final hasId = stored is String && stored.isNotEmpty;
    final state = PatchState.fromJson(raw, hasId ? stored : _newInstallId());

    // A missing or malformed id is repaired in place rather than by discarding
    // the file. The rest of the state is worth far more than the id — losing
    // the blocklist means happily reloading a patch that has already crashed
    // the app twice.
    if (!hasId) await writeState(state);
    return state;
  }

  /// The state file as decoded JSON, or null if there is not one to read.
  ///
  /// No existence check: `readAsString` throws when the file is missing, and
  /// that is already caught below. Asking first costs a second syscall and
  /// answers a question the read is about to answer anyway — and between the
  /// two the file could be gone regardless.
  Future<Map<String, Object?>?> _readJsonOrNull() async {
    try {
      final decoded = jsonDecode(await _stateFile.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } on Object {
      // Unreadable state is recoverable; a thrown exception here is not.
      return null;
    }
  }

  /// Persists [state], creating the directory if needed.
  ///
  /// Serialised against every other state write, because they are not all
  /// awaited by whoever starts them. The boot-confirmation timer fires
  /// `markBootSuccessful` unawaited, the dispatcher abandons a patch from
  /// inside interpreted code and cannot wait for a disk write, and
  /// `checkForUpdate` runs on its own. Two of those overlapping used to write
  /// the same temporary file and then race to rename it: one rename won, the
  /// other threw, and the bytes in between were whichever interleaving got
  /// there first.
  Future<void> writeState(PatchState state) {
    final bytes = utf8.encode(jsonEncode(state.toJson()));
    final next = _stateWrites.then((_) async {
      await root.create(recursive: true);
      await _writeAtomic(_stateFile, bytes);
    });
    // The chain has to survive a failed write, or one bad disk moment stops
    // every later write from being attempted. The error still reaches the
    // caller through `next`.
    _stateWrites = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Tail of the state-write chain. See [writeState].
  Future<void> _stateWrites = Future<void>.value();

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
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// Deletes a stored patch if present.
  Future<void> deletePatch(int number) async {
    try {
      await _patchFile(number).delete();
    } on FileSystemException {
      // Missing or undeletable, and neither is a correctness problem: selection
      // goes by state, not by what is on disk.
    }
  }

  /// Patch numbers currently on disk, highest first.
  ///
  /// An absent directory is the ordinary state before the first install, and
  /// `list()` reports it the same way it reports a permission problem — as a
  /// `FileSystemException`. Both mean the same thing here: nothing to offer.
  Future<List<int>> storedPatches() async {
    final numbers = <int>[];
    try {
      await for (final entity in _patchDir.list()) {
        if (entity is! File) continue;
        final name = p.basenameWithoutExtension(entity.path);
        final number = int.tryParse(name);
        if (number != null && p.extension(entity.path) == '.mfp') {
          numbers.add(number);
        }
      }
    } on FileSystemException {
      return const <int>[];
    }
    numbers.sort((a, b) => b.compareTo(a));
    return numbers;
  }

  /// Keeps the [keep] highest-numbered patches, and always keeps [protect].
  ///
  /// [protect] is what makes this safe. Ranking by number alone deletes the
  /// installed patch whenever the client has just moved *backwards* — which is
  /// exactly what a revocation does. The next launch then finds the file
  /// missing, treats that as a broken patch, and blocklists a patch that was
  /// never broken.
  Future<void> prune({int keep = 2, int protect = 0}) async {
    final stored = await storedPatches();
    // [protect] counts against the budget rather than sitting on top of it, so
    // `keep` still means what it says.
    final survivors = <int>{if (protect > 0) protect};
    for (final number in stored) {
      if (survivors.length >= keep) break;
      survivors.add(number);
    }
    for (final number in stored) {
      if (!survivors.contains(number)) await deletePatch(number);
    }
  }

  /// Deletes everything. Used when the state is beyond repair.
  Future<void> clear() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Missing or undeletable. Best effort either way.
    }
  }

  String _newInstallId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Writes via a temporary file and renames, so an interrupted write leaves
  /// the previous content rather than a half-file.
  /// One temporary name per target, reused.
  ///
  /// A unique suffix per write looks safer and is worse: nothing sweeps these,
  /// so a process killed between the write and the rename orphans a file no
  /// later write will ever reuse, and a device that is force-killed often
  /// accumulates them without bound. `storedPatches` will not even notice —
  /// it filters on the `.mfp` extension and these end in `.part`.
  ///
  /// A fixed name is bounded at one file per target and the next write reclaims
  /// it. What makes that safe is that no two writers share a target: state
  /// writes are serialised through [writeState]'s chain, and a patch file is
  /// named after a number that is downloaded once.
  Future<void> _writeAtomic(File file, List<int> bytes) async {
    final temp = File('${file.path}.part');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } on Object {
      // A partial temporary file left behind would be collected as debris and
      // never read, but it would still be there. Rename is the last step, so
      // reaching here usually means it is still called `.part`.
      try {
        await temp.delete();
      } on FileSystemException {
        // Already gone, or undeletable. Neither changes the failure below.
      }
      rethrow;
    }
  }
}
