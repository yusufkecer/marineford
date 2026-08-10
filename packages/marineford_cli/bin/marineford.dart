import 'dart:io';

import 'package:args/args.dart';
import 'package:marineford_cli/marineford_cli.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

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

Future<int> main(List<String> arguments) async {
  final parser = ArgParser()..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('init')
    ..addOption('app-id', help: 'Application id, e.g. com.example.app')
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('abi').addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('build')
    ..addOption('abi', help: 'Override the ABI fingerprint. Testing only.')
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('publish')
    ..addOption('to',
        help: 'Output directory for the channel', defaultsTo: 'dist')
    ..addOption('channel', help: 'Release channel')
    ..addOption('min-app-version', help: 'Lowest app version this patch suits')
    ..addOption('max-app-version', help: 'Highest app version this patch suits')
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
    ..addFlag('help', abbr: 'h', negatable: false);

  parser.addCommand('doctor').addFlag('help', abbr: 'h', negatable: false);

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('marineford: ${e.message}\n');
    stderr.writeln(_usage);
    return 64;
  }

  final command = results.command;
  if (command == null || results.flag('help')) {
    stdout.write(_usage);
    return command == null && arguments.isNotEmpty ? 64 : 0;
  }

  const commands = MarinefordCommands();
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
        await commands.init(Directory.current, appId: appId);

      case 'abi':
        await commands.abi(MarinefordProject.load());

      case 'build':
        await commands.build(MarinefordProject.load(),
            abiOverride: command.option('abi'));

      case 'publish':
        final project = MarinefordProject.load();
        final channel = command.option('channel') ?? project.channel;
        await commands.publish(
          project,
          target: _target(project, command.option('to')!, channel),
          channel: channel,
          appVersionMin: _version(command, 'min-app-version'),
          appVersionMax: _version(command, 'max-app-version'),
          rollout: _percent(command.option('percent')),
          notes: command.option('notes'),
        );

      case 'rollout':
        final project = MarinefordProject.load();
        final channel = command.option('channel') ?? project.channel;
        await commands.rollout(
          project,
          target: _target(project, command.option('to')!, channel),
          channel: channel,
          number: _number(command),
          fraction: _percent(command.option('percent')),
        );

      case 'revoke':
        final project = MarinefordProject.load();
        final channel = command.option('channel') ?? project.channel;
        if (command.rest.isEmpty) {
          throw const CliException('revoke needs at least one patch number');
        }
        await commands.revoke(
          project,
          target: _target(project, command.option('to')!, channel),
          channel: channel,
          numbers: <int>{
            for (final raw in command.rest) _parseNumber(raw),
          },
        );

      case 'doctor':
        return await commands.doctor(MarinefordProject.load()) ? 0 : 1;
    }
    return 0;
  } on CliException catch (e) {
    stderr.writeln('marineford: $e');
    return 1;
  }
}

PublishTarget _target(MarinefordProject project, String to, String channel) =>
    DirectoryTarget(Directory(p.join(project.root.path, to, channel)));

Version _version(ArgResults command, String name) {
  final raw = command.option(name);
  if (raw == null) {
    throw CliException(
      'publish needs --$name',
      hint: 'A patch must say which app builds it is safe for. Use the '
          'version range of the store releases that share this ABI.',
    );
  }
  try {
    return Version.parse(raw);
  } on FormatException {
    throw CliException('--$name: "$raw" is not a semantic version');
  }
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

double _percent(String? raw) {
  final value = double.tryParse((raw ?? '100').replaceAll('%', ''));
  if (value == null || value < 0 || value > 100) {
    throw CliException('--percent must be between 0 and 100, got "$raw"');
  }
  return value / 100;
}
