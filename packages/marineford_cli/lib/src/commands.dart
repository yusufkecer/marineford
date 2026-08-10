import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:marineford_core/marineford_core.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'builder.dart';
import 'config.dart';
import 'lint.dart';
import 'publish.dart';

/// Where a command writes its output.
///
/// Injected so tests can read what a command said instead of scraping stdout.
abstract interface class Console {
  /// Writes a line.
  void write(String line);
}

/// A [Console] that prints.
final class StdoutConsole implements Console {
  /// Creates a [StdoutConsole].
  const StdoutConsole();

  @override
  void write(String line) => stdout.writeln(line);
}

/// A [Console] that records, for tests.
final class RecordingConsole implements Console {
  /// Every line written, in order.
  final List<String> lines = <String>[];

  @override
  void write(String line) => lines.add(line);

  /// Everything written, joined.
  String get text => lines.join('\n');
}

/// The `marineford` commands.
final class MarinefordCommands {
  /// Creates [MarinefordCommands] writing to [console].
  const MarinefordCommands({this.console = const StdoutConsole()});

  /// Where output goes.
  final Console console;

  /// Creates `marineford.yaml` and a signing key pair.
  ///
  /// The private key is written with the narrowest permissions the platform
  /// allows and added to `.gitignore` immediately, because the most likely way
  /// to lose control of a code-push channel is to commit its key on day one.
  Future<void> init(Directory root, {required String appId}) async {
    final configFile = File(p.join(root.path, 'marineford.yaml'));
    if (configFile.existsSync()) {
      throw CliException('${configFile.path} already exists');
    }

    final keyDirectory = Directory(p.join(root.path, '.marineford'));
    await keyDirectory.create(recursive: true);

    final signer = await PatchSigner.generate();
    final keyFile = File(p.join(keyDirectory.path, 'signing.key'));
    await keyFile.writeAsString(base64Encode(await signer.extractSeed()));
    await File(p.join(keyDirectory.path, 'signing.pub'))
        .writeAsString(signer.publicKeyBase64);
    _restrictPermissions(keyFile);

    await configFile.writeAsString('''
# marineford project configuration.
app_id: $appId
channel: prod

# Where patches will be served from. Used to build absolute URLs in output.
# base_url: https://cdn.example.com/prod

# Paths, relative to this file.
patch_package: patch
app_package: .

# Warn when a packed patch exceeds this. Patches are usually a few KB.
size_budget_kb: 256
''');

    await _appendGitignore(root, <String>['.marineford/signing.key', 'out/']);

    console
      ..write('Created ${configFile.path}')
      ..write('Created ${keyFile.path}  <- NEVER commit this')
      ..write('')
      ..write('Add this to your app:')
      ..write('')
      ..write("  const kMarinefordPublicKey = '${signer.publicKeyBase64}';")
      ..write('')
      ..write('The private key signs every patch. Anyone who has it can run '
          'code in your app,')
      ..write('so keep it out of version control and put it in a CI secret '
          'rather than a file.')
      ..write('Losing it means you cannot publish again for builds already in '
          'the field —')
      ..write('back it up somewhere you trust.');
  }

  /// Prints the ABI fingerprint the app was generated with.
  Future<void> abi(MarinefordProject project) async {
    final registry = _requireRegistry(project);
    console
      ..write(registry.abi)
      ..write('${registry.ids.length} patchable function'
          '${registry.ids.length == 1 ? '' : 's'}');
  }

  /// Compiles, lints and packs the patch, writing a `.mfp` to `out/`.
  Future<File> build(MarinefordProject project, {String? abiOverride}) async {
    final signer = await _loadSigner(project);
    final registry = abiOverride == null ? _requireRegistry(project) : null;
    final abi = abiOverride ?? registry!.abi;

    final built = await PatchBuilder(project)
        .build(signer: signer, abi: abi, knownIds: registry?.ids);

    await project.outputDirectory.create(recursive: true);
    final file = File(p.join(project.outputDirectory.path, 'patch.mfp'));
    await file.writeAsBytes(built.bytes, flush: true);

    final ratio = built.rawSize / built.compressedSize;
    console
      ..write('Compiled ${built.overrideIds.length} override'
          '${built.overrideIds.length == 1 ? '' : 's'}:')
      ..write(built.overrideIds.map((id) => '  $id').join('\n'))
      ..write('')
      ..write('Bytecode  ${_kb(built.rawSize)}')
      ..write('Packed    ${_kb(built.bytes.length)} '
          '(${ratio.toStringAsFixed(1)}x compression)')
      ..write('Written   ${file.path}');

    final sizeFinding = PatchLinter(project).checkSize(built.compressedSize);
    final findings = <LintFinding>[
      ...built.warnings,
      if (sizeFinding != null) sizeFinding,
    ];
    _reportFindings(findings);
    return file;
  }

