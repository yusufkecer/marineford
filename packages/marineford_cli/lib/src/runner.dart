import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../marineford_cli.dart';

const _usage = '''
marineford — code push for Flutter

  init <app-id>        Create marineford.yaml and a signing key pair
  abi                  Print this build's ABI fingerprint
  build                Compile, lint and pack the patch package
  publish              Upload the packed patch and update the manifest
  rollout <n>          Change a patch's staged rollout percentage
  revoke <n> [n...]    Revoke patches so devices roll back
  doctor               Check the project is ready to publish

Run `marineford <command> --help` for the options of a command.
''';

/// Runs the `marineford` command line and returns the process exit code.
///
/// Lives here rather than in `bin/` so it can be tested, and returns the code
/// rather than setting it so a test can read it. Argument parsing is where the
/// three worst bugs this CLI has had all lived: a `publish` that threw on every
/// invocation because it read an option it never declared, an upper-bound guard
/// whose regex was missing its escapes and matched nothing, and an exit code
/// that was returned from `main` and therefore discarded. None of the three were
/// visible to a suite that only ever called the library underneath.
Future<int> run(
  List<String> arguments, {
  Console output = const StdoutConsole(),
  Console errors = const StderrConsole(),
  Directory? workingDirectory,
}) async {
  final cwd = workingDirectory ?? Directory.current;
  final parser = ArgParser()..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('init')
    ..addOption('app-id', help: 'Application id, e.g. com.example.app')
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('abi').addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('build')
    ..addOption('min-app-version',
        help: 'Lowest app version you will publish this patch for; lets the '
            'linter check override constraints against it')
    ..addOption('abi', help: 'Override the ABI fingerprint. Testing only.')
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('publish')
    ..addOption('to',
        help: 'Output directory for the channel', defaultsTo: 'dist')
    ..addOption('channel', help: 'Release channel')
    // One constraint rather than a min and a max pair. `_constraint` has always
    // parsed a single `VersionConstraint`, its error messages have always named
    // `--app-versions`, and the README has always taught it — the pair was
    // declared here and read nowhere, which is how `option('app-versions')`
    // ended up throwing on every publish.
    ..addOption('app-versions',
        help: "App versions this patch is safe for, e.g. '>=1.4.0 <1.5.0'")
    ..addOption('percent',
        help: 'Initial rollout percentage', defaultsTo: '100')
    ..addOption('notes', help: 'Note recorded in the manifest')
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('rollout')
    ..addOption('to', defaultsTo: 'dist')
    ..addOption('channel')
    ..addOption('percent', help: 'New rollout percentage')
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('revoke')
    ..addOption('to', defaultsTo: 'dist')
    ..addOption('channel')
    // The answer differs per app version — a patch constrained to <1.5.0 is not
    // a fallback for a device on 1.5.0 — so the preview has to be told which
    // cohort it is being asked about rather than picking one.
    ..addOption('dry-run',
        valueHelp: 'app version',
        help: 'Show where devices would end up, and write nothing.')
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('doctor').addFlag('help', abbr: 'h', negatable: false);

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    errors
      ..write('marineford: ${e.message}\n')
      ..write(_usage);
    return 64;
  }

  // Asking for help is not a usage error. The two cases were folded into one
  // condition and `--help` fell into the wrong half of it, so `marineford
  // --help` printed the usage and then exited 64.
  if (results.flag('help')) {
    output.write(_usage);
    return 0;
  }

  final command = results.command;
  if (command == null) {
    output.write(_usage);
    return arguments.isEmpty ? 0 : 64;
  }

  // `--help` after a command name sets the *subcommand's* flag, not the root
  // one, so checking only the root meant `marineford revoke 3 --help` fell
  // through to the switch and revoked patch 3 — a command with no undo, run by
  // someone asking what it does. The usage text above tells people to type
  // exactly that.
  if (command.flag('help')) {
    output
      ..write('marineford ${command.name}')
      ..write('')
      ..write(parser.commands[command.name]!.usage);
    return 0;
  }

  final commands = MarinefordCommands(console: output);
  try {
    switch (command.name) {
      case 'init':
        final appId = command.option('app-id') ??
            (command.rest.isNotEmpty ? command.rest.first : null);
        if (appId == null) {
          throw const CliException(
            'init needs an application id',
            hint: 'Example: marineford init com.example.app',
          );
        }
        await commands.init(cwd, appId: appId);

      case 'abi':
        await commands.abi(MarinefordProject.load(cwd));

      case 'build':
        await commands.build(
          MarinefordProject.load(cwd),
          abiOverride: command.option('abi'),
          appVersionMin: _optionalVersion(command, 'min-app-version'),
        );

      case 'publish':
        final project = MarinefordProject.load(cwd);
        final channel = command.option('channel') ?? project.channel;
        final constraint = _constraint(command);
        await commands.publish(
          project,
          target: _target(project, command.option('to')!, channel),
          channel: channel,
          appVersions: constraint,
          rollout: _percent(command.option('percent')),
          notes: command.option('notes'),
        );

      case 'rollout':
        final project = MarinefordProject.load(cwd);
        final channel = command.option('channel') ?? project.channel;
        await commands.rollout(
          project,
          target: _target(project, command.option('to')!, channel),
          channel: channel,
          number: _number(command),
          fraction: _percent(command.option('percent')),
        );

      case 'revoke':
        final project = MarinefordProject.load(cwd);
        final channel = command.option('channel') ?? project.channel;
        if (command.rest.isEmpty) {
          throw const CliException('revoke needs at least one patch number');
        }
        final preview = command.option('dry-run');
        await commands.revoke(
          project,
          target: _target(project, command.option('to')!, channel),
          channel: channel,
          numbers: <int>{
            for (final raw in command.rest) _parseNumber(raw),
          },
          previewFor: preview == null ? null : _parseVersion(preview),
        );

      case 'doctor':
        return await commands.doctor(MarinefordProject.load(cwd)) ? 0 : 1;
    }
    return 0;
  } on CliException catch (e) {
    errors.write('marineford: $e');
    return 1;
  }
}

