import 'package:marineford_annotation/marineford_annotation.dart';
import 'package:test/test.dart';

void main() {
  test('patchable is a const Patchable with no id', () {
    expect(patchable, isA<Patchable>());
    expect(patchable.id, isNull);
  });

  test('RuntimeOverride keeps id and version verbatim', () {
    const o = RuntimeOverride('pkg:app/a.dart#f', version: '>=1.0.0 <2.0.0');
    expect(o.id, 'pkg:app/a.dart#f');
    expect(o.version, '>=1.0.0 <2.0.0');
  });

  test('PatchableService defaults to excluding nothing', () {
    const s = PatchableService();
    expect(s.exclude, isEmpty);
    expect(s.name, isNull);
  });
}