  /// Uploads a built patch and updates the manifest.
  Future<void> publish(
    MarinefordProject project, {
    required PublishTarget target,
    required String channel,
    required Version appVersionMin,
    required Version appVersionMax,
    File? patchFile,
    double rollout = 1.0,
    String? notes,
  }) async {
    final signer = await _loadSigner(project);
    final file =
        patchFile ?? File(p.join(project.outputDirectory.path, 'patch.mfp'));
    if (!file.existsSync()) {
      throw CliException(
        'no patch at ${file.path}',
        hint: 'Run `marineford build` first.',
      );
    }
    final bytes = Uint8List.fromList(await file.readAsBytes());

    // Parse what we are about to publish with the device-side reader. If this
    // throws, the patch was never going to load anywhere.
    final container = MfpContainer.parse(bytes);

    final publisher = ChannelPublisher(
      target: target,
      project: project,
      channel: channel,
    );
    final manifest = await publisher.read();
    final number = publisher.nextNumber(manifest);

    await target.put('$number.mfp', bytes);
    final updated = publisher.withPatch(
      manifest,
      PatchEntry(
        number: number,
        url: '$number.mfp',
        size: bytes.length,
        sha256: sha256Hex(bytes),
        abi: container.abi,
        runtime: VersionConstraint.parse('>=$appVersionMin <=$appVersionMax'),
        rollout: rollout,
        notes: notes,
      ),
    );
    await publisher.write(updated, signer);

    console
      ..write('Published patch #$number to $channel')
      ..write('  ${target.describe('$number.mfp')}')
      ..write('  ${_kb(bytes.length)}, ABI ${container.abi.substring(0, 20)}…')
      ..write('  apps >=$appVersionMin <=$appVersionMax')
      ..write('  rollout ${(rollout * 100).toStringAsFixed(0)}%');
    if (rollout < 1.0) {
      console.write('');
      console.write('Raise it with: marineford rollout $number --percent 100');
    }
  }

