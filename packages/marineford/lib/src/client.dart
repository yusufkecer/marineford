import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:marineford_core/marineford_core.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'dispatch.dart';
import 'observer.dart';
import 'store.dart';
import 'transport.dart';

/// Drives the whole patch lifecycle: check, verify, install, activate, recover.
///
/// The ordering here is the safety model, so it is worth stating plainly:
/// signature before decompression, hash before parse, ABI before load, boot
/// token before activation. Each of those is one step earlier than feels
/// necessary, which is the point — every one of them guards against trusting
/// bytes a step too soon.
final class MarinefordClient {
  /// Creates a client. Prefer [Marineford.init].
  @visibleForTesting
  MarinefordClient({
    required this.config,
    required PatchStore store,
    PatchTransport? transport,
  })  : _store = store,
        _transport = transport ?? config.transport ?? HttpPatchTransport(),
        _verifier = PatchVerifier.fromBase64(config.publicKey);

  /// The configuration this client runs with.
  final MarinefordConfig config;

  final PatchStore _store;
  final PatchTransport _transport;
  final PatchVerifier _verifier;

  PatchState? _state;
  Timer? _confirmTimer;

  /// Persisted state. Available after [start].
  PatchState get state =>
      _state ?? (throw StateError('MarinefordClient.start() has not run yet'));

  /// The patch currently dispatching, or 0 if the store build is running.
  int get activePatch => Patch.isActive ? (_activeNumber ?? 0) : 0;
  int? _activeNumber;

  void _emit(PatchEvent event) => config.observer?.onEvent(event);

  /// Recovers from the previous run and activates any pending patch.
  ///
  /// Never throws. A patch system that can prevent an app from starting is
  /// worse than no patch system, so every failure path here ends in "run the
  /// store build".
  Future<void> start() async {
    try {
      await _start();
    } on Object catch (error, stackTrace) {
      _emit(PatchCheckFailed(error, stackTrace));
      Patch.deactivate();
    }
  }

  Future<void> _start() async {
    var current = await _store.readState();

    // A boot token that survived the last run means that run never reached a
    // healthy state. Give the patch one more chance, then stop trying.
    //
    // The token is deliberately *not* cleared here on the retry path. Clearing
    // it would reset the attempt counter on every launch, and the guard would
    // never fire no matter how many times the app died. Only a healthy boot
    // (markBootSuccessful) clears it.
    final booting = current.booting;
    if (booting != null && current.bootAttempts >= config.maxBootAttempts) {
      _emit(PatchBlocklisted(
          booting,
          'failed to boot ${current.bootAttempts} times '
          '(limit ${config.maxBootAttempts})'));
      current = current.copyWith(
        blocklist: {...current.blocklist, booting},
        installed: current.installed == booting ? 0 : current.installed,
        clearBooting: true,
        bootAttempts: 0,
      );
      await _store.deletePatch(booting);
      await _store.writeState(current);
    }

    _state = current;

    final installed = current.installed;
    if (installed > 0 && !current.blocklist.contains(installed)) {
      await _activateStored(installed);
    }
  }

  Future<void> _activateStored(int number) async {
    final bytes = await _store.readPatch(number);
    if (bytes == null) {
      await _abandon(number, 'patch file is missing from disk');
      return;
    }
    // Re-verify on every load rather than trusting that it was verified when it
    // was written. The file has been sitting on a device we do not control.
    final program = await _openVerified(bytes, number);
    if (program == null) return;

    await _writeBootToken(number);
    _activateProgram(program, number);
  }

  /// Parses, verifies and decompresses a container into runnable bytecode.
  ///
  /// Returns null and records the reason if anything is wrong.
  Future<Uint8List?> _openVerified(Uint8List bytes, int number) async {
    final MfpContainer container;
    try {
      container = MfpContainer.parse(bytes);
    } on MarinefordFormatException catch (e) {
      await _abandon(number, e.message);
      return null;
    }

    if (container.abi != config.abi) {
      await _abandon(number,
          'built against ABI ${container.abi}, this build is ${config.abi}');
      return null;
    }

    // Signature first. The payload is compressed, and inflating bytes nobody
    // has vouched for is how a few kilobytes turns into an out-of-memory kill.
    final signatureOk =
        await _verifier.verify(container.signedRegion, container.signature);
    if (!signatureOk) {
      await _abandon(number, 'signature does not verify');
      return null;
    }

    try {
      return container.flags.has(MfpFlags.gzip)
          ? Uint8List.fromList(gzip.decode(container.payload))
          : container.payload;
    } on Object catch (e) {
      await _abandon(number, 'payload could not be decompressed: $e');
      return null;
    }
  }

