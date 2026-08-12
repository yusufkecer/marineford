import 'package:flutter_test/flutter_test.dart';
import 'package:json_drift_app/marineford.g.dart';

void main() {
  test('the generator still recognises the annotations', () {
    // This is the only place the real generator meets the real annotations, and
    // it is the only thing standing between a rename and total silence.
    //
    // The generator matches `@patchable` by library URL — the string
    // `package:marineford/src/annotations.dart` — rather than by type, because
    // it cannot depend on the runtime: that is a Flutter package and a
    // build_runner generator runs under the plain Dart VM. Move or rename that
    // file and nothing is recognised, no shim is emitted, and no error is
    // raised. The generator's own tests cannot catch it either: they declare
    // the annotations in a stub at that same path, so they keep passing.
    //
    // An empty registry here means the marking stopped working.
    expect(kMarinefordPatchIds, isNotEmpty);
  });
}
