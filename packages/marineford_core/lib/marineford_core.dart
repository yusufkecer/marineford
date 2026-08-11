/// Pure-Dart core of marineford: everything both the runtime and the CLI must
/// agree on.
///
/// The manifest format, the `.mfp` container, the ABI fingerprint, signature
/// and hash verification, patch selection and rollout bucketing all live here.
/// Keeping them in one place is deliberate: if the side that writes a manifest
/// and the side that reads it do not share the code, they drift — and the
/// failure mode of that drift is a patch that installs on a device it should
/// never have reached.
///
/// Nothing in this library touches the network, the disk, or `dart:io`. It is
/// all pure functions over bytes, which is what makes the safety rules in
/// `selectPatch` exhaustively testable.
library;

export 'src/abi.dart';
export 'src/errors.dart';
export 'src/manifest.dart';
export 'src/mfp.dart';
export 'src/rollout.dart';
export 'src/selection.dart';
export 'src/signing.dart';