  void _activateProgram(Uint8List bytecode, int number) {
    final stopwatch = Stopwatch()..start();
    final runtime = Runtime(bytecode.buffer
        .asByteData(bytecode.offsetInBytes, bytecode.lengthInBytes));
    for (final plugin in config.plugins) {
      runtime.addPlugin(plugin);
    }
    runtime.loadGlobalOverrides();

    final slots = resolveSlots(runtime, config.appVersion);
    Patch.activate(
      runtime,
      slots,
      failureThreshold: config.failureThreshold,
      onFailure: (id, error, stackTrace) {
        _emit(PatchFailure(id, error, stackTrace, Patch.failureCount));
        if (Patch.failureCount >= config.failureThreshold) {
          unawaited(_abandon(
              number, 'threw ${Patch.failureCount} times while running'));
        }
      },
    );
    _activeNumber = number;
    stopwatch.stop();
    _emit(PatchActivated(number, slots.length, stopwatch.elapsed));

    _scheduleBootConfirmation();
  }

  void _scheduleBootConfirmation() {
    final after = config.autoConfirmBootAfter;
    if (after == null) return;
    _confirmTimer?.cancel();
    _confirmTimer = Timer(after, () => unawaited(markBootSuccessful()));
  }

  Future<void> _writeBootToken(int number) async {
    final current = state;
    final attempts = current.booting == number ? current.bootAttempts + 1 : 1;
    _state = current.copyWith(booting: number, bootAttempts: attempts);
    await _store.writeState(_state!);
  }

  /// Declares the current run healthy, clearing the crash-loop token.
  ///
  /// Called automatically after [MarinefordConfig.autoConfirmBootAfter] unless that
  /// is null. Call it yourself at the point your app is genuinely usable — a
  /// timer cannot tell a working app from one stuck on a spinner.
  Future<void> markBootSuccessful() async {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    final current = _state;
    if (current == null || current.booting == null) return;
    _state = current.copyWith(clearBooting: true, bootAttempts: 0);
    await _store.writeState(_state!);
  }

  /// Stops using a patch and makes sure it is never picked again.
  Future<void> _abandon(int number, String reason) async {
    _emit(PatchBlocklisted(number, reason));
    if (_activeNumber == number) {
      Patch.deactivate();
      _activeNumber = null;
    }
    final current = _state;
    if (current != null) {
      _state = current.copyWith(
        blocklist: {...current.blocklist, number},
        installed: current.installed == number ? 0 : current.installed,
        clearBooting: true,
      );
      await _store.writeState(_state!);
    }
    await _store.deletePatch(number);
  }

  /// Checks the manifest and installs whatever the rules allow.
  ///
  /// Safe to call whenever. Never throws; failures become [PatchCheckFailed].
  Future<PatchDecision> checkForUpdate() async {
    try {
      return await _checkForUpdate();
    } on Object catch (error, stackTrace) {
      _emit(PatchCheckFailed(error, stackTrace));
      return const StayOnCurrent();
    }
  }

  Future<PatchDecision> _checkForUpdate() async {
    final current = state;
    final response = await _transport.get(config.manifestUrl,
        ifNoneMatch: current.manifestEtag);

    if (response.notModified) {
      _emit(const PatchRejected(0, 'manifest unchanged (304)'));
      return const StayOnCurrent();
    }
    if (!response.isOk) {
      throw PatchTransportException(
          'manifest fetch returned HTTP ${response.statusCode}');
    }

    // The manifest is signed detached, over its exact bytes. Verifying before
    // parsing means the parser never runs on attacker-chosen input.
    final signature = await _transport.get(_siblingUri('manifest.json.sig'));
    if (!signature.isOk) {
      throw PatchTransportException(
          'manifest signature fetch returned HTTP ${signature.statusCode}');
    }
    if (!await _verifier.verify(response.body, signature.body)) {
      _emit(const PatchRejected(0, 'manifest signature does not verify'));
      return const StayOnCurrent();
    }

    final manifest = PatchManifest.parse(utf8.decode(response.body));
    _emit(ManifestLoaded(manifest, fromCache: false));

    if (response.etag != null) {
      _state = current.copyWith(manifestEtag: response.etag);
      await _store.writeState(_state!);
    }

    final decision = selectPatch(
      manifest,
      SelectionContext(
        appId: config.appId,
        abi: config.abi,
        appVersion: config.appVersion,
        installId: current.installId,
        installedPatch: _state!.installed,
        blocklist: _state!.blocklist,
      ),
    );
    _emit(DecisionMade(decision));

    switch (decision) {
      case ApplyPatch(entry: final entry):
        await _download(entry);
      case RollBackToBase(reason: final reason):
        await _rollBackToBase(reason);
      case StayOnCurrent():
        break;
    }
    return decision;
  }

