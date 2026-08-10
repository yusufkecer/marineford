/// Thrown when data that arrived over the network cannot be trusted enough to
/// use.
///
/// Everything marineford_core parses — manifests, `.mfp` containers — comes from
/// outside the app. Malformed input is expected, not exceptional, so these
/// carry a human-readable [message] meant to end up in a log or a
/// `marineford doctor` report rather than in front of a user.
sealed class MarinefordFormatException implements Exception {
  /// Creates a [MarinefordFormatException].
  const MarinefordFormatException(this.message);

  /// What was wrong, phrased for whoever has to debug it.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The manifest could not be parsed, or a required field was missing or had
/// the wrong shape.
final class ManifestFormatException extends MarinefordFormatException {
  /// Creates a [ManifestFormatException].
  const ManifestFormatException(super.message);
}

/// The manifest declares a schema version this build does not understand.
///
/// Treated separately from [ManifestFormatException] because it is not a bug:
/// it means the publishing side is newer than the client, and the correct
/// response is to do nothing and keep running the current code.
final class UnsupportedSchemaException extends MarinefordFormatException {
  /// Creates an [UnsupportedSchemaException].
  const UnsupportedSchemaException(this.found, this.maxSupported)
      : super('manifest schema $found is newer than the supported maximum '
            '$maxSupported; ignoring this manifest');

  /// Schema version the manifest declared.
  final int found;

  /// Highest schema version this build can read.
  final int maxSupported;
}

/// The `.mfp` container is not a well-formed patch file.
final class MfpFormatException extends MarinefordFormatException {
  /// Creates a [MfpFormatException].
  const MfpFormatException(super.message);
}

/// The `.mfp` container sets capability flags this build does not implement.
///
/// This is the forward-compatibility escape hatch: a v2 patch that needs the
/// Flutter bridge must be refused cleanly by a v1 client rather than loaded
/// and blown up halfway through.
final class UnsupportedFlagsException extends MarinefordFormatException {
  /// Creates an [UnsupportedFlagsException].
  const UnsupportedFlagsException(this.unsupported)
      : super('patch requires capabilities this build does not have '
            '(unsupported flag bits: $unsupported); a newer marineford is '
            'needed to apply it');

  /// The bits that were set but not understood.
  final int unsupported;
}
