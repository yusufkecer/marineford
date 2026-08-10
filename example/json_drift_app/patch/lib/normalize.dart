// This file is compiled by dart_eval, not by Dart, so it declares the
// annotation it needs rather than importing it. dart_eval matches
// @RuntimeOverride by name.
class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

bool _accepted(Object? status) {
  return status == 'ok' || status == 'success' || status == 200;
}

Map _unwrap(Map response) {
  final data = response['data'];
  if (data is Map) {
    return data;
  }
  return response;
}

/// Rewrites whatever the backend is sending today into the shape the shipped
/// build expects: `{"status": "ok", "day": "<name>"}`.
///
/// The app's own parser is not patchable and has not changed. It does not need
/// to: it never sees the drift.
@RuntimeOverride(
  'pkg:json_drift_app/lib/api_client.dart#normalizeResponse',
  version: '>=1.4.0 <1.5.0',
)
Map normalize(String endpoint, Map raw) {
  final out = <String, Object?>{};
  out['status'] = _accepted(raw['status']) ? 'ok' : 'error';

  final node = _unwrap(raw);

  final renamed = node['collect_day'];
  if (renamed != null) {
    out['day'] = renamed.toString();
  }

  final original = node['day'];
  if (original != null) {
    out['day'] = original.toString();
  }

  final list = node['days'];
  if (list is List) {
    if (list.isNotEmpty) {
      out['day'] = list.join(', ');
    }
  }

  return out;
}