PublishTarget _target(MarinefordProject project, String to, String channel) =>
    DirectoryTarget(Directory(p.join(project.root.path, to, channel)));

/// Parses `--app-versions`, refusing the shape that silently excludes almost
/// everyone.
///
/// A `<=1.5.0` upper bound looks right and is not: pub_semver orders build
/// metadata, so `1.5.0+42` — the form a Flutter app version takes as soon as it
/// has a build number, which is always — sits *above* `1.5.0` and is excluded.
/// The patch then silently never applies to the most common case there is.
VersionConstraint _constraint(ArgResults command) {
  final raw = command.option('app-versions');
  if (raw == null) {
    throw const CliException(
      'publish needs --app-versions',
      hint: 'A patch must say which app builds it is safe for. Use an '
          "exclusive upper bound: --app-versions '>=1.4.0 <1.5.0'",
    );
  }
  final VersionConstraint constraint;
  try {
    constraint = VersionConstraint.parse(raw);
  } on FormatException catch (e) {
    throw CliException('--app-versions: ${e.message}');
  }
  // The escapes matter: `r'<=s*d'` reads as `<=` followed by any number of the
  // letter `s` and then the letter `d`, which no version constraint contains.
  // The guard below matched nothing at all until this was `\s` and `\d`.
  if (RegExp(r'<=\s*\d').hasMatch(raw)) {
    throw CliException(
      '--app-versions uses an inclusive upper bound ($raw)',
      hint: 'Build metadata sorts above the bare version, so <=1.5.0 excludes '
          '1.5.0+42 — and a Flutter app version almost always carries a build '
          'number. Use an exclusive bound instead: <1.5.1',
    );
  }
  return constraint;
}

int _number(ArgResults command) {
  if (command.rest.isEmpty) {
    throw const CliException('this command needs a patch number');
  }
  return _parseNumber(command.rest.first);
}

int _parseNumber(String raw) {
  final value = int.tryParse(raw.replaceFirst('#', ''));
  if (value == null || value <= 0) {
    throw CliException('"$raw" is not a patch number');
  }
  return value;
}

Version _parseVersion(String raw) {
  try {
    return Version.parse(raw);
  } on FormatException {
    throw CliException('"$raw" is not a version',
        hint: 'Pass the app version the preview should answer for, as it '
            'appears in your pubspec — for example 1.4.0 or 1.4.0+42.');
  }
}

double _percent(String? raw) {
  final value = double.tryParse((raw ?? '100').replaceAll('%', ''));
  if (value == null || value < 0 || value > 100) {
    throw CliException('--percent must be between 0 and 100, got "$raw"');
  }
  return value / 100;
}

/// Parses an optional `--<name>` semantic version.
Version? _optionalVersion(ArgResults command, String name) {
  final raw = command.option(name);
  if (raw == null) return null;
  try {
    return Version.parse(raw);
  } on FormatException {
    throw CliException('--$name: "$raw" is not a semantic version');
  }
}
