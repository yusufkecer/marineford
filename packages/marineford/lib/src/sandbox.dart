import 'package:dart_eval/dart_eval_bridge.dart';

/// Thrown into interpreted code that reaches for something a patch may not use.
///
/// Reaches the dispatcher as an ordinary failure, so the marked function falls
/// back to its original body and the patch is dropped after enough attempts —
/// the same treatment as any other bug in downloaded code.
final class PatchDeniedException implements Exception {
  /// Creates a [PatchDeniedException] about [capability].
  const PatchDeniedException(this.capability);

  /// What the patch tried to reach.
  final String capability;

  @override
  String toString() => 'marineford denied "$capability" to a patch. Patches '
      'are business logic: they get the arguments they are given and the '
      'bridges the app registered, and nothing else.';
}

/// Closes the one hole in dart_eval's permission system.
///
/// dart_eval is default-deny and marineford grants nothing, so every `dart:io`
/// call a patch makes throws — `filesystem:read`, `filesystem:write`,
/// `network`, `process:run` are all checked with `assertPermission` before the
/// real call. Except in `socket.dart`, which checks nothing.
///
/// `InternetAddress.lookup` therefore ran for real: a patch could encode data
/// into a hostname, look it up, and the query would reach the attacker's
/// authoritative nameserver. It bypasses the `network` permission entirely,
/// leaves no HTTP trace, and leaves most corporate and mobile networks
/// unhindered. Reaching it needs a signing key, so the attacker is a malicious
/// patch author or someone holding a stolen key rather than a stranger — but
/// the documented blast radius was "the bodies of marked functions", and this
/// was outside it.
///
/// The fix is ownership. dart_eval resolves bridge registrations in order and
/// the last one wins, and plugins are configured in the order they were added,
/// so a plugin added after `DartIoPlugin` replaces its implementations. This
/// re-registers the ungated ones with implementations that refuse.
///
/// Deliberately not just `lookup`. A patch cannot open a socket — dart_eval
/// declares no bridge for one — so an `InternetAddress` is of no use to it by
/// any route, and "the class is unavailable" is a rule that can be stated in
/// one sentence and checked in one place.
///
/// This is a boundary, not a lint: it holds no matter how the patch spells the
/// import. `marineford build` also refuses `dart:io` in patch source, which is
/// the friendlier half of the same rule and the defeatable one.
final class MarinefordSandbox implements EvalPlugin {
  /// Creates a [MarinefordSandbox].
  const MarinefordSandbox();

  /// Bridge functions dart_eval registers for `dart:io` without a permission
  /// check, as of 0.8.5. Everything else in `dart:io` is gated already and
  /// denied by default because marineford grants no permissions.
  static const List<String> deniedIoBridges = <String>[
    'InternetAddress.',
    'InternetAddress.fromRawAddress',
    'InternetAddress.lookup',
    'InternetAddress.tryParse',
  ];

  @override
  String get identifier => 'marineford_sandbox';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    // Nothing to declare. The compiler still knows dart:io — it is in
    // dart_eval's own default plugin list and cannot be removed — so a patch
    // using it compiles. Refusing at runtime is what makes it not work, and
    // `marineford build` is what makes that obvious before publishing.
  }

  @override
  void configureForRuntime(Runtime runtime) {
    for (final name in deniedIoBridges) {
      runtime.registerBridgeFunc('dart:io', name, _deny(name));
    }
  }

  static EvalCallableFunc _deny(String name) =>
      (Runtime runtime, $Value? target, List<$Value?> args) =>
          throw PatchDeniedException('dart:io $name');
}
