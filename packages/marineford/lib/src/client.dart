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
import 'sandbox.dart';
import 'store.dart';
import 'transport.dart';

/// Drives the whole patch lifecycle: check, verify, install, activate, recover.
///
/// The ordering here is the safety model, so it is worth stating plainly:
/// signature before decompression, hash before parse, ABI before load, boot
/// token before activation, and the ETag only after the decision has actually
/// been carried out. Each is one step later or earlier than feels necessary,
/// which is the point — every one of them guards against trusting something a
/// step too soon.
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
  Future<PatchDecision>? _inFlight;
  Future<void>? _maintenance;

  /// Persisted state. Available after [start].
  ///
  /// Can lag by a moment after a patch is abandoned at runtime. Giving up on a
  /// patch is triggered from inside interpreted code, on a callback that cannot
  /// wait for a disk write, so the write is started and not awaited. Use
  /// [settled] before reading this if you need the answer to be final.
  PatchState get state =>
      _state ?? (throw StateError('MarinefordClient.start() has not run yet'));

  /// Completes when background writes have landed.
  ///
  /// There is exactly one thing the client does without being asked: abandon a
  /// patch whose interpreted code keeps throwing. That decision arrives on a
  /// dispatch callback, several frames inside the interpreter, where awaiting a
  /// file write is not an option — so it is started and left to finish.
  ///
  /// Which means [state] is briefly stale afterwards, and nothing said so.
  /// Anything that reads state to log it, report it, or assert on it needs a
  /// point to wait for, and a fixed delay is not one.
  Future<void> get settled async {
    await _inFlight;
    await _maintenance;
  }

  /// The patch currently dispatching, or 0 if the store build is running.
  int get activePatch => Patch.isActive ? (_activeNumber ?? 0) : 0;
  int? _activeNumber;

  /// Delivers an event without letting a bad observer break the client.
  void _emit(PatchEvent event) {
    final observer = config.observer;
    if (observer == null) return;
    try {
      observer.onEvent(event);
    } on Object {
      // An observer that throws must not take down the patch pipeline. It is
      // reporting on failures; it cannot be allowed to cause them.
    }
  }

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
      current = await _blocklist(
        current,
        booting,
        'failed to boot ${current.bootAttempts} times '
        '(limit ${config.maxBootAttempts})',
      );
    }

    _state = current;

    final installed = current.installed;
    if (installed > 0 && !current.blocklist.contains(installed)) {
      await _activateStored(installed);
    }
  }

  /// The single place a patch is given up on.
  ///
  /// Blocklisting, clearing the installed slot, deactivating and deleting the
  /// file all have to happen together; splitting them across call sites is how
  /// a device ends up blocklisting a patch it is still running, or running one
  /// it has blocklisted.
  Future<PatchState> _blocklist(
      PatchState from, int number, String reason) async {
    _emit(PatchBlocklisted(number, reason));
    if (_activeNumber == number) {
      Patch.deactivate();
      _activeNumber = null;
    }
    final next = from.copyWith(
      blocklist: <int>{...from.blocklist, number},
      installed: from.installed == number ? 0 : from.installed,
      clearBooting: true,
      bootAttempts: 0,
    );
    await _store.deletePatch(number);
    await _store.writeState(next);
    _state = next;
    return next;
  }

  Future<void> _activateStored(int number) async {
    final bytes = await _store.readPatch(number);
    if (bytes == null) {
      await _blocklist(state, number, 'patch file is missing from disk');
      return;
    }
    // Before opening it, not after. Decompression is the one step here that can
    // take the process down rather than throw — a signed payload that inflates
    // to more than the device can hold is killed by the OS, and an OOM does not
    // run a catch block. With the token written afterwards the attempt was
    // never recorded, so the next launch loaded the same patch and died the
    // same way: a permanent brick that the crash-loop guard never saw, because
    // the counter it reads was only ever incremented on the far side of the
    // thing that killed it.
    //
    // Ordering it this way costs one wasted token when a patch fails
    // verification, which _blocklist clears on its way out.
    await _writeBootToken(number);

    // Re-verify on every load rather than trusting that it was verified when it
    // was written. The file has been sitting on a device we do not control.
    final program = await _openVerified(bytes, number);
    if (program == null) return;

    _activateProgram(program, number);
  }

  /// Parses, verifies and decompresses a container into runnable bytecode.
  ///
  /// Returns null and records the reason if anything is wrong.
  Future<Uint8List?> _openVerified(Uint8List bytes, int number) async {
    final MfpContainer container;
    try {
      container = MfpContainer.parse(bytes);
    } on UnsupportedFlagsException catch (e) {
      // Refused, not condemned. This is the forward-compatibility hatch: the
      // patch is well-formed and uses something this build does not know about
      // yet. Blocklisting it made the hatch a trap — the blocklist is permanent
      // and nothing clears it, so a device that met a v2 patch once would still
      // be refusing that patch number after a store update to the build that
      // understands it.
      _emit(PatchRejectedEvent(number, e.message));
      await _forgetBootAttempt(number);
      return null;
    } on MarinefordFormatException catch (e) {
      // Everything else here is a malformed file, which is a fact about the
      // bytes rather than about this build. It will never become valid.
      await _blocklist(state, number, e.message);
      return null;
    }

    if (container.abi != config.fingerprint) {
      // Also not condemned, for the same reason. Selection already filters on
      // the manifest's ABI, so this is reached for a patch on disk after a
      // store update changed the fingerprint — an ordinary state, not a bad
      // patch. Blocklisting it would fill the set with old patch numbers and
      // conflate "crashed twice" with "not built for this binary".
      _emit(PatchRejectedEvent(
          number,
          'built against ABI ${container.abi}, this build is '
          '${config.fingerprint}'));
      await _forgetBootAttempt(number);
      return null;
    }

    // Signature first. The payload is compressed, and inflating bytes nobody
    // has vouched for is how a few kilobytes turns into an out-of-memory kill.
    final signatureOk =
        await _verifier.verify(container.signedRegion, container.signature);
    if (!signatureOk) {
      await _blocklist(state, number, 'signature does not verify');
      return null;
    }

    try {
      return container.flags.has(MfpFlags.gzip)
          ? _inflate(container.payload)
          : container.payload;
    } on Object catch (e) {
      await _blocklist(state, number, 'payload could not be decompressed: $e');
      return null;
    }
  }

  /// Ceiling on what a patch may inflate to.
  ///
  /// The container is capped at 8MB, which bounds the download and bounds
  /// nothing else: gzip reaches ratios around 1000:1 on repetitive input, so
  /// eight compressed megabytes can ask for gigabytes. The signature is checked
  /// first, so producing one needs the signing key — but a stolen key should buy
  /// an attacker a bad patch, not a device that cannot be recovered without a
  /// store release.
  ///
  /// Sixty-four megabytes is far above any real patch. The largest thing
  /// measured in `bench/` is under 10KB of bytecode, and a patch is a handful of
  /// functions by design.
  static const int _maxInflatedBytes = 64 * 1024 * 1024;

  /// Decompresses with a ceiling, refusing rather than allocating past it.
  ///
  /// `gzip.decode` takes no limit, so this drives the decoder in chunks and
  /// gives up the moment the output crosses [_maxInflatedBytes]. Checking as
  /// the chunks arrive is the entire point — a total measured after the fact is
  /// measured on memory already taken, which is too late to refuse it.
  static Uint8List _inflate(Uint8List payload) {
    final sink = _BoundedSink(_maxInflatedBytes);
    final converter = gzip.decoder.startChunkedConversion(sink);
    converter
      ..add(payload)
      ..close();
    return sink.takeBytes();
  }

  void _activateProgram(Uint8List bytecode, int number) {
    final stopwatch = Stopwatch()..start();
    final runtime = Runtime(bytecode.buffer
        .asByteData(bytecode.offsetInBytes, bytecode.lengthInBytes));
    for (final plugin in config.plugins) {
      runtime.addPlugin(plugin);
    }
    // Last, and that is the point. dart_eval configures plugins in the order
    // they were added and the last registration of a bridge wins, so adding
    // this after both DartIoPlugin and the app's own plugins is what lets it
    // take dart:io's ungated functions away from them.
    runtime.addPlugin(const MarinefordSandbox());
    for (final permission in config.permissions) {
      runtime.grant(permission);
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
          // Recorded rather than dropped, so `settled` has something to wait
          // on. Fire-and-forget is forced here — this runs on a dispatch
          // callback inside the interpreter — but forgetting the future
          // entirely left callers with no way to know when state was final.
          final write = _blocklist(state, number,
              'threw ${Patch.failureCount} times in a row while running');
          _maintenance = write;
          unawaited(write.whenComplete(() {
            if (identical(_maintenance, write)) _maintenance = null;
          }));
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
  /// Called automatically after [MarinefordConfig.autoConfirmBootAfter] unless
  /// that is null. Call it yourself at the point your app is genuinely usable —
  /// a timer cannot tell a working app from one stuck on a spinner.
  Future<void> markBootSuccessful() async {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    final current = _state;
    if (current == null || current.booting == null) return;

    // A patch that was activated and is no longer dispatching gave up during
    // this launch, and this boot is not the healthy one the token is waiting
    // for. Confirming anyway is how an async patch became immortal: the first
    // async failure drops the patch for the session and resets the failure
    // count in the same breath, so the runtime threshold can never be reached,
    // and clearing the token here meant the crash-loop guard never saw
    // anything either. Leaving the token is what lets the existing guard
    // count the launches and blocklist after maxBootAttempts.
    if (_activeNumber != null && !Patch.isActive) return;

    _state = current.copyWith(clearBooting: true, bootAttempts: 0);
    try {
      await _store.writeState(_state!);
    } on Object catch (error, stackTrace) {
      // The auto-confirm path calls this from a timer with no one awaiting it,
      // so an exception here is an unhandled async error in the app's zone —
      // from a library whose whole promise is that it cannot take the app
      // down. The cost of swallowing it is a boot token left on disk, which
      // costs one attempt against the crash-loop budget next launch.
      _emit(PatchCheckFailed(error, stackTrace));
    }
  }

  /// Checks the manifest and installs whatever the rules allow.
  ///
  /// Safe to call whenever, including concurrently: overlapping calls share one
  /// in-flight check rather than racing to read-modify-write the same state.
  /// Never throws; failures become [PatchCheckFailed].
  Future<PatchDecision> checkForUpdate() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _guardedCheck();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<PatchDecision> _guardedCheck() async {
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
      _emit(const ManifestUnchanged());
      return const StayOnCurrent();
    }
    if (!response.isOk) {
      throw PatchTransportException(
          'manifest fetch returned HTTP ${response.statusCode}');
    }

    // The manifest and its signature are one file. Reading the envelope does
    // not touch what is inside it, so no field validation, and not even a JSON
    // decode, runs on bytes the signature has not vouched for.
    final signed = SignedManifest.parse(response.body);
    if (!await _verifier.verify(signed.signedBytes, signed.signature)) {
      _emit(const PatchRejectedEvent(
          null,
          'manifest signature does not '
          'verify'));
      return const StayOnCurrent();
    }

    final manifest = signed.open();
    _emit(ManifestLoaded(manifest));

    final decision = selectPatch(
      manifest,
      SelectionContext(
        appId: config.appId,
        channel: config.channel,
        abi: config.fingerprint,
        appVersion: config.appVersion,
        installId: current.installId,
        installedPatch: current.installed,
        blocklist: current.blocklist,
        lastSequence: current.lastSequence,
      ),
    );
    _emit(DecisionMade(decision));

    switch (decision) {
      case ManifestRejected(reason: final reason):
        // Refused wholesale. Recording anything from it would treat a rejection
        // as a commitment, and both ways of doing that are exploitable:
        // adopting its sequence lets a replay walk the high-water mark down,
        // and caching its ETag turns every later check into a 304 and makes the
        // refusal permanent.
        _emit(PatchRejectedEvent(null, reason));
        return decision;
      case ApplyPatch(entry: final entry):
        final installed = await _download(entry);
        if (!installed) return decision;
      case RollBackToBase(reason: final reason):
        await _rollBackToBase(reason);
      case StayOnCurrent():
        break;
    }

    // Only now. Recording the ETag before the decision is carried out means a
    // failed download leaves the client sending If-None-Match for a manifest it
    // never finished with: the server answers 304, the check returns early, and
    // the patch is never retried until the publisher happens to change the
    // manifest again.
    //
    // The sequence advances on the same terms, and for the same reason.
    // PatchState keeps it monotonic regardless, so this cannot walk backwards.
    final next = state.copyWith(
      manifestEtag: response.etag,
      clearEtag: response.etag == null,
      lastSequence: manifest.sequence,
    );
    // Only touch the disk when something moved. A server that serves the
    // manifest without an ETag gets a full 200 on every check, and the decision
    // it leads to is almost always "nothing to do" — writing an identical file
    // each time costs an fsync and a rename for no information gained.
    if (next != state) {
      _state = next;
      await _store.writeState(next);
    }
    return decision;
  }

  /// Drops the boot token written for [number] before it was opened.
  ///
  /// `_activateStored` writes the token first on purpose — a payload that
  /// inflates past what the device can hold is killed by the OS, and an OOM
  /// runs no catch block, so the attempt has to be on disk before the
  /// dangerous part. That ordering assumed whatever refused the patch would
  /// clear the token on its way out, which `_blocklist` did.
  ///
  /// The two refusals that are *not* blocklists — a flag this build does not
  /// know, an ABI from a different binary — therefore left the token behind,
  /// and the crash-loop guard blocklisted the patch a couple of launches later
  /// with `failed to boot N times`. That is the exact conflation those two
  /// refusals exist to avoid, arriving late and under a wrong name.
  ///
  /// `installed` is deliberately left alone. Clearing it would make the next
  /// check select and download the same patch again, refuse it again, and loop;
  /// leaving it means the patch sits on disk being re-read and re-refused once
  /// per launch, which is cheap and stops the moment a build appears that can
  /// use it.
  Future<void> _forgetBootAttempt(int number) async {
    final current = _state;
    if (current == null || current.booting != number) return;
    _state = current.copyWith(clearBooting: true, bootAttempts: 0);
    try {
      await _store.writeState(_state!);
    } on Object catch (error, stackTrace) {
      _emit(PatchCheckFailed(error, stackTrace));
    }
  }

  /// Whether [url] is somewhere a patch for [manifest] is allowed to live.
  ///
  /// Same scheme, host and port — and for `file:`, where there is no host and
  /// no port to compare, the same directory. Without that last clause the check
  /// was vacuous for a bundled or test manifest: every `file:` URL matched
  /// every other, so an entry could name any path on the device and pass the
  /// guard that exists to stop exactly that.
  static bool _sameOrigin(Uri url, Uri manifest) {
    if (url.scheme != manifest.scheme) return false;
    if (url.isScheme('file')) {
      return p.equals(p.dirname(url.path), p.dirname(manifest.path));
    }
    return url.host == manifest.host && url.port == manifest.port;
  }

  /// Returns whether the patch is now installed.
  Future<bool> _download(PatchEntry entry) async {
    final url = config.manifestUrl.resolve(entry.url);
    // The manifest is signed, so this URL is the key holder's choice — but a
    // stolen key should only be able to replace patch *content*, and an
    // arbitrary host turns it into "point every device at a URL of my
    // choosing", which is a beacon carrying the app id and version whether or
    // not anything is ever served back. Same origin keeps the blast radius at
    // the bytes, where the signature check already meets it.
    if (!_sameOrigin(url, config.manifestUrl)) {
      _emit(PatchRejectedEvent(
          entry.number,
          'patch url $url is not on the same origin as the manifest '
          '(${config.manifestUrl})'));
      return false;
    }
    final response = await _transport.get(url);
    if (!response.isOk) {
      throw PatchTransportException(
          'patch #${entry.number} returned HTTP ${response.statusCode}');
    }

    if (response.body.length != entry.size) {
      _emit(PatchRejectedEvent(
          entry.number,
          'downloaded ${response.body.length} bytes, manifest says '
          '${entry.size}'));
      return false;
    }
    if (!matchesSha256(response.body, entry.sha256)) {
      _emit(PatchRejectedEvent(
          entry.number, 'sha256 does not match the manifest'));
      return false;
    }

    // Prove it loads before recording it as installed. Writing first would let
    // a patch that fails ABI or signature checks occupy the installed slot and
    // have to be un-installed on the next launch.
    final program = await _openVerified(response.body, entry.number);
    if (program == null) return false;

    await _store.savePatch(entry.number, response.body);
    _state = state.copyWith(installed: entry.number);
    await _store.writeState(_state!);
    // `protect` is what stops a rollback from deleting the patch it just
    // installed: after moving backwards the newly installed number is no longer
    // the highest on disk.
    await _store.prune(keep: config.retainPatches, protect: entry.number);
    _emit(PatchInstalled(entry.number, response.body.length));

    if (config.activation == PatchActivation.immediate) {
      await _writeBootToken(entry.number);
      _activateProgram(program, entry.number);
    }
    return true;
  }

  Future<void> _rollBackToBase(String reason) async {
    _emit(PatchRejectedEvent(_state?.installed, reason));
    Patch.deactivate();
    _activeNumber = null;
    _state = state.copyWith(installed: 0, clearBooting: true, bootAttempts: 0);
    try {
      await _store.writeState(_state!);
    } on Object catch (error, stackTrace) {
      // The rollback itself already happened — the patch is deactivated and
      // the in-memory state says so. Failing to record it means the next
      // launch tries the patch again, which is recoverable; throwing from a
      // path reached during startup is not.
      _emit(PatchCheckFailed(error, stackTrace));
    }
  }

  /// Abandons the current patch and runs the store build.
  ///
  /// The patch stays on disk and is not blocklisted, so a later manifest can
  /// legitimately reinstate it. Publisher revocation is what makes a patch never
  /// come back.
  Future<void> rollback() async {
    await _rollBackToBase('rollback requested by the app');
  }

  /// Releases the transport and cancels pending timers.
  void dispose() {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _transport.close();
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
  /// runtime — measured at about a millisecond, which is why it is safe on the
  /// startup path.
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

/// Collects decompressed output, refusing to grow past a limit.
///
/// The decoder emits its result in pieces, so the running total can be checked
/// while it is still cheap to stop. A sink that accumulated first and checked
/// afterwards would have already done the damage.
final class _BoundedSink extends ByteConversionSink {
  _BoundedSink(this.limit);

  /// Most bytes this will accept before throwing.
  final int limit;

  final BytesBuilder _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (_builder.length + chunk.length > limit) {
      throw FormatException('the patch inflates past the $limit byte ceiling; '
          'refusing to allocate it');
    }
    _builder.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(Uint8List.sublistView(
        chunk is Uint8List ? chunk : Uint8List.fromList(chunk), start, end));
    if (isLast) close();
  }

  @override
  void close() {}

  /// The bytes collected so far.
  Uint8List takeBytes() => _builder.takeBytes();
}
