import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// What a fetch returned.
@immutable
final class TransportResponse {
  /// Creates a [TransportResponse].
  const TransportResponse({
    required this.statusCode,
    required this.body,
    this.etag,
  });

  /// HTTP status.
  final int statusCode;

  /// Response body. Empty for 304.
  final Uint8List body;

  /// `ETag` header, if the server sent one.
  final String? etag;

  /// Whether the server said the cached copy is still good.
  bool get notModified => statusCode == 304;

  /// Whether the fetch succeeded with a body.
  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// How the client reaches the CDN.
///
/// Behind an interface so tests can serve bytes without a socket, and so an app
/// with its own HTTP stack — custom certificates, a proxy, an offline bundle —
/// can supply one instead of getting a second client it did not ask for.
abstract interface class PatchTransport {
  /// Fetches [url], optionally conditional on [ifNoneMatch].
  Future<TransportResponse> get(Uri url, {String? ifNoneMatch});

  /// Releases any underlying resources.
  void close();
}

/// The default [PatchTransport], built on `package:http`.
final class HttpPatchTransport implements PatchTransport {
  /// Creates a transport, optionally wrapping an existing [http.Client].
  HttpPatchTransport({
    http.Client? client,
    this.maxBodyBytes = 8 * 1024 * 1024,
    this.timeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// Ceiling on a single fetch, headers and body together.
  ///
  /// `package:http` has no default, and a server that accepts a connection and
  /// then says nothing is not a hypothetical — it is what a captive portal, a
  /// half-open NAT entry or an overloaded CDN edge looks like. Without this the
  /// fetch never completes, so the future the client deduplicates on never
  /// completes either, and every later `checkForUpdate` in the session returns
  /// that same hung future. One stalled connection was enough to stop a device
  /// ever hearing about a revocation.
  ///
  /// What this does *not* do is cancel the request. `Future.timeout` abandons
  /// the wait; the socket underneath stays open until the response arrives or
  /// [close] is called. So this unwedges the client and bounds the wait, but a
  /// host that black-holes every request still costs one held connection per
  /// check — which is why [close] exists and why `MarinefordClient.dispose`
  /// calls it. Do not read the drain in `get` as covering this too: that one
  /// releases a socket we have a response for, and this one has none.
  final Duration timeout;

  /// Hard ceiling on a response body.
  ///
  /// A patch is kilobytes; anything approaching this is either a broken server
  /// or someone trying to make the app allocate until it dies. The manifest's
  /// declared size is checked separately, but that check trusts the manifest —
  /// this one does not trust anything.
  final int maxBodyBytes;

  @override
  Future<TransportResponse> get(Uri url, {String? ifNoneMatch}) =>
      _get(url, ifNoneMatch: ifNoneMatch).timeout(
        timeout,
        onTimeout: () => throw PatchTransportException(
            'no response from $url within ${timeout.inSeconds}s'),
      );

  Future<TransportResponse> _get(Uri url, {String? ifNoneMatch}) async {
    final request = http.Request('GET', url);
    if (ifNoneMatch != null) {
      request.headers['if-none-match'] = ifNoneMatch;
    }
    final streamed = await _client.send(request);

    final declared = streamed.contentLength;
    if (declared != null && declared > maxBodyBytes) {
      // Drained rather than abandoned. Throwing without touching the stream
      // leaves the response body unsubscribed, and the socket under it is held
      // until the client is collected — so the defence against an oversized
      // body leaked a connection every time it worked.
      await streamed.stream.drain<void>();
      throw PatchTransportException(
          'response from $url declares $declared bytes, over the '
          '$maxBodyBytes byte limit');
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > maxBodyBytes) {
        throw PatchTransportException(
            'response from $url exceeded the $maxBodyBytes byte limit');
      }
    }

    return TransportResponse(
      statusCode: streamed.statusCode,
      body: builder.takeBytes(),
      etag: _safeEtag(streamed.headers['etag']),
    );
  }

  /// [value] if it looks like an ETag, or null.
  ///
  /// This string is server-controlled and ends up in `state.json`, which the
  /// client rewrites on every check — an unbounded header would be an
  /// unbounded file, chosen by whoever answers the request. RFC 7232 puts an
  /// ETag in quotes and allows only visible ASCII inside, so anything longer
  /// than [_maxEtagBytes] or containing anything else is not one.
  ///
  /// Dropped rather than rejected. A malformed ETag costs one full download
  /// per check, which is a server bug worth tolerating; failing the update
  /// would turn it into an outage.
  static String? _safeEtag(String? value) {
    if (value == null) return null;
    if (value.isEmpty || value.length > _maxEtagBytes) return null;
    return _etagShape.hasMatch(value) ? value : null;
  }

  static const int _maxEtagBytes = 256;

  /// Visible ASCII, which is what RFC 7232 allows in an entity tag.
  static final RegExp _etagShape = RegExp(r'^[\x21-\x7E]+$');

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Thrown when a fetch cannot be completed safely.
final class PatchTransportException implements Exception {
  /// Creates a [PatchTransportException].
  const PatchTransportException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'PatchTransportException: $message';
}
