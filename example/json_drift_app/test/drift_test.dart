import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:json_drift_app/api_client.dart';
import 'package:json_drift_app/marineford.g.dart';
import 'package:marineford/marineford.dart';
import 'package:marineford_cli/marineford_cli.dart';
import 'package:marineford_core/marineford_core.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// Every shape the backend has taken, and what the shipped build makes of it.
///
/// This is the whole reason the library exists, so it is worth stating as data:
/// one column is what users get today, the other is what they get after a patch
/// that never went near an app store.
const _responses = <String, String>{
  'unchanged': '{"status":"ok","day":"Salı"}',
  'status renamed': '{"status":"success","day":"Çarşamba"}',
  'status became a number': '{"status":200,"day":"Perşembe"}',
  'field renamed': '{"status":"ok","collect_day":"Cuma"}',
  'wrapped in data': '{"status":"success","data":{"collect_day":"Cumartesi"}}',
  'became a list': '{"status":"ok","data":{"days":["Pazartesi","Perşembe"]}}',
  'value became an int': '{"status":"ok","data":{"collect_day":3}}',
  'error response': '{"status":"error","message":"yok"}',
};

const _expectedBeforePatch = <String, String>{
  'unchanged': 'Salı',
  'status renamed': 'Belirlenmemiş',
  'status became a number': 'Belirlenmemiş',
  'field renamed': 'Belirlenmemiş',
  'wrapped in data': 'Belirlenmemiş',
  'became a list': 'Belirlenmemiş',
  'value became an int': 'Belirlenmemiş',
  'error response': 'Belirlenmemiş',
};

const _expectedAfterPatch = <String, String>{
  'unchanged': 'Salı',
  'status renamed': 'Çarşamba',
  'status became a number': 'Perşembe',
  'field renamed': 'Cuma',
  'wrapped in data': 'Cumartesi',
  'became a list': 'Pazartesi, Perşembe',
  'value became an int': '3',
  'error response': 'Belirlenmemiş',
};

Future<String> collectDayFor(String key) async {
  final client = ApiClient(<String, Map<String, dynamic>>{
    'getCollectDay': jsonDecode(_responses[key]!) as Map<String, dynamic>,
  });
  return parseCollectDay(await client.get('getCollectDay'));
}

/// This package's own directory, wherever the test was launched from.
///
/// `flutter test example/json_drift_app` from the workspace root leaves the
/// working directory at the root, so anything that assumes otherwise breaks
/// depending on how you invoke it.
Directory _projectRoot() {
  for (final candidate in <String>[
    Directory.current.path,
    p.join(Directory.current.path, 'example', 'json_drift_app'),
  ]) {
    if (File(p.join(candidate, 'marineford.yaml')).existsSync()) {
      return Directory(candidate);
    }
  }
  throw StateError('cannot find the example project from '
      '${Directory.current.path}');
}

void main() {
  final projectRoot = _projectRoot();

  tearDown(Patch.resetForTesting);

  group('before any patch', () {
    for (final key in _responses.keys) {
      test(key, () async {
        expect(await collectDayFor(key), _expectedBeforePatch[key]);
      });
    }
  });

  group('after the chokepoint patch', () {
    late Directory dist;

    setUpAll(() async {
      // Build and publish the patch exactly the way a developer would, then
      // let the real client fetch it. Nothing is stubbed except the network.
      final project = MarinefordProject.load(projectRoot);
      await _ensureThrowawayKey(project);
      final commands = MarinefordCommands(console: RecordingConsole());
      await commands.build(project);
      dist = Directory(p.join(projectRoot.path, 'dist', 'prod'));
      await commands.publish(
        project,
        target: DirectoryTarget(dist),
        channel: 'prod',
        appVersionMin: Version.parse('1.4.0'),
        appVersionMax: Version.parse('1.4.99'),
      );
    });

    tearDownAll(() {
      try {
        if (dist.parent.existsSync()) dist.parent.deleteSync(recursive: true);
        final out = Directory(p.join(projectRoot.path, 'out'));
        if (out.existsSync()) out.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    late Directory storage;
    late MarinefordClient client;

    setUp(() async {
      storage = Directory.systemTemp.createTempSync('marineford_example');
      client = MarinefordClient(
        config: MarinefordConfig(
          appId: 'com.example.jsondrift',
          appVersion: Version.parse('1.4.0'),
          abi: kMarinefordAbi,
          manifestUrl: Uri.parse('file:///prod/manifest.json'),
          publicKey:
              File(p.join(projectRoot.path, '.marineford', 'signing.pub'))
                  .readAsStringSync(),
          activation: PatchActivation.immediate,
          autoConfirmBootAfter: null,
        ),
        store: PatchStore(storage),
        transport: _FileTransport(dist),
      );
      await client.start();
      final decision = await client.checkForUpdate();
      expect(decision, isA<ApplyPatch>(),
          reason: 'the example patch should have been selected');
    });

    tearDown(() {
      client.dispose();
      try {
        if (storage.existsSync()) storage.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    for (final key in _responses.keys) {
      test(key, () async {
        expect(await collectDayFor(key), _expectedAfterPatch[key]);
      });
    }

    test('parseCollectDay itself was never patched', () {
      // The function with the bug is not in the id registry and never could
      // be. Fixing the chokepoint above it was enough.
      expect(kMarinefordPatchIds, hasLength(1));
      expect(kMarinefordPatchIds.single, endsWith('#normalizeResponse'));
    });
  });
}

/// Generates a signing key for the example if there is not one already.
///
/// The example deliberately does not ship a key. A private key committed to a
/// public repository is a private key anyone can use to run code in any app
/// that trusts it, and an example that models the habit is worse than no
/// example. This makes a throwaway one on first run instead; it is gitignored
/// along with every other `.marineford/signing.key`.
Future<void> _ensureThrowawayKey(MarinefordProject project) async {
  if (project.privateKeyFile.existsSync()) return;
  final signer = await PatchSigner.generate();
  await project.privateKeyFile.parent.create(recursive: true);
  await project.privateKeyFile
      .writeAsString(base64Encode(await signer.extractSeed()));
  await project.publicKeyFile.writeAsString(signer.publicKeyBase64);
}

/// Serves the published channel directory over `file:` URIs.
final class _FileTransport implements PatchTransport {
  _FileTransport(this.root);

  final Directory root;

  @override
  Future<TransportResponse> get(Uri url, {String? ifNoneMatch}) async {
    final file = File(p.join(root.path, p.basename(url.path)));
    if (!file.existsSync()) {
      return TransportResponse(statusCode: 404, body: Uint8List(0));
    }
    return TransportResponse(statusCode: 200, body: await file.readAsBytes());
  }

  @override
  void close() {}
}