  Future<void> _download(PatchEntry entry) async {
    final url = config.manifestUrl.resolve(entry.url);
    final response = await _transport.get(url);
    if (!response.isOk) {
      throw PatchTransportException(
          'patch #${entry.number} returned HTTP ${response.statusCode}');
    }

    if (response.body.length != entry.size) {
      _emit(PatchRejected(
          entry.number,
          'downloaded ${response.body.length} bytes, manifest says '
          '${entry.size}'));
      return;
    }
    if (!matchesSha256(response.body, entry.sha256)) {
      _emit(PatchRejected(entry.number, 'sha256 does not match the manifest'));
      return;
    }

    // Prove it loads before recording it as installed. Writing first would let
    // a patch that fails ABI or signature checks occupy the installed slot and
    // have to be un-installed on the next launch.
    final program = await _openVerified(response.body, entry.number);
    if (program == null) return;

    await _store.savePatch(entry.number, response.body);
    _state = state.copyWith(installed: entry.number);
    await _store.writeState(_state!);
    await _store.prune(keep: config.retainPatches);
    _emit(PatchInstalled(entry.number, response.body.length));

    if (config.activation == PatchActivation.immediate) {
      await _writeBootToken(entry.number);
      _activateProgram(program, entry.number);
    }
  }

  Future<void> _rollBackToBase(String reason) async {
    _emit(PatchRejected(_state?.installed ?? 0, reason));
    Patch.deactivate();
    _activeNumber = null;
    _state = state.copyWith(installed: 0, clearBooting: true, bootAttempts: 0);
    await _store.writeState(_state!);
  }

  /// Abandons the current patch and runs the store build.
  ///
  /// The patch stays on disk and is not blocklisted, so a later manifest can
  /// legitimately reinstate it. Use [_abandon] semantics — via a publisher
  /// revocation — when a patch should never come back.
  Future<void> rollback() async {
    await _rollBackToBase('rollback requested by the app');
  }

  /// Releases the transport and cancels pending timers.
  void dispose() {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _transport.close();
  }

  Uri _siblingUri(String name) {
    final segments = [...config.manifestUrl.pathSegments];
    if (segments.isEmpty) {
      return config.manifestUrl.replace(pathSegments: [name]);
    }
    segments[segments.length - 1] = name;
    return config.manifestUrl.replace(pathSegments: segments);
  }
}

/// The entry point most apps use.
///
/// ```dart
/// await Marineford.init(MarinefordConfig(
///   appId: 'com.example.app',
///   appVersion: Version.parse('1.4.0'),
///   abi: kMarinefordAbi,
///   manifestUrl: Uri.parse('https://cdn.example.com/prod/manifest.json'),
///   publicKey: kMarinefordPublicKey,
/// ));
/// unawaited(Marineford.checkForUpdate());
/// ```
abstract final class Marineford {
  static MarinefordClient? _instance;

  /// The running client, or null before [init].
  static MarinefordClient? get instance => _instance;

  /// Sets up patching and activates anything already installed.
  ///
  /// Await this before `runApp` so the first frame already reflects the patch.
  /// It reads two small files and, when a patch is present, builds a dart_eval
  /// runtime — measured at 0.74ms, which is why it is safe on the startup path.
  static Future<MarinefordClient> init(MarinefordConfig config) async {
    final root = await _channelDirectory(config.channel);
    final client = MarinefordClient(
      config: config,
      store: PatchStore(root),
    );
    await client.start();
    _instance = client;
    return client;
  }

  /// Checks the manifest and installs what the rules allow.
  static Future<PatchDecision> checkForUpdate() async =>
      _instance?.checkForUpdate() ?? const StayOnCurrent();

  /// Declares this run healthy. See [MarinefordClient.markBootSuccessful].
  static Future<void> markBootSuccessful() async =>
      _instance?.markBootSuccessful();

  /// Abandons the active patch for this run.
  static Future<void> rollback() async => _instance?.rollback();

  /// Tears everything down. Mostly useful in tests.
  static void dispose() {
    _instance?.dispose();
    _instance = null;
    Patch.deactivate();
  }

  static Future<Directory> _channelDirectory(String channel) async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'marineford', channel));
  }
}
