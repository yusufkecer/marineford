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
  HttpPatchTransport({http.Client? client, this.maxBodyBytes = 8 * 1024 * 1024})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// Hard ceiling on a response body.
  ///
  /// A patch is kilobytes; anything approaching this is either a broken server
  /// or someone trying to make the app allocate until it dies. The manifest's
  /// declared size is checked separately, but that check trusts the manifest —
  /// this one does not trust anything.
  final int maxBodyBytes;

  @override
  Future<TransportResponse> get(Uri url, {String? ifNoneMatch}) async {
    final request = http.Request('GET', url);
    if (ifNoneMatch != null) {
      request.headers['if-none-match'] = ifNoneMatch;
    }
    final streamed = await _client.send(request);

    final declared = streamed.contentLength;
    if (declared != null && declared > maxBodyBytes) {
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
      etag: streamed.headers['etag'],
    );
  }

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
