import 'package:build_test/build_test.dart';
import 'package:logging/logging.dart';
import 'package:marineford_gen/builder.dart';
import 'package:source_gen/source_gen.dart';
import 'package:test/test.dart';

/// Stand-ins for the packages a real app would depend on.
///
/// build_test resolves every import, so the generator has to run against real
/// element models — which is the point. A generator tested against a mocked
/// analyzer is a generator that has not been tested.
const _annotationStub = r'''
final class Patchable {
  const Patchable({this.id});
  final String? id;
}
const patchable = Patchable();

final class PatchableService {
  const PatchableService({this.name, this.exclude = const []});
  final String? name;
  final List<String> exclude;
}
''';

const _runtimeStub = r'''
final class Patch {
  static int get generation => 0;
  static int? slot(String id) => null;
  static Object? invoke0(int o, [String id = '']) => null;
  static Object? invoke1(int o, Object? a, [String id = '']) => null;
  static Object? invoke2(int o, Object? a, Object? b, [String id = '']) => null;
  static Object? invoke3(int o, Object? a, Object? b, Object? c,
          [String id = '']) =>
      null;
  static Object? invokeN(int o, List<Object?> a, [String id = '']) => null;
}
const Object patchedNull = Object();
abstract final class MarinefordJson {
  static Object? wrap(Object? v) => v;
  static Object? unwrap(Object? v) => v;
  static Map<String, dynamic>? unwrapMap(Object? v) => null;
  static List<dynamic>? unwrapList(Object? v) => null;
}
''';

final _errors = <Object>[];

Future<String> generate(String source) async {
  _errors.clear();
  String? captured;
  await testBuilder(
    PartBuilder(<Generator>[ShimGenerator()], '.marineford.dart'),
    <String, String>{
      'marineford_annotation|lib/marineford_annotation.dart': _annotationStub,
      'marineford|lib/marineford.dart': _runtimeStub,
      'app|lib/pricing.dart': source,
    },
    // Without this the builder also runs over the stub packages, and resolving
    // them inside the harness trips build_runner's own library-cycle guard.
    generateFor: <String>{'app|lib/pricing.dart'},
    rootPackage: 'app',
    outputs: <String, Object>{
      'app|lib/pricing.marineford.dart':
          decodedMatches(predicate((Object? value) {
        captured = '$value';
        return true;
      })),
    },
    onLog: (record) {
      final error = record.error;
      if (error != null) _errors.add(error);
      if (record.level >= Level.SEVERE) _errors.add(record.message);
    },
  );
  final output = captured;
  if (output == null) {
    throw StateError('no shim was generated. Build log:\n'
        '${_errors.join('\n')}');
  }
  return output;
}

/// Runs the generator expecting it to refuse, and returns what it said.
///
/// build_runner reports a generator failure through the log rather than by
/// throwing, so a test that only wrapped [generate] in a try/catch would pass
/// on a generator that silently produced nothing.
Future<String> generateError(String source) async {
  try {
    await generate(source);
  } on Object {
    // The missing-output path; the reason is in _errors.
  }
  return _errors.join('\n');
}

const _imports = '''
import 'package:marineford/marineford.dart';
import 'package:marineford_annotation/marineford_annotation.dart';
part 'pricing.marineford.dart';
''';

