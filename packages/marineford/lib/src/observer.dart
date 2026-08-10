import 'package:marineford_core/marineford_core.dart';
import 'package:meta/meta.dart';

/// Something the patch client did, or refused to do.
///
/// marineford publishes patches from a static file, so there is no server to
/// report back to and no dashboard telling you whether a patch actually landed.
/// These events are the replacement: wire them to whatever you already use for
/// crash reporting and you get the same visibility. Ignore them and a patch can
/// fail on every device in the field without you ever finding out — that is the
/// real cost of the static-hosting decision, and it is worth being explicit
/// about.
sealed class PatchEvent {
  const PatchEvent();
}

/// A manifest was fetched and read.
final class ManifestLoaded extends PatchEvent {
  /// Creates a [ManifestLoaded] event.
  const ManifestLoaded(this.manifest, {required this.fromCache});

  /// The manifest that was read.
  final PatchManifest manifest;

  /// Whether the server answered 304 and the cached copy was reused.
  final bool fromCache;

  @override
  String toString() =>
      'ManifestLoaded(${manifest.patches.length} patches, cached: $fromCache)';
}

/// The check ran and produced a decision.
final class DecisionMade extends PatchEvent {
  /// Creates a [DecisionMade] event.
  const DecisionMade(this.decision);

  /// What the selection rules concluded, including why patches were skipped.
  final PatchDecision decision;

  @override
  String toString() => 'DecisionMade($decision)';
}

/// A patch was downloaded, verified and written to disk.
final class PatchInstalled extends PatchEvent {
  /// Creates a [PatchInstalled] event.
  const PatchInstalled(this.number, this.bytes);

  /// Patch number.
  final int number;

  /// Size of the downloaded container.
  final int bytes;

  @override
  String toString() => 'PatchInstalled(#$number, $bytes bytes)';
}

/// A patch started dispatching.
final class PatchActivated extends PatchEvent {
  /// Creates a [PatchActivated] event.
  const PatchActivated(this.number, this.overrides, this.elapsed);

  /// Patch number.
  final int number;

  /// How many functions it replaces.
  final int overrides;

  /// How long activation took. Worth watching: it lands on your startup path.
  final Duration elapsed;

  @override
  String toString() =>
      'PatchActivated(#$number, $overrides overrides, ${elapsed.inMilliseconds}ms)';
}

/// Interpreted code threw. The original function ran instead.
final class PatchFailure extends PatchEvent {
  /// Creates a [PatchFailure] event.
  const PatchFailure(this.id, this.error, this.stackTrace, this.count);

  /// Dispatch id of the function that failed.
  final String id;

  /// What it threw.
  final Object error;

  /// Where.
  final StackTrace stackTrace;

  /// How many failures this patch has produced so far.
  final int count;

  @override
  String toString() => 'PatchFailure($id, #$count): $error';
}

/// A patch was refused, or abandoned after being installed.
final class PatchRejected extends PatchEvent {
  /// Creates a [PatchRejected] event.
  const PatchRejected(this.number, this.reason);

  /// Patch number, or 0 when the rejection was not about a specific patch.
  final int number;

  /// Why.
  final String reason;

  @override
  String toString() => 'PatchRejected(#$number): $reason';
}

/// A patch was blocklisted locally and will never be loaded again.
final class PatchBlocklisted extends PatchEvent {
  /// Creates a [PatchBlocklisted] event.
  const PatchBlocklisted(this.number, this.reason);

  /// Patch number.
  final int number;

  /// Why — a failed boot, or too many runtime failures.
  final String reason;

  @override
  String toString() => 'PatchBlocklisted(#$number): $reason';
}

/// The client gave up on patching for this run.
final class PatchCheckFailed extends PatchEvent {
  /// Creates a [PatchCheckFailed] event.
  const PatchCheckFailed(this.error, this.stackTrace);

  /// What went wrong — usually the network.
  final Object error;

  /// Where.
  final StackTrace stackTrace;

  @override
  String toString() => 'PatchCheckFailed: $error';
}

/// Receives [PatchEvent]s.
///
/// Implement this and hand it to the client to get patch activity into your
/// existing logging or crash reporting.
abstract interface class PatchObserver {
  /// Called for every event. Must not throw; the client does not guard you.
  void onEvent(PatchEvent event);
}

/// A [PatchObserver] that keeps events in memory. Useful in tests and for a
/// debug screen.
@visibleForTesting
final class RecordingObserver implements PatchObserver {
  /// Everything seen so far, oldest first.
  final List<PatchEvent> events = <PatchEvent>[];

  @override
  void onEvent(PatchEvent event) => events.add(event);

  /// Every recorded event of type [T].
  Iterable<T> ofType<T extends PatchEvent>() => events.whereType<T>();
}
