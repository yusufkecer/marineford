import 'dart:io';

import 'package:marineford_cli/marineford_cli.dart';
import 'package:marineford_cli/src/runner.dart';
import 'package:test/test.dart';

/// Tests for the argument-parsing layer.
///
/// This file exists because its absence was expensive. Every other test in this
/// package calls `MarinefordCommands` directly, so `bin/` had no coverage at
/// all, and it held three bugs at once: `publish` read an option it never
/// declared and threw `ArgumentError` on every invocation, the guard against an
/// inclusive upper bound was written `r'<=s*d'` and matched nothing, and the
/// exit code was returned from `main`, where Dart discards it.
///
/// None of them are subtle. All three needed a test that called the entry
/// point rather than the layer underneath it.
void main() {
  late Directory root;
  late RecordingConsole out;
  late RecordingConsole err;

  setUp(() {
    root = Directory.systemTemp.createTempSync('marineford_runner');
    out = RecordingConsole();
    err = RecordingConsole();
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  Future<int> invoke(List<String> arguments) => run(
        arguments,
        output: out,
        errors: err,
        workingDirectory: root,
      );

  Future<void> initProject() async {
    expect(await invoke(<String>['init', 'com.example.app']), 0);
    out.lines.clear();
  }

  group('publish', () {
    test('does not throw on a well-formed invocation', () async {
      // The regression that matters most. Before the fix this threw
      // `ArgumentError: Could not find an option named "--app-versions"`,
      // which is not a `CliException` and so escaped the handler entirely —
      // every publish died with a stack trace, whatever it was passed.
      await initProject();

      final code = await invoke(<String>[
        'publish',
        '--app-versions',
        '>=1.4.0 <1.5.0',
      ]);

      // It still fails: nothing has been built. What matters is that it fails
      // as a handled error with a message, not as a crash.
      expect(code, 1);
      expect(err.text, startsWith('marineford: '));
      expect(err.text, isNot(contains('Could not find an option')));
    });

    test('asks for --app-versions when it is missing', () async {
      await initProject();

      expect(await invoke(<String>['publish']), 1);
      expect(err.text, contains('--app-versions'));
    });

    test('refuses an inclusive upper bound', () async {
      // The guard the broken regex disabled. `<=1.5.0` excludes `1.5.0+42`,
      // and a Flutter app version almost always carries a build number, so
      // this is the shape that silently applies to nobody.
      await initProject();

      expect(
        await invoke(<String>['publish', '--app-versions', '>=1.4.0 <=1.5.0']),
        1,
      );
      expect(err.text, contains('inclusive upper bound'));
      expect(err.text, contains('1.5.0+42'));
    });

    test('accepts an exclusive upper bound', () async {
      await initProject();

      await invoke(<String>['publish', '--app-versions', '>=1.4.0 <1.5.1']);
      expect(err.text, isNot(contains('inclusive upper bound')));
    });

    test('rejects an unparseable constraint with the parser message', () async {
      await initProject();

      expect(await invoke(<String>['publish', '--app-versions', 'not a range']),
          1);
      expect(err.text, contains('--app-versions'));
    });
  });

  group('exit codes', () {
    test('an unknown option is a usage error', () async {
      expect(await invoke(<String>['publish', '--nonsense']), 64);
      expect(err.text, contains('Could not find an option'));
    });

    test('an unknown command is a usage error', () async {
      expect(await invoke(<String>['frobnicate']), 64);
    });

    test('help succeeds and prints to stdout', () async {
      expect(await invoke(<String>['--help']), 0);
      expect(out.text, contains('marineford — code push for Flutter'));
      expect(err.lines, isEmpty);
    });

    test('help on a command describes it instead of running it', () async {
      // `--help` after a command name sets the subcommand's flag, not the root
      // one. Checking only the root meant this fell through to the switch and
      // ran the command — `marineford revoke 3 --help` revoked patch 3 and
      // exited 0, which is irreversible, and the usage text tells people to
      // type exactly this.
      await initProject();

      expect(await invoke(<String>['revoke', '3', '--help']), 0);
      expect(out.text, contains('--dry-run'),
          reason: 'it should describe the options');
      expect(out.text, isNot(contains('Revoked')),
          reason: 'asking what a command does must not do it');
    });

    test('help on every command is inert', () async {
      for (final name in <String>[
        'init',
        'abi',
        'build',
        'publish',
        'rollout',
        'revoke',
        'doctor',
      ]) {
        out.lines.clear();
        err.lines.clear();
        final fresh = Directory.systemTemp.createTempSync('marineford_help');
        addTearDown(() {
          try {
            fresh.deleteSync(recursive: true);
          } on FileSystemException {
            // Best effort.
          }
        });

        final code = await run(<String>[name, '--help'],
            output: out, errors: err, workingDirectory: fresh);

        expect(code, 0, reason: '$name --help must succeed');
        expect(fresh.listSync(), isEmpty,
            reason: '$name --help must not touch the project');
      }
    });

    test('doctor fails on a directory with no project', () async {
      expect(await invoke(<String>['doctor']), 1);
    });

    test('init succeeds and is not repeatable', () async {
      expect(await invoke(<String>['init', 'com.example.app']), 0);
      expect(await invoke(<String>['init', 'com.example.app']), 1,
          reason: 'overwriting a signing key must not be a silent success');
    });

    test('a bad patch number is rejected rather than parsed as zero', () async {
      await initProject();
      expect(await invoke(<String>['revoke', 'abc']), 1);
      expect(err.text, contains('not a patch number'));
    });

    test('revoke needs at least one number', () async {
      await initProject();
      expect(await invoke(<String>['revoke']), 1);
      expect(err.text, contains('at least one patch number'));
    });

    test('a percentage outside 0-100 is rejected', () async {
      await initProject();
      expect(
        await invoke(<String>['rollout', '1', '--percent', '140']),
        1,
      );
      expect(err.text, contains('--percent'));
    });
  });

  group('the exit code reaches the process', () {
    test('a failing command exits non-zero', () async {
      // `main` used to `return` the code, which Dart ignores — the process
      // exited 0 no matter what happened. Nothing but running the real binary
      // catches that, so this one test pays for a subprocess.
      final result = await Process.run(
        Platform.resolvedExecutable,
        <String>['run', 'bin/marineford.dart', 'doctor'],
        workingDirectory: Directory.current.path,
        environment: <String, String>{'MARINEFORD_TEST_ROOT': root.path},
      );

      expect(result.exitCode, isNot(0),
          reason: 'doctor failed, so the shell must be told');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