void main() {
  group('@patchable functions', () {
    test('generates a public wrapper around the private implementation',
        () async {
      final output = await generate('''
$_imports
@patchable
int _double(int value) => value * 2;
''');
      expect(output, contains('int double(int value) {'));
      expect(
          output, contains("Patch.slot(r'pkg:app/lib/pricing.dart#double')"));
      expect(output, contains('Patch.invoke1(_s, value,'),
          reason: 'a non-nullable int is passed raw');
      expect(output, contains('return _double(value);'),
          reason: 'the fallback must call the original');
    });

    test('wraps everything that is not a non-nullable primitive', () async {
      final output = await generate('''
$_imports
@patchable
String _label(String name, int count, double ratio, bool flag, int? maybe) =>
    name;
''');
      expect(output, contains('MarinefordJson.wrap(name)'));
      expect(output, contains('MarinefordJson.wrap(maybe)'),
          reason: 'a nullable int flips to the wrapped form');
      expect(output, isNot(contains('MarinefordJson.wrap(count)')));
      expect(output, isNot(contains('MarinefordJson.wrap(ratio)')));
      expect(output, isNot(contains('MarinefordJson.wrap(flag)')));
    });

    test('picks the arity-specialised invoke', () async {
      final zero = await generate('$_imports\n@patchable\nint _a() => 1;');
      expect(zero, contains('Patch.invoke0('));

      final four = await generate(
          '$_imports\n@patchable\nint _a(int a, int b, int c, int d) => 1;');
      expect(four, contains('Patch.invokeN('),
          reason: 'past three arguments the list allocation is unavoidable');
    });

    test('deep-unwraps collection returns', () async {
      final output = await generate('''
$_imports
@patchable
Map<String, dynamic> _normalize(Map<String, dynamic> raw) => raw;
''');
      expect(output, contains('MarinefordJson.unwrapMap(_r)'));
    });

    test('handles a nullable return without confusing it with no patch',
        () async {
      final output = await generate('''
$_imports
@patchable
String? _maybe(int v) => null;
''');
      expect(output, contains('identical(_r, patchedNull)'),
          reason: 'a patch returning null must be distinguishable');
    });

    test('honours an explicit id', () async {
      final output = await generate('''
$_imports
@Patchable(id: 'stable.id')
int _f(int v) => v;
''');
      expect(output, contains("r'stable.id'"));
    });

    test('a public @patchable function is a build error', () async {
      final error = await generateError('''
$_imports
@patchable
int visible(int v) => v;
''');
      expect(error, contains('must be private'));
    });
  });

  group('unsupported types produce a build error, not a broken shim', () {
    Future<void> rejects(String signature, String expected) async {
      final error = await generateError('''
$_imports
class Cart { const Cart(); }
@patchable
$signature
''');
      expect(error, contains(expected),
          reason: 'expected a build error for: $signature');
    }

    test('a domain object parameter', () async {
      await rejects('int _total(Cart cart) => 0;', 'needs a dart_eval binding');
    });

    test('a domain object return', () async {
      await rejects(
          'Cart _build(int v) => const Cart();', 'needs a dart_eval binding');
    });

    test('a Future return', () async {
      await rejects(
          'Future<int> _load(int v) async => v;', 'cannot cross the patch');
    });

    test('a callback parameter', () async {
      await rejects(
          'int _run(int Function() f) => f();', 'cannot cross the patch');
    });

    test('named parameters', () async {
      await rejects(
          'int _f(int a, {int b = 0}) => a;', 'named parameters are not');
    });
  });

  group('@PatchableService classes', () {
    test('generates a subclass that overrides every public method', () async {
      final output = await generate('''
$_imports
@PatchableService()
class PricingRulesBase {
  int total(int a, int b) => a + b;
  String label(String name) => name;
  int _hidden() => 0;
  static int alsoHidden() => 0;
}
''');
      expect(output, contains('class PricingRules extends PricingRulesBase {'));
      expect(output, contains('int total(int a, int b) {'));
      expect(output, contains('String label(String name) {'));
      expect(output, contains('return super.total(a, b);'));
      expect(output, isNot(contains('_hidden')));
      expect(output, isNot(contains('alsoHidden')));
    });

    test('caches slots behind a generation counter', () async {
      final output = await generate('''
$_imports
@PatchableService()
class ServiceBase {
  int a(int v) => v;
  int b(int v) => v;
}
''');
      expect(output, contains('if (_generation == Patch.generation) return;'));
      expect(output, contains('int? _s0;'));
      expect(output, contains('int? _s1;'));
      expect(output, contains('_sync();'));
    });

    test('exclude keeps a method off the boundary', () async {
      final output = await generate('''
$_imports
@PatchableService(exclude: ['hot'])
class ServiceBase {
  int hot(int v) => v;
  int cold(int v) => v;
}
''');
      expect(output, contains('int cold(int v) {'));
      expect(output, isNot(contains('int hot(int v) {')));
    });

    test('an explicit name is honoured', () async {
      final output = await generate('''
$_imports
@PatchableService(name: 'Pricing')
class Rules {
  int total(int v) => v;
}
''');
      expect(output, contains('class Pricing extends Rules {'));
    });

    test('a class with no public methods is a build error', () async {
      final error = await generateError('''
$_imports
@PatchableService()
class EmptyBase {
  int _private() => 0;
}
''');
      expect(error, contains('no public instance methods'));
    });

    test('ids are scoped by class so two services cannot collide', () async {
      final output = await generate('''
$_imports
@PatchableService()
class OneBase { int run(int v) => v; }
@PatchableService()
class TwoBase { int run(int v) => v; }
''');
      expect(output, contains('pkg:app/lib/pricing.dart#One.run'));
      expect(output, contains('pkg:app/lib/pricing.dart#Two.run'));
    });
  });

  group('generated code is valid Dart', () {
    test('a realistic file analyses cleanly', () async {
      final output = await generate('''
$_imports
@patchable
Map<String, dynamic>? _normalize(String endpoint, Map<String, dynamic>? raw) =>
    raw;

@patchable
int _score(int base, double weight, bool boosted) => base;

@PatchableService()
class RulesBase {
  int total(int a, int b) => a + b;
  List<String> names(Map<String, dynamic> input) => const <String>[];
  void audit(String message) {}
}
''');
      // Balanced braces is a cheap proxy for "the template did not tear".
      expect('{'.allMatches(output).length, '}'.allMatches(output).length);
      expect(output, contains('void audit(String message) {'));
      expect(output, contains('MarinefordJson.unwrapList(_r)'));
    });
  });
}
