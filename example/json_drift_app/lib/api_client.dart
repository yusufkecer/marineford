import 'package:marineford/marineford.dart';
import 'package:marineford_annotation/marineford_annotation.dart';

part 'api_client.marineford.dart';

/// A stand-in for whatever HTTP client the app actually uses.
///
/// The interesting part is not this class — it is the one marked function below
/// it.
class ApiClient {
  ApiClient(this._responses);

  final Map<String, Map<String, dynamic>> _responses;

  Future<Map<String, dynamic>?> get(String endpoint) async =>
      normalizeResponse(endpoint, _responses[endpoint]);
}

/// The chokepoint.
///
/// This is the single most valuable place in an app to mark patchable, and in
/// this example it is the *only* marked function. It does nothing today — it
/// returns the response untouched — but because the branch is compiled into the
/// binary, a patch can later rewrite it into anything: renaming fields,
/// unwrapping an envelope the backend started adding, coercing a type that
/// changed, absorbing a status value nobody warned you about.
///
/// Everything downstream of it stays unmarked and unpatchable, and does not
/// need to be. See [parseCollectDay].
@patchable
Map<String, dynamic>? _normalizeResponse(
  String endpoint,
  Map<String, dynamic>? raw,
) =>
    raw;

/// Deliberately **not** patchable.
///
/// This is the function with the bug, and it can never be fixed directly — it
/// shipped without a marker. The example exists to show that it does not have
/// to be: fixing the chokepoint above is enough, because by the time this runs
/// the data already looks the way it expects.
String parseCollectDay(Map<String, dynamic>? response) {
  if (response != null && response['status'] == 'ok') {
    return response['day'] as String? ?? 'Belirlenmemiş';
  }
  return 'Belirlenmemiş';
}
