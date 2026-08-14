import 'dart:convert';
import 'dart:io';

import 'package:marineford_cli/marineford_cli.dart';
import 'package:marineford_core/marineford_core.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

const _abi = 'sha256:'
    '1111111111111111111111111111111111111111111111111111111111111111';

const _goodPatch = '''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0 <2.0.0')
int normalize(int value) { return value * 2; }
''';

void main() {
  late Directory root;
  late RecordingConsole console;
  late MarinefordCommands commands;

  setUp(() {
    root = Directory.systemTemp.createTempSync('marineford_cli_test');
    console = RecordingConsole();
    commands = MarinefordCommands(console: console);
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows sometimes holds a handle briefly; not a test failure.
    }
  });

  void writePatchPackage(String source) {
    final lib = Directory(p.join(root.path, 'patch', 'lib'))
      ..createSync(recursive: true);
    File(p.join(lib.path, 'main.dart')).writeAsStringSync(source);
  }

  void writeIdRegistry({
    String abi = _abi,
    List<String> ids = const <String>['pkg:app/lib/api.dart#normalize'],
  }) {
    File(p.join(root.path, 'marineford_ids.json'))
        .writeAsStringSync(jsonEncode({
      'abi': abi,
      'ids': <Object?>[
        for (final id in ids) <String, Object?>{'id': id}
      ],
    }));
  }

  Future<MarinefordProject> initProject() async {
    await commands.init(root, appId: 'com.example.app');
    console.lines.clear();
    return MarinefordProject.load(root);
  }

  PublishTarget targetFor(String channel) =>
      DirectoryTarget(Directory(p.join(root.path, 'dist', channel)));

  group('init', () {
    test('creates config, keys and a gitignore entry', () async {
      await commands.init(root, appId: 'com.example.app');

      expect(File(p.join(root.path, 'marineford.yaml')).existsSync(), isTrue);
      expect(File(p.join(root.path, '.marineford', 'signing.key')).existsSync(),
          isTrue);
      expect(File(p.join(root.path, '.gitignore')).readAsStringSync(),
          contains('.marineford/signing.key'),
          reason: 'the key must be ignored before it can be committed by '
              'accident');
      expect(console.text, contains('kMarinefordPublicKey'));
      expect(console.text, contains('NEVER commit'));
    });

    test('refuses to overwrite an existing project', () async {
      await commands.init(root, appId: 'com.example.app');
      expect(() => commands.init(root, appId: 'other'),
          throwsA(isA<CliException>()));
    });

    test('the printed public key verifies the key it wrote', () async {
      await commands.init(root, appId: 'com.example.app');
      final printed = RegExp(r"kMarinefordPublicKey = '([^']+)'")
          .firstMatch(console.text)!
          .group(1)!;
      final seed = base64Decode(
          File(p.join(root.path, '.marineford', 'signing.key'))
              .readAsStringSync());
      final signer = await PatchSigner.fromSeed(seed);
      expect(signer.publicKeyBase64, printed);
    });
  });

  group('build', () {
    test('compiles, packs and reports', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);

      final file = await commands.build(project);

      expect(file.existsSync(), isTrue);
      expect(console.text, contains('pkg:app/lib/api.dart#normalize'));
      expect(console.text, contains('compression'));

      // What was written must be readable by the device-side parser.
      final container = MfpContainer.parse(file.readAsBytesSync());
      expect(container.abi, AbiFingerprint.parse(_abi));
      expect(container.flags.has(MfpFlags.gzip), isTrue);
    });

    test('a patch that builds widgets compiles from pure Dart', () async {
      // The load-bearing claim of the whole Flutter story: this process has no
      // Flutter and cannot have it — flutter_eval imports `dart:ui`, which the
      // standalone VM does not provide — yet it compiles a patch that builds a
      // widget tree. It works because the compiler only needs the declared
      // shapes, and those are bundled as data by `tool/bridge_dump`.
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''import 'package:flutter/material.dart';

class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0 <2.0.0')
Widget normalize(Map<String, dynamic> data) {
  return Column(
    children: [
      Text(data['label']),
      Padding(
        padding: EdgeInsets.all(8.0),
        child: Text(data['total']),
      ),
    ],
  );
}
''');

      final file = await commands.build(project);

      expect(file.existsSync(), isTrue);
      final container = MfpContainer.parse(file.readAsBytesSync());
      expect(container.abi, AbiFingerprint.parse(_abi));
      expect(console.text, contains('pkg:app/lib/api.dart#normalize'));
    });

    test('a patch importing dart:io is refused before it compiles', () async {
      // marineford grants a patch no permissions, so every dart:io call either
      // throws at runtime or is refused by the sandbox. Letting it build means
      // publishing a patch that silently does not do what it says — the worst
      // possible outcome for a system whose job is to fix things quietly.
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''import 'dart:io';

@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0')
Map normalize(Map raw) {
  InternetAddress.lookup('leak.example.com');
  return raw;
}
''');

      await expectLater(
        commands.build(project),
        throwsA(isA<CliException>().having(
            (CliException e) => '${e.message} ${e.hint}',
            'message',
            allOf(contains('dart:io'), contains('platform')))),
      );
    });

    test('a patch catching around an await is refused', () async {
      // dart_eval drops the catch at the suspension point, so the handler never
      // runs. Error handling that is written and silently dead is worse than
      // none, because the author stops looking at that case.
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''
@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0')
Future normalize(Map raw) async {
  try {
    await Future.delayed(Duration(milliseconds: 1));
    return raw;
  } catch (e) {
    return {};
  }
}
''');

      await expectLater(
        commands.build(project),
        throwsA(isA<CliException>().having(
            (CliException e) => '${e.message} ${e.hint}',
            'message',
            allOf(contains('await'), contains('catch')))),
      );
    });

    test('a try block without an await still builds', () async {
      // The other half: the check is about the suspension point, not about
      // try/catch, and ordinary synchronous error handling works in a patch.
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''
@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0')
Map normalize(Map raw) {
  try {
    return raw;
  } catch (e) {
    return {};
  }
}
''');

      await expectLater(commands.build(project), completes);
    });

    test('a patch that stays away from platform libraries still builds',
        () async {
      // The other half: the check must not fire on ordinary code that happens
      // to contain the word `import` or the string `dart:io` somewhere.
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''
@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0')
Map normalize(Map raw) {
  // Mentions dart:io in a comment, and 'import' in a string.
  final note = 'we do not import anything';
  if (note.length > 0) { return raw; }
  return raw;
}
''');

      expect((await commands.build(project)).existsSync(), isTrue);
    });

    test('the packed patch verifies against the project key', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);
      final file = await commands.build(project);

      final publicKey = File(p.join(root.path, '.marineford', 'signing.pub'))
          .readAsStringSync();
      final container = MfpContainer.parse(file.readAsBytesSync());
      expect(
        await PatchVerifier.fromBase64(publicKey)
            .verify(container.signedRegion, container.signature),
        isTrue,
      );
    });

    test('refuses when the app has not been generated yet', () async {
      final project = await initProject();
      writePatchPackage(_goodPatch);
      await expectLater(
        commands.build(project),
        throwsA(isA<CliException>()
            .having((e) => e.hint, 'hint', contains('build_runner'))),
      );
    });

    test('refuses an empty patch package', () async {
      final project = await initProject();
      writeIdRegistry();
      Directory(p.join(root.path, 'patch', 'lib')).createSync(recursive: true);
      await expectLater(commands.build(project), throwsA(isA<CliException>()));
    });

    test('refuses a patch with no overrides', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('int plain(int v) { return v; }');
      await expectLater(
        commands.build(project),
        throwsA(isA<CliException>().having(
            (e) => e.message, 'message', contains('no @RuntimeOverride'))),
      );
    });

    test('explains an unsupported Dart feature instead of dumping a trace',
        () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}
mixin Greeter { String hello() { return 'hi'; } }

@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0')
int normalize(int v) { return v; }
''');
      await expectLater(
        commands.build(project),
        throwsA(isA<CliException>()
            .having((e) => e.hint, 'hint', contains('dart_eval'))),
      );
    });
  });

  group('lint', () {
    test('warns about an override id the app does not have', () async {
      final project = await initProject();
      writeIdRegistry(ids: <String>['pkg:app/lib/api.dart#somethingElse']);
      writePatchPackage(_goodPatch);
      await commands.build(project);

      expect(console.text, contains('does not exist in the app'));
    });

    test('warns about a missing version constraint', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

@RuntimeOverride('pkg:app/lib/api.dart#normalize')
int normalize(int v) { return v; }
''');
      await commands.build(project);

      // dart_eval defaults the constraint to its own version, so an override
      // without one never fires. Silence here would be a patch that publishes
      // cleanly and does nothing.
      expect(console.text, contains('no usable version constraint'));
    });

    test('warns about a large interpreted loop', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage('''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

@RuntimeOverride('pkg:app/lib/api.dart#normalize', version: '>=1.0.0')
int normalize(int v) {
  var total = 0;
  for (var i = 0; i < 50000; i++) { total = total + i; }
  return total;
}
''');
      await commands.build(project);

      expect(console.text, contains('loops about 50000 times'));
      expect(console.text, contains('µs per call'));
    });
  });

  group('publish', () {
    Future<MarinefordProject> readyProject() async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);
      await commands.build(project);
      console.lines.clear();
      return project;
    }

    test('writes a signed manifest the device-side reader accepts', () async {
      final project = await readyProject();
      await commands.publish(
        project,
        target: targetFor('prod'),
        channel: 'prod',
        appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'),
      );

      final dist = Directory(p.join(root.path, 'dist', 'prod'));
      final manifestBytes =
          File(p.join(dist.path, 'manifest.json')).readAsBytesSync();
      final manifest = SignedManifest.parse(manifestBytes).open();

      expect(manifest.appId, 'com.example.app');
      expect(manifest.patches.single.number, 1);
      expect(manifest.patches.single.abi, AbiFingerprint.parse(_abi));
      expect(File(p.join(dist.path, '1.mfp')).existsSync(), isTrue);

      // One file, not two. A separate .sig left a window in which the new
      // manifest was up and the old signature was not.
      expect(
          File(p.join(dist.path, 'manifest.json.sig')).existsSync(), isFalse);

      final publicKey = File(p.join(root.path, '.marineford', 'signing.pub'))
          .readAsStringSync();
      final signed = SignedManifest.parse(manifestBytes);
      expect(
        await PatchVerifier.fromBase64(publicKey)
            .verify(signed.signedBytes, signed.signature),
        isTrue,
        reason: 'the signature must cover the exact bytes that were signed',
      );
    });

    test('the manifest hash matches the uploaded patch', () async {
      final project = await readyProject();
      await commands.publish(
        project,
        target: targetFor('prod'),
        channel: 'prod',
        appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'),
      );

      final dist = p.join(root.path, 'dist', 'prod');
      final manifest = SignedManifest.parse(
              File(p.join(dist, 'manifest.json')).readAsBytesSync())
          .open();
      final bytes = File(p.join(dist, '1.mfp')).readAsBytesSync();

      expect(manifest.patches.single.sha256, sha256Hex(bytes));
      expect(manifest.patches.single.size, bytes.length);
    });

    test('patch numbers increase', () async {
      final project = await readyProject();
      for (var i = 0; i < 3; i++) {
        await commands.publish(
          project,
          target: targetFor('prod'),
          channel: 'prod',
          appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'),
        );
      }
      final manifest = SignedManifest.parse(
              File(p.join(root.path, 'dist', 'prod', 'manifest.json'))
                  .readAsBytesSync())
          .open();
      expect(manifest.patches.map((e) => e.number), [3, 2, 1]);
    });

    test('channels are independent', () async {
      final project = await readyProject();
      await commands.publish(project,
          target: targetFor('beta'),
          channel: 'beta',
          appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'));

      expect(
          File(p.join(root.path, 'dist', 'beta', 'manifest.json')).existsSync(),
          isTrue);
      expect(
          File(p.join(root.path, 'dist', 'prod', 'manifest.json')).existsSync(),
          isFalse);
    });

    test('refuses to publish into another app\'s channel', () async {
      final project = await readyProject();
      final target = targetFor('prod');
      final otherSigner = await PatchSigner.generate();
      final foreign = SignedManifest.bytesToSign(PatchManifest(
        schema: 1,
        appId: 'com.other.app',
        channel: 'prod',
        sequence: 1,
        generatedAt: DateTime.utc(2026, 8, 10),
        patches: const <PatchEntry>[],
      ));
      await target.put('manifest.json',
          SignedManifest.encode(foreign, await otherSigner.sign(foreign)));

      await expectLater(
        commands.publish(project,
            target: target,
            channel: 'prod',
            appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9')),
        throwsA(isA<CliException>()
            .having((e) => e.message, 'message', contains('com.other.app'))),
      );
    });

    test('refuses when nothing has been built', () async {
      final project = await initProject();
      await expectLater(
        commands.publish(project,
            target: targetFor('prod'),
            channel: 'prod',
            appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9')),
        throwsA(isA<CliException>()
            .having((e) => e.hint, 'hint', contains('marineford build'))),
      );
    });

    test('a staged rollout is reported and can be raised', () async {
      final project = await readyProject();
      await commands.publish(project,
          target: targetFor('prod'),
          channel: 'prod',
          appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'),
          rollout: 0.1);
      expect(console.text, contains('rollout 10%'));

      await commands.rollout(project,
          target: targetFor('prod'), channel: 'prod', number: 1, fraction: 1.0);

      final manifest = SignedManifest.parse(
              File(p.join(root.path, 'dist', 'prod', 'manifest.json'))
                  .readAsBytesSync())
          .open();
      expect(manifest.patches.single.rollout, 1.0);
    });

    test('rollout on a patch that does not exist is an error', () async {
      final project = await readyProject();
      await commands.publish(project,
          target: targetFor('prod'),
          channel: 'prod',
          appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'));

      await expectLater(
        commands.rollout(project,
            target: targetFor('prod'),
            channel: 'prod',
            number: 99,
            fraction: 0.5),
        throwsA(isA<CliException>()),
      );
    });
  });

  group('revoke', () {
    test('adds to the revoked list without deleting anything', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);
      await commands.build(project);
      await commands.publish(project,
          target: targetFor('prod'),
          channel: 'prod',
          appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'));

      await commands.revoke(project,
          target: targetFor('prod'), channel: 'prod', numbers: {1});

      final dist = p.join(root.path, 'dist', 'prod');
      final manifest = SignedManifest.parse(
              File(p.join(dist, 'manifest.json')).readAsBytesSync())
          .open();
      expect(manifest.revoked, {1});
      expect(File(p.join(dist, '1.mfp')).existsSync(), isTrue,
          reason: 'the file stays available for forensics');
    });

    test('a dry run writes nothing and says where devices land', () async {
      // Revoking has no undo — the revoked list only grows — and its effect is
      // not obvious: devices do not stop patching, they move to the best patch
      // still standing. Both are reasons to be able to ask first.
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);
      for (var i = 0; i < 2; i++) {
        await commands.build(project);
        await commands.publish(project,
            target: targetFor('prod'),
            channel: 'prod',
            appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'));
      }

      await commands.revoke(project,
          target: targetFor('prod'),
          channel: 'prod',
          numbers: {2},
          previewFor: Version.parse('1.4.0'));

      final manifest = SignedManifest.parse(
              File(p.join(root.path, 'dist', 'prod', 'manifest.json'))
                  .readAsBytesSync())
          .open();
      expect(manifest.revoked, isEmpty,
          reason: 'a dry run must not touch the channel');
      expect(console.text, contains('nothing is written'));
      expect(console.text, contains('#1'),
          reason: 'devices on #2 fall back to #1, and the table has to say so');
    });

    test('a dry run warns when the fallback is behind a staged rollout',
        () async {
      // The trap the table alone would hide: #1 is the destination, but only
      // for the devices inside its rollout. The rest go further back.
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);
      for (var i = 0; i < 2; i++) {
        await commands.build(project);
        await commands.publish(project,
            target: targetFor('prod'),
            channel: 'prod',
            appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'));
      }
      await commands.rollout(project,
          target: targetFor('prod'), channel: 'prod', number: 1, fraction: 0.4);

      await commands.revoke(project,
          target: targetFor('prod'),
          channel: 'prod',
          numbers: {2},
          previewFor: Version.parse('1.4.0'));

      expect(console.text, contains('40% rollout'));
      expect(console.text, contains('marineford rollout 1 --percent 100'));
    });

    test('a revoked number is not reused', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);
      await commands.build(project);
      await commands.publish(project,
          target: targetFor('prod'),
          channel: 'prod',
          appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'));
      await commands.revoke(project,
          target: targetFor('prod'), channel: 'prod', numbers: {1});
      await commands.publish(project,
          target: targetFor('prod'),
          channel: 'prod',
          appVersions: VersionConstraint.parse('>=1.0.0 <=1.9.9'));

      final manifest = SignedManifest.parse(
              File(p.join(root.path, 'dist', 'prod', 'manifest.json'))
                  .readAsBytesSync())
          .open();
      expect(manifest.patches.map((e) => e.number), contains(2));
      expect(manifest.revoked, {1});
    });
  });

  group('doctor', () {
    test('passes on a complete project', () async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);

      expect(await commands.doctor(project), isTrue);
      expect(console.text, contains('Ready to publish'));
    });

    test('fails and explains when the app was never generated', () async {
      final project = await initProject();
      writePatchPackage(_goodPatch);

      expect(await commands.doctor(project), isFalse);
      expect(console.text, contains('build_runner'));
    });

    test('fails when nothing is marked patchable', () async {
      final project = await initProject();
      writeIdRegistry(ids: const <String>[]);
      writePatchPackage(_goodPatch);

      expect(await commands.doctor(project), isFalse);
      expect(console.text, contains('Nothing can be patched'));
    });

    test('fails when there is no patch package', () async {
      final project = await initProject();
      writeIdRegistry();

      expect(await commands.doctor(project), isFalse);
      expect(console.text, contains('no patch package'));
    });
  });

  group('project config', () {
    test('is found by walking up from a subdirectory', () async {
      await commands.init(root, appId: 'com.example.app');
      final nested = Directory(p.join(root.path, 'a', 'b'))
        ..createSync(recursive: true);
      expect(MarinefordProject.load(nested).appId, 'com.example.app');
    });

    test('a missing config explains what to run', () {
      final empty = Directory.systemTemp.createTempSync('marineford_empty');
      addTearDown(() => empty.deleteSync(recursive: true));
      // Walks to the filesystem root, so this only holds if no ancestor of the
      // temp directory happens to be a marineford project.
      try {
        MarinefordProject.load(empty);
        fail('expected a CliException');
      } on CliException catch (e) {
        expect(e.hint, contains('marineford init'));
      }
    });

    test('a malformed config is rejected with the file path', () async {
      File(p.join(root.path, 'marineford.yaml'))
          .writeAsStringSync('app_id: 42');
      expect(
        () => MarinefordProject.load(root),
        throwsA(isA<CliException>()
            .having((e) => e.message, 'message', contains('app_id'))),
      );
    });
  });

  group('an unreadable signing key', () {
    // The signing key is the whole security model, so the one path where the
    // answer is never "try again" should not arrive as a bare FormatException
    // and a stack trace. A CI secret that picked up a newline, or the public
    // key pasted where the seed belonged, both land here.
    Future<void> expectRefusal(String contents, Matcher message) async {
      final project = await initProject();
      writeIdRegistry();
      writePatchPackage(_goodPatch);
      await commands.build(project);
      project.privateKeyFile.writeAsStringSync(contents);

      await expectLater(
        commands.publish(
          project,
          target: targetFor('prod'),
          channel: 'prod',
          appVersions: VersionConstraint.parse('>=1.0.0 <2.0.0'),
        ),
        throwsA(isA<CliException>()
            .having((e) => e.message, 'message', message)
            .having((e) => e.hint, 'hint', contains('base64 seed'))),
      );
    }

    test('is refused with the path when it is not base64', () async {
      await expectRefusal('not base64 at all!!', contains('not base64'));
    });

    test('is refused when it is base64 of the wrong length', () async {
      // Valid base64, useless as a seed — what pasting the public key looks
      // like, since that is base64 too.
      await expectRefusal(
          base64Encode(List<int>.filled(7, 1)), contains('Ed25519 seed'));
    });
  });
}
