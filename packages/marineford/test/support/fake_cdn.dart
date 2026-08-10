import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:marineford/marineford.dart';
import 'package:marineford_core/marineford_core.dart';

/// A signing key plus the CDN that serves what it signs.
///
/// Client tests go through real bytes: a real dart_eval program, really
/// gzipped, framed into a real container, really signed. Faking any of that
/// would leave the verification order — the part most worth testing — untested.
final class FakeCdn implements PatchTransport {
  FakeCdn._(this.signer, this.abi);

  /// Creates a CDN with a fresh signing key.
  static Future<FakeCdn> create({String? abi}) async =>
      FakeCdn._(await PatchSigner.generate(), abi ?? 'sha256:${'a' * 64}');

  /// The publisher's key.
  final PatchSigner signer;

  /// ABI fingerprint stamped into everything this CDN publishes.
  final String abi;

  /// Base64 public key, as it would be pasted into an app.
  String get publicKey => signer.publicKeyBase64;

  /// Where the manifest lives.
  final Uri manifestUrl = Uri.parse('https://cdn.test/prod/manifest.json');

  final Map<String, Uint8List> _files = <String, Uint8List>{};

  /// Every path fetched so far, in order. Lets tests assert on caching.
  final List<String> requests = <String>[];

  /// ETag the manifest is served with, or null for none.
  String? etag;

  /// Status code to return for the next manifest fetch, or null for normal.
  int? manifestStatusOverride;

  int _closeCount = 0;

  /// How many times the client closed this transport.
  int get closeCount => _closeCount;

  /// Compiles [source] into a signed container and returns its bytes.
  ///
  /// [source] is patch-package Dart: top-level functions annotated with
  /// `@RuntimeOverride`.
  Future<Uint8List> buildPatch(
    String source, {
    String? abiOverride,
    MfpFlags flags = MfpFlags.gzip,
    int schema = 1,
  }) async {
    const header = '''
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}
''';
    final program = Compiler().compile({
      'patch': {'main.dart': '$header\n$source'},
    });
    final evc = program.write();
    final payload =
        flags.has(MfpFlags.gzip) ? Uint8List.fromList(gzip.encode(evc)) : evc;

    final region = MfpContainer.buildSignedRegion(
      payload: payload,
      abiHash: _abiBytes(abiOverride ?? abi),
      flags: flags,
      schema: schema,
    );
    final signature = await signer.sign(region);
    return Uint8List.fromList([...region, ...signature]);
  }

  /// Publishes [patches] and the manifest that describes them.
  ///
  /// Each entry maps a patch number to its container bytes.
  Future<void> publish(
    Map<int, Uint8List> patches, {
    Set<int> revoked = const <int>{},
    String appId = 'com.example.app',
    String runtime = '>=1.0.0 <2.0.0',
    double rollout = 1.0,
    Map<int, String> abiPerPatch = const <int, String>{},
  }) async {
    final entries = <Map<String, Object?>>[];
    patches.forEach((number, bytes) {
      _files['/prod/$number.mfp'] = bytes;
      entries.add(<String, Object?>{
        'number': number,
        'url': '$number.mfp',
        'size': bytes.length,
        'sha256': sha256Hex(bytes),
        'abi': abiPerPatch[number] ?? abi,
        'runtime': runtime,
        'rollout': rollout,
      });
    });

    final manifest = utf8.encode(jsonEncode(<String, Object?>{
      'schema': 1,
      'app': appId,
      'channel': 'prod',
      'generatedAt': '2026-08-10T12:00:00Z',
      'patches': entries,
      'revoked': revoked.toList(),
    }));
    _files['/prod/manifest.json'] = Uint8List.fromList(manifest);
    _files['/prod/manifest.json.sig'] = await signer.sign(
      Uint8List.fromList(manifest),
    );
  }

  /// Replaces a served file with arbitrary bytes, simulating tampering or a
  /// broken server.
  void corrupt(String path, Uint8List bytes) => _files[path] = bytes;

  /// Removes a served file, simulating a 404.
  void remove(String path) => _files.remove(path);

  @override
  Future<TransportResponse> get(Uri url, {String? ifNoneMatch}) async {
    requests.add(url.path);

    if (url.path.endsWith('manifest.json')) {
      final override = manifestStatusOverride;
      if (override != null) {
        manifestStatusOverride = null;
        return TransportResponse(statusCode: override, body: Uint8List(0));
      }
      if (etag != null && ifNoneMatch == etag) {
        return TransportResponse(statusCode: 304, body: Uint8List(0));
      }
    }

    final body = _files[url.path];
    if (body == null) {
      return TransportResponse(statusCode: 404, body: Uint8List(0));
    }
    return TransportResponse(
      statusCode: 200,
      body: body,
      etag: url.path.endsWith('manifest.json') ? etag : null,
    );
  }

  @override
  void close() => _closeCount++;

  static Uint8List _abiBytes(String abi) {
    final hex = abi.substring('sha256:'.length);
    return Uint8List.fromList(<int>[
      for (var i = 0; i < 32; i++)
        int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ]);
  }
}
