import 'dart:io';

import 'package:marineford_cli/src/runner.dart';

/// Sets the exit code rather than returning it.
///
/// Returning an `int` from `main` does nothing in Dart — the VM ignores it and
/// the process exits 0. That is how a failing `marineford doctor` and every
/// handled `CliException` came to report success to the shell, which is worse
/// than a crash: a CI step that gates on the exit code passed regardless.
Future<void> main(List<String> arguments) async {
  exitCode = await run(arguments);
}
