## 0.1.0-dev

- `@patchable` ve `@PatchableService` icin dispatch shim uretimi.
- Kutulama kuralinin otomatik uygulanmasi (ham vs `MarinefordJson.wrap`).
- Desteklenmeyen tipler icin acik build hatasi.
- ABI fingerprint ve `marineford_ids.json` kayit defteri.

## Unreleased

- No longer depends on `marineford_annotation`, or on any marineford package.
  The annotations are matched by library URL rather than by type, because they
  now live in `marineford`, which is a Flutter package a build_runner generator
  cannot depend on. The example app's `marking_test.dart` guards the URL.
