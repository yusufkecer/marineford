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

/// A [Console] that prints to stderr.
///
/// Separate from [StdoutConsole] so the runner can be handed both and a test
/// can tell which stream a message went to — the difference matters to anyone
/// piping this in a script.
final class StderrConsole implements Console {
  /// Creates a [StderrConsole].
  const StderrConsole();

  @override
  void write(String line) => stderr.writeln(line);
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
    final keyFile =
        await _createPrivate(File(p.join(keyDirectory.path, 'signing.key')));
    await keyFile.writeAsString(base64Encode(await signer.extractSeed()));
    await File(p.join(keyDirectory.path, 'signing.pub'))
        .writeAsString(signer.publicKeyBase64);

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
  ///
  /// [appVersionMin] is the lowest app version the patch will be published for.
  /// The linter needs it to tell you when an override's own constraint excludes
  /// devices you are about to publish to.
  Future<File> build(
    MarinefordProject project, {
    String? abiOverride,
    Version? appVersionMin,
  }) async {
    final signer = await _loadSigner(project);

    // --abi replaces one thing: the fingerprint. It says nothing about which
    // dispatch ids exist, and those two only travelled together because they
    // happen to be written to the same file. Treating the flag as "ignore the
    // registry" turned off the typo check as a side effect — and a mistyped
    // id is not an error anywhere else in the pipeline. It builds, it signs,
    // it publishes, and it never fires on a single device.
    final registry = abiOverride == null
        ? _requireRegistry(project)
        : project.readIdRegistry();

    final AbiFingerprint abi;
    try {
      abi = AbiFingerprint.parse(abiOverride ?? registry!.abi);
    } on FormatException catch (e) {
      throw CliException(
        e.message,
        hint: 'Run `dart run build_runner build` in your app so marineford_gen '
            'can regenerate lib/marineford.g.dart.',
      );
    }

    if (abiOverride != null && registry == null) {
      console.write('note: --abi was given and there is no marineford_ids.json '
          'to read, so override ids cannot be checked for typos.');
    }

    final built = await PatchBuilder(project).build(
      signer: signer,
      abi: abi,
      appVersionMin: appVersionMin ?? Version.parse('0.0.0'),
      knownIds: registry?.ids,
    );

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
    required VersionConstraint appVersions,
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

    // Everything a device will check, checked here first, against the same
    // code. A patch that fails any of this was never going to load anywhere,
    // and finding out now costs a second instead of a support ticket.
    final container = MfpContainer.parse(bytes);

    final verifier = PatchVerifier(signer.publicKey);
    if (!await verifier.verify(container.signedRegion, container.signature)) {
      throw const CliException(
        'the patch is not signed by this project\'s key',
        hint: 'It was probably built before `marineford init` regenerated the '
            'key, or copied from another project. Run `marineford build` '
            'again.',
      );
    }

    final registry = project.readIdRegistry();
    if (registry != null && AbiFingerprint.tryParse(registry.abi) != null) {
      final expected = AbiFingerprint.parse(registry.abi);
      if (container.abi != expected) {
        throw CliException(
          'this patch was built against ABI ${container.abi}, but the app '
          'currently generates $expected',
          hint: 'The app changed after the patch was built. Run '
              '`marineford build` again, or publish from the revision the '
              'patch was built from.',
        );
      }
    }

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
        runtime: appVersions,
        rollout: rollout,
        notes: notes,
      ),
    );
    await publisher.write(updated, signer);

    console
      ..write('Published patch #$number to $channel')
      ..write('  ${target.describe('$number.mfp')}')
      ..write('  ${_kb(bytes.length)}, ABI ${_shortAbi(container.abi)}')
      ..write('  apps $appVersions')
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
    Version? previewFor,
  }) async {
    final publisher = ChannelPublisher(
      target: target,
      project: project,
      channel: channel,
    );
    final manifest = await publisher.read();

    if (previewFor != null) {
      _previewRevoke(
          project, manifest, publisher, channel, numbers, previewFor);
      return;
    }

    final signer = await _loadSigner(project);
    await publisher.write(publisher.withRevoked(manifest, numbers), signer);

    console
      ..write('Revoked ${numbers.map((n) => '#$n').join(', ')} on $channel')
      ..write('Devices roll back on their next check. Nothing is deleted, so '
          'the files stay')
      ..write('available for forensics.');
  }

  /// Shows where each device would end up if [numbers] were revoked.
  ///
  /// Revoking is the one command with no way back — the revoked list only ever
  /// grows, so a number retired by mistake is retired for good and the fix is a
  /// fresh publish. It is also the command whose effect is least obvious:
  /// devices do not simply stop patching, they move to the best patch still
  /// standing, which may be an older one, or the store build, or nothing at
  /// all. This runs the real [selectPatch] against a hypothetical manifest and
  /// prints the answer before anything is written.
  ///
  /// Rollout is normalised to 100% for the simulation. Leaving it in would make
  /// every row true only for the one synthetic device this asks about; the
  /// fractions that actually change the answer are called out underneath
  /// instead.
  ///
  /// The simulated device has an empty blocklist, which is the other place this
  /// is optimistic and the reason the header says so. A device that crash-looped
  /// on the patch it would otherwise fall back to goes further back still, and
  /// nothing here can know which devices those are — the blocklist is local and
  /// never reported.
  void _previewRevoke(
    MarinefordProject project,
    PatchManifest manifest,
    ChannelPublisher publisher,
    String channel,
    Set<int> numbers,
    Version appVersion,
  ) {
    final registry = _requireRegistry(project);
    final revoked = publisher.withRevoked(manifest, numbers);
    final everyoneInRollout = PatchManifest(
      schema: revoked.schema,
      appId: revoked.appId,
      channel: revoked.channel,
      sequence: revoked.sequence,
      generatedAt: revoked.generatedAt,
      patches: <PatchEntry>[
        for (final entry in revoked.patches) entry.copyWith(rollout: 1),
      ],
      revoked: revoked.revoked,
    );

    String outcome(int installed) {
      final decision = selectPatch(
        everyoneInRollout,
        SelectionContext(
          appId: project.appId,
          channel: channel,
          abi: AbiFingerprint.parse(registry.abi),
          appVersion: appVersion,
          installId: 'preview',
          installedPatch: installed,
        ),
      );
      return switch (decision) {
        ApplyPatch(entry: final entry) => '#${entry.number}',
        RollBackToBase() => 'the store build',
        // Not reachable from a manifest this command just built — it carries
        // the project's own app id and channel — but a hole here would be a
        // silent wrong answer rather than a compile error, so it is spelled out.
        ManifestRejected(reason: final reason) => 'nothing ($reason)',
        StayOnCurrent() =>
          installed == 0 ? 'nothing' : 'unchanged (#$installed)',
      };
    }

    final states = <int>[
      0,
      for (final entry in manifest.patches) entry.number,
    ]..sort();

    console
      ..write('Revoking ${numbers.map((n) => '#$n').join(', ')} on $channel — '
          'dry run, nothing is written.')
      ..write('Simulated for app $appVersion, with every device inside the '
          'rollout and nothing locally blocklisted.')
      ..write('')
      ..write('  device on     becomes')
      ..write('  ---------     -------');
    for (final installed in states) {
      final label = installed == 0 ? 'nothing' : '#$installed';
      console.write('  ${label.padRight(13)} ${outcome(installed)}');
    }

    final staged = <PatchEntry>[
      for (final entry in revoked.patches)
        if (entry.rollout < 1.0 && !revoked.revoked.contains(entry.number))
          entry,
    ];
    if (staged.isNotEmpty) {
      console.write('');
      for (final entry in staged) {
        console.write('  #${entry.number} is at '
            '${(entry.rollout * 100).toStringAsFixed(0)}% rollout, so the rest '
            'fall back further than the table shows.');
      }
      console.write('  Raise it first if that is not what you want: '
          'marineford rollout ${staged.first.number} --percent 100');
    }
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

    switch (_isGitTracked(project.root, project.privateKeyFile)) {
      case true:
        final relative =
            p.relative(project.privateKeyFile.path, from: project.root.path);
        bad(
            'the signing key is tracked by git',
            'Run `git rm --cached $relative`, then rotate the key: anything '
                'already pushed has to be assumed compromised.');
      case false:
        ok('signing key is not in version control');
      case null:
        console.write('  ?     could not ask git whether the signing key is '
            'tracked');
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
      final fingerprint = AbiFingerprint.tryParse(registry.abi);
      if (fingerprint == null) {
        bad('marineford_ids.json has a malformed ABI ("${registry.abi}")',
            'Delete it and run `dart run build_runner build` again.');
      } else {
        ok('${registry.ids.length} patchable function'
            '${registry.ids.length == 1 ? '' : 's'}, ABI '
            '${_shortAbi(fingerprint)}');
      }
    }

    final patchLib =
        Directory(p.join(project.root.path, project.patchPackage, 'lib'));
    if (patchLib.existsSync()) {
      ok('patch package at ${project.patchPackage}');
    } else {
      bad('no patch package at ${project.patchPackage}/lib',
          'Create it, or point `patch_package` at the right directory.');
    }

    // The check the command has always promised and never performed: compile
    // the patch and confirm every id it overrides is one the app declares. A
    // typo here costs nothing at publish time and everything afterwards, since
    // the override simply never fires.
    if (registry != null && patchLib.existsSync()) {
      try {
        final signer = await _loadSigner(project);
        final abi = AbiFingerprint.tryParse(registry.abi);
        if (abi != null) {
          final built = await PatchBuilder(project).build(
            signer: signer,
            abi: abi,
            appVersionMin: Version.parse('0.0.0'),
            knownIds: registry.ids,
          );
          final unknown = built.overrideIds
              .where((id) => !registry.ids.contains(id))
              .toList();
          if (unknown.isEmpty) {
            ok('${built.overrideIds.length} override'
                '${built.overrideIds.length == 1 ? '' : 's'}, all known to the '
                'app');
          } else {
            bad(
                'the patch overrides ids the app does not declare: '
                    '${unknown.join(', ')}',
                'They will never fire. Check the spelling; rebuild the app if '
                    'the function is new; and if it lives in a package the app '
                    'depends on, move it into the app — the registry and the '
                    'ABI fingerprint only cover this package.');
          }
        }
      } on CliException catch (e) {
        bad('the patch package does not build', e.hint ?? e.message);
      }
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
      return _signerFromSeed(
        fromEnvironment,
        'MARINEFORD_SIGNING_KEY',
        'The variable should hold the base64 seed `marineford init` printed, '
            'with nothing around it. A CI secret that picked up a newline or '
            'was stored as the public key looks exactly like this.',
      );
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
    return _signerFromSeed(
      await file.readAsString(),
      file.path,
      'The file should hold nothing but the base64 seed `marineford init` '
      'wrote. Restore it from your backup — a key that cannot be read is a '
      'key you cannot publish with again.',
    );
  }

  /// Builds a signer from a base64 [seed], naming [source] when it will not.
  ///
  /// A malformed key reached the user as a bare `FormatException` and a stack
  /// trace, which is a poor way to learn that a CI secret has a stray newline
  /// in it. It is also the one path where the answer is never "try again": the
  /// signing key is the whole security model, so the message says which of the
  /// two places it came from and what a good one looks like.
  Future<PatchSigner> _signerFromSeed(
      String seed, String source, String hint) async {
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base64Decode(seed.trim()));
    } on FormatException catch (e) {
      throw CliException(
          'the signing key in $source is not base64 '
          '(${e.message})',
          hint: hint);
    }
    try {
      return await PatchSigner.fromSeed(bytes);
    } on FormatException catch (e) {
      // Well-formed base64 of the wrong length, most often: a public key
      // pasted where the seed belonged. Named rather than caught as `Object`,
      // so a future `fromSeed` that reports something else — a revoked key, a
      // key of the wrong kind — reaches the user as itself instead of being
      // relabelled "not a usable seed" and sending them after the wrong thing.
      throw CliException(
        'the signing key in $source is not a usable Ed25519 seed (${e.message})',
        hint: hint,
      );
    } on ArgumentError catch (e) {
      throw CliException(
        'the signing key in $source was refused by Ed25519 (${e.message})',
        hint: hint,
      );
    }
  }

  static String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  /// A fingerprint short enough to read, long enough to tell two apart.
  ///
  /// Never substring the full form directly: it is only long enough by
  /// convention, and a shorter one would throw where a log line was wanted.
  static String _shortAbi(AbiFingerprint abi) {
    final text = abi.toString();
    return text.length <= 24 ? text : '${text.substring(0, 24)}…';
  }

  /// Creates [file] with restrictive permissions *before* anything is written.
  ///
  /// Order matters. Writing the key and then tightening the mode leaves a
  /// window where the secret exists world-readable, which on a shared machine
  /// is the whole exposure.
  static Future<File> _createPrivate(File file) async {
    await file.create(recursive: true);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', <String>['600', file.path]);
      } on ProcessException {
        // Best effort; the .gitignore entry is the protection that matters.
      }
    }
    return file;
  }

  /// Whether git tracks [file], or null when git could not answer.
  ///
  /// Distinguishes "not tracked" from "no git here". Reporting a missing git as
  /// a clean bill of health is how a key ends up committed by someone who was
  /// told it was safe.
  static bool? _isGitTracked(Directory root, File file) {
    try {
      final probe = Process.runSync('git', <String>['rev-parse', '--git-dir'],
          workingDirectory: root.path);
      if (probe.exitCode != 0) return null;
      final result = Process.runSync(
        'git',
        <String>['ls-files', '--error-unmatch', file.path],
        workingDirectory: root.path,
      );
      return result.exitCode == 0;
    } on ProcessException {
      return null;
    }
  }

  /// Appends the entries git does not already have, matching whole lines.
  ///
  /// Substring matching would consider `.marineford/signing.key` already
  /// present because some unrelated line happens to contain it — and the one
  /// entry that must never be missed is the one holding the signing key.
  static Future<void> _appendGitignore(
      Directory root, List<String> entries) async {
    final file = File(p.join(root.path, '.gitignore'));
    final existing = file.existsSync() ? await file.readAsString() : '';
    final lines =
        const LineSplitter().convert(existing).map((l) => l.trim()).toSet();
    final missing = entries.where((entry) => !lines.contains(entry)).toList();
    if (missing.isEmpty) return;
    await file.writeAsString(
      '${existing.isEmpty || existing.endsWith('\n') ? existing : '$existing\n'}'
      '\n# marineford\n${missing.join('\n')}\n',
    );
  }
}
