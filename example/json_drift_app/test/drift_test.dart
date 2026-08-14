import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_drift_app/api_client.dart';
import 'package:json_drift_app/collect_day_screen.dart';
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
        appVersions: VersionConstraint.parse('>=1.4.0 <=1.4.99'),
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
          // What lets a patch build widgets. Without it the widget override
          // compiles and loads, then fails on the first `Column` it cannot
          // resolve and falls back to the shipped card — safely, silently, and
          // uselessly. An app that only patches logic leaves this out and
          // never links flutter_eval at all.
          plugins: const [flutterEvalPlugin],
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
      expect(kMarinefordPatchIds, isNot(contains(contains('parseCollectDay'))));
    });

    group('and the screen it draws', () {
      // The same patch, the same activation — one `.mfp` carrying both
      // overrides, because they are one release. The pairing is the realistic
      // one: the backend changed, and the card that renders the result was
      // always slightly wrong about what to do when there is no result.
      Future<void> pumpCard(WidgetTester tester, String day) =>
          tester.pumpWidget(MaterialApp(home: CollectDayScreen(day: day)));

      testWidgets('a known day still renders the same', (tester) async {
        await pumpCard(tester, 'Salı');
        expect(find.text('Toplama günü'), findsOneWidget);
        expect(find.text('Salı'), findsOneWidget);
      });

      testWidgets('a missing day no longer looks like an answer',
          (tester) async {
        await pumpCard(tester, 'Belirlenmemiş');

        // What shipped: the placeholder set at 28pt, indistinguishable from a
        // real day. What the patch does: say plainly that it could not be
        // read, at a size that does not claim to be an answer.
        expect(find.text('Belirlenmemiş'), findsNothing);
        expect(find.text('Toplama günü alınamadı'), findsOneWidget);
        expect(find.text('Daha sonra tekrar deneyin'), findsOneWidget);

        final style = tester
            .widget<Text>(
              find.text('Daha sonra tekrar deneyin'),
            )
            .style;
        expect(style?.fontSize, 16.0,
            reason: 'the placeholder must not keep the answer size');
      });
    });
  });

  group('before any patch the card is the broken one', () {
    testWidgets('the placeholder is rendered as if it were a day',
        (tester) async {
      // Deliberately asserting the bug. It is what users of 1.4.0 see, and the
      // patch group above is only meaningful against it.
      await tester.pumpWidget(
        const MaterialApp(home: CollectDayScreen(day: 'Belirlenmemiş')),
      );
      expect(find.text('Belirlenmemiş'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Belirlenmemiş')).style?.fontSize,
        28.0,
      );
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
