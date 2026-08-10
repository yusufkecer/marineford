/// Implementation of the `marineford` command line tool.
///
/// The commands here do the parts of code push that happen on a developer's
/// machine: making a signing key, compiling a patch, checking it against the
/// cost model, and publishing it somewhere a device can fetch it.
///
/// Everything a device will later verify is verified here first, using the same
/// `marineford_core` code. A patch that cannot be parsed, whose ABI does not match,
/// or whose manifest the device-side reader would reject, fails at publish time
/// in front of someone who can fix it.
library;

export 'src/builder.dart' show BuiltPatch, PatchBuilder;
export 'src/commands.dart'
    show Console, MarinefordCommands, RecordingConsole, StdoutConsole;
export 'src/config.dart'
    show CliException, MarinefordIdRegistry, MarinefordProject;
export 'src/lint.dart' show LintFinding, LintSeverity, PatchLinter;
export 'src/publish.dart' show ChannelPublisher, DirectoryTarget, PublishTarget;