  /// Marks patches as revoked so devices roll back.
  Future<void> revoke(
    MarinefordProject project, {
    required PublishTarget target,
    required String channel,
    required Set<int> numbers,
  }) async {
    final signer = await _loadSigner(project);
    final publisher = ChannelPublisher(
      target: target,
      project: project,
      channel: channel,
    );
    final manifest = await publisher.read();
    await publisher.write(publisher.withRevoked(manifest, numbers), signer);

    console
      ..write('Revoked ${numbers.map((n) => '#$n').join(', ')} on $channel')
      ..write('Devices roll back on their next check. Nothing is deleted, so '
          'the files stay')
      ..write('available for forensics.');
  }

  /// Changes a patch's staged rollout fraction.
  Future<void> rollout(
    MarinefordProject project, {
    required PublishTarget target,
    required String channel,
    required int number,
    required double fraction,
  }) async {
    final signer = await _loadSigner(project);
    final publisher = ChannelPublisher(
      target: target,
      project: project,
      channel: channel,
    );
    final manifest = await publisher.read();
    await publisher.write(
        publisher.withRollout(manifest, number, fraction), signer);

    console.write('Patch #$number on $channel is now at '
        '${(fraction * 100).toStringAsFixed(0)}%');
    console.write('Devices already on it keep it; raising the number only '
        'adds devices.');
  }

  /// Checks that the project is in a state where publishing would work.
  Future<bool> doctor(MarinefordProject project) async {
    var healthy = true;

    void ok(String message) => console.write('  ok    $message');
    void bad(String message, String hint) {
      healthy = false;
      console
        ..write('  FAIL  $message')
        ..write('        $hint');
    }

    console.write('Checking ${project.root.path}');

    if (project.privateKeyFile.existsSync()) {
      ok('signing key present');
    } else {
      bad('no signing key at ${project.privateKeyFile.path}',
          'Run `marineford init`, or restore the key from your secret store.');
    }

    if (_isGitTracked(project.root, project.privateKeyFile)) {
      final relative =
          p.relative(project.privateKeyFile.path, from: project.root.path);
      bad(
          'the signing key is tracked by git',
          'Run `git rm --cached $relative`, then rotate the key: anything '
              'already pushed has to be assumed compromised.');
    } else {
      ok('signing key is not in version control');
    }

    final registry = project.readIdRegistry();
    if (registry == null) {
      bad('no marineford_ids.json in ${project.appPackage}',
          'Run `dart run build_runner build` in your app.');
    } else if (registry.ids.isEmpty) {
      bad(
          'the app declares no patchable functions',
          'Nothing can be patched until something is marked with @patchable '
              'or @PatchableService. Start with a normaliser on your HTTP '
              'client\'s output.');
    } else {
      ok('${registry.ids.length} patchable function'
          '${registry.ids.length == 1 ? '' : 's'}, ABI '
          '${registry.abi.substring(0, 20)}…');
    }

    final patchLib =
        Directory(p.join(project.root.path, project.patchPackage, 'lib'));
    if (patchLib.existsSync()) {
      ok('patch package at ${project.patchPackage}');
    } else {
      bad('no patch package at ${project.patchPackage}/lib',
          'Create it, or point `patch_package` at the right directory.');
    }

    console.write(healthy ? '\nReady to publish.' : '\nNot ready.');
    return healthy;
  }

  void _reportFindings(List<LintFinding> findings) {
    if (findings.isEmpty) return;
    console.write('');
    for (final finding in findings) {
      final label =
          finding.severity == LintSeverity.warning ? 'warning' : 'note';
      console.write('$label: ${finding.message}');
      if (finding.hint != null) console.write('         ${finding.hint}');
    }
  }

  MarinefordIdRegistry _requireRegistry(MarinefordProject project) {
    final registry = project.readIdRegistry();
    if (registry == null) {
      throw CliException(
        'no marineford_ids.json at ${project.idRegistryFile.path}',
        hint: 'Run `dart run build_runner build` in your app so marineford_gen '
            'can record which functions are patchable.',
      );
    }
    return registry;
  }

  Future<PatchSigner> _loadSigner(MarinefordProject project) async {
    final fromEnvironment = Platform.environment['MARINEFORD_SIGNING_KEY'];
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      return PatchSigner.fromSeed(
          Uint8List.fromList(base64Decode(fromEnvironment.trim())));
    }
    final file = project.privateKeyFile;
    if (!file.existsSync()) {
      throw CliException(
        'no signing key at ${file.path}',
        hint:
            'Run `marineford init`, or set MARINEFORD_SIGNING_KEY to the base64 '
            'seed — that is the form to use in CI.',
      );
    }
    return PatchSigner.fromSeed(
        Uint8List.fromList(base64Decode((await file.readAsString()).trim())));
  }

  static String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  static void _restrictPermissions(File file) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', <String>['600', file.path]);
    } on ProcessException {
      // Best effort; the .gitignore entry is the protection that matters.
    }
  }

  static bool _isGitTracked(Directory root, File file) {
    try {
      final result = Process.runSync(
        'git',
        <String>['ls-files', '--error-unmatch', file.path],
        workingDirectory: root.path,
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static Future<void> _appendGitignore(
      Directory root, List<String> entries) async {
    final file = File(p.join(root.path, '.gitignore'));
    final existing = file.existsSync() ? await file.readAsString() : '';
    final missing =
        entries.where((entry) => !existing.contains(entry)).toList();
    if (missing.isEmpty) return;
    await file.writeAsString(
      '${existing.isEmpty || existing.endsWith('\n') ? existing : '$existing\n'}'
      '\n# marineford\n${missing.join('\n')}\n',
    );
  }
}
