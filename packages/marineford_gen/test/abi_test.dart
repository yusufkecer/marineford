import 'package:marineford_gen/builder.dart';
import 'package:test/test.dart';

void main() {
  AbiBuilder builderWith(List<(String, List<String>, String)> entries) {
    final abi = AbiBuilder();
    for (final (id, params, returns) in entries) {
      abi.add(id: id, parameterTypes: params, returnType: returns);
    }
    return abi;
  }

  group('stability', () {
    test('the same surface always hashes the same', () {
      final a = builderWith([
        ('pkg:app/lib/a.dart#one', ['int'], 'int'),
        ('pkg:app/lib/b.dart#two', ['String'], 'bool'),
      ]);
      final b = builderWith([
        ('pkg:app/lib/a.dart#one', ['int'], 'int'),
        ('pkg:app/lib/b.dart#two', ['String'], 'bool'),
      ]);
      expect(a.build(), b.build());
    });

    test('order does not matter', () {
      // Build order is not stable across machines or incremental builds. If it
      // leaked into the fingerprint, every developer would invalidate every
      // patch at random.
      final forwards = builderWith([
        ('pkg:app/lib/a.dart#one', ['int'], 'int'),
        ('pkg:app/lib/b.dart#two', ['String'], 'bool'),
      ]);
      final backwards = builderWith([
        ('pkg:app/lib/b.dart#two', ['String'], 'bool'),
        ('pkg:app/lib/a.dart#one', ['int'], 'int'),
      ]);
      expect(forwards.build(), backwards.build());
    });

    test('the shape is sha256:<64 hex>', () {
      expect(builderWith([('a', [], 'void')]).build(),
          matches(RegExp(r'^sha256:[0-9a-f]{64}$')));
    });

    test('an empty surface still produces a fingerprint', () {
      expect(AbiBuilder().build(), matches(RegExp(r'^sha256:[0-9a-f]{64}$')));
    });
  });

  group('what changes the fingerprint', () {
    final baseline = builderWith([
      ('pkg:app/lib/a.dart#one', ['int', 'String'], 'bool'),
    ]).build();

    void changes(String label, List<(String, List<String>, String)> entries) {
      test(label, () {
        expect(builderWith(entries).build(), isNot(baseline));
      });
    }

    changes('renaming the function', [
      ('pkg:app/lib/a.dart#renamed', ['int', 'String'], 'bool')
    ]);
    changes('moving it to another file', [
      ('pkg:app/lib/moved.dart#one', ['int', 'String'], 'bool')
    ]);
    changes('changing a parameter type', [
      ('pkg:app/lib/a.dart#one', ['int', 'int'], 'bool')
    ]);
    changes('making a parameter nullable', [
      ('pkg:app/lib/a.dart#one', ['int?', 'String'], 'bool')
    ]);
    changes('reordering parameters', [
      ('pkg:app/lib/a.dart#one', ['String', 'int'], 'bool')
    ]);
    changes('dropping a parameter', [
      ('pkg:app/lib/a.dart#one', ['int'], 'bool')
    ]);
    changes('adding a parameter', [
      ('pkg:app/lib/a.dart#one', ['int', 'String', 'bool'], 'bool')
    ]);
    changes('changing the return type', [
      ('pkg:app/lib/a.dart#one', ['int', 'String'], 'int')
    ]);
    changes('adding a whole new patchable function', [
      ('pkg:app/lib/a.dart#one', ['int', 'String'], 'bool'),
      ('pkg:app/lib/a.dart#two', ['int'], 'int'),
    ]);
    changes('removing the only patchable function', []);

    test('making a parameter nullable is caught even though semver would not',
        () {
      // The case the fingerprint exists for: a signature that changes without
      // anyone thinking to bump a major version.
      final before = builderWith([
        ('id', ['int'], 'int')
      ]).build();
      final after = builderWith([
        ('id', ['int?'], 'int')
      ]).build();
      expect(after, isNot(before));
    });
  });

  test('the canonical form is readable, for debugging a mismatch', () {
    final abi = builderWith([
      ('pkg:app/lib/b.dart#two', ['String'], 'bool'),
      ('pkg:app/lib/a.dart#one', ['int'], 'int'),
    ]);
    expect(abi.canonicalForm,
        'pkg:app/lib/a.dart#one(int)->int\npkg:app/lib/b.dart#two(String)->bool');
    expect(abi.length, 2);
  });
}
