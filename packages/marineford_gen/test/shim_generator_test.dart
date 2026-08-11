import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
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

/// Parses [source] as Dart, failing the test with the analyzer's own message.
///
/// The old check counted braces, which is why a generated `super.foo()` call
/// against an abstract method and a subclass with no usable constructor both
/// sailed through: both are perfectly balanced and neither compiles.
void expectValidDart(String source) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final errors =
      result.errors.where((e) => e.severity == Severity.error).toList();
  expect(errors, isEmpty,
      reason: 'generated code does not parse: ${errors.join('; ')}');
}

/// Collapses runs of whitespace, so an assertion about generated code does not
/// also assert about where the formatter chose to wrap it.
String collapse(String source) => source.replaceAll(RegExp(r'\s+'), ' ');

/// Turns a generated part file into something that stands alone well enough to
/// parse, by dropping the `part of` directive.
String asLibrary(String output, [String extra = '']) => 'library x;\n$extra\n'
    '${output.replaceFirst("part of 'pricing.dart';", '')}';

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
  _gaps();

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
      // Whitespace-insensitive: the formatter wraps long calls, and an
      // assertion that breaks on line width is testing the formatter.
      expect(collapse(output), contains('Patch.invoke1( _mfSlot, value,'),
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
      expect(output, contains('MarinefordJson.unwrapMap(_mfResult)'));
    });

    test('handles a nullable return without confusing it with no patch',
        () async {
      final output = await generate('''
$_imports
@patchable
String? _maybe(int v) => null;
''');
      expect(output, contains('identical(_mfResult, patchedNull)'),
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

    test('caches its slot behind the generation counter', () async {
      // Without the cache, a marked function that is not itself patched pays a
      // string hash and a map probe on every call for as long as any patch is
      // live anywhere in the app — which, for a code-push system, is the
      // steady state rather than the exception. Measured at 8.9ns against
      // 4.5ns in `bench/`.
      final output = await generate('''
$_imports
@patchable
int _price(int v) => v;

@patchable
int _tax(int v) => v;
''');

      expect(collapse(output), contains(collapse(r'''
  if (_mfGeneration$price != Patch.generation) {
    _mfGeneration$price = Patch.generation;
    _mfSlot$price = Patch.slot(r'pkg:app/lib/pricing.dart#price');
  }
''')));
      // One pair of statics per function, named after it, so two marked
      // functions in the same library cannot share a cache.
      expect(output, contains(r'int? _mfSlot$price;'));
      expect(output, contains(r'int _mfGeneration$price = -1;'));
      expect(output, contains(r'int? _mfSlot$tax;'));
      expect(output, contains(r'int _mfGeneration$tax = -1;'));
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
      expect(
          output, contains('if (_mfGeneration == Patch.generation) return;'));
      expect(output, contains('int? _mfSlot0;'));
      expect(output, contains('int? _mfSlot1;'));
      expect(output, contains('_mfSync();'));
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
      expectValidDart(asLibrary(output));
      expect(output, contains('void audit(String message) {'));
      expect(output, contains('MarinefordJson.unwrapList(_mfResult)'));
    });
  });
}

/// Gaps the review named.
void _gaps() {
  group('abstract methods', () {
    test('an abstract method is a build error, not uncompilable output',
        () async {
      // The shim falls back to `super`, and an abstract method has nothing
      // there. The old generator emitted the call anyway and the generated file
      // simply did not compile.
      final error = await generateError('''
$_imports
@PatchableService()
abstract class RulesBase {
  int total(int a);
  int other(int a) => a;
}
''');
      expect(error, contains('abstract'));
      expect(error, contains('super'));
    });

    test('excluding the abstract method makes it work', () async {
      final output = await generate('''
$_imports
@PatchableService(exclude: ['total'])
abstract class RulesBase {
  int total(int a);
  int other(int a) => a;
}
''');
      expect(output, contains('int other(int a) {'));
      expect(output, isNot(contains('super.total')));
    });
  });

  group('constructors', () {
    test('an unnamed constructor with dependencies is forwarded', () async {
      // Without this @PatchableService cannot be used on any service that takes
      // a dependency, which is most of them.
      final output = await generate('''
$_imports
@PatchableService()
class RulesBase {
  RulesBase(this.rate);
  final int rate;
  int total(int a) => a * rate;
}
''');
      expect(output, contains('Rules(super.rate) : super();'));
      expectValidDart(asLibrary(output, '''
class RulesBase {
  RulesBase(this.rate);
  final int rate;
  int total(int a) => a * rate;
}
'''));
    });

    test('named parameters are forwarded with their required-ness', () async {
      final output = await generate('''
$_imports
@PatchableService()
class RulesBase {
  RulesBase({required this.rate, this.label = ''});
  final int rate;
  final String label;
  int total(int a) => a * rate;
}
''');
      expect(output, contains('required super.rate'));
      expect(output, contains('super.label'));
    });

    test('a named constructor is forwarded under its own name', () async {
      final output = await generate('''
$_imports
@PatchableService()
class RulesBase {
  RulesBase.withRate(this.rate);
  final int rate;
  int total(int a) => a * rate;
}
''');
      expect(
          output, contains('Rules.withRate(super.rate) : super.withRate();'));
    });
  });

  group('misplaced annotations', () {
    test('@patchable on a class is a build error', () async {
      // The most natural mistake there is. It used to generate nothing and say
      // nothing.
      final error = await generateError('''
$_imports
@patchable
class Rules {
  int total(int a) => a;
}
''');
      expect(error, contains('top-level functions'));
      expect(error, contains('@PatchableService'));
    });

    test('@patchable on a method is a build error', () async {
      final error = await generateError('''
$_imports
class Rules {
  @patchable
  int total(int a) => a;
}
''');
      expect(error, contains('top-level functions'));
    });
  });

  group('exclude', () {
    test('a misspelled exclusion is a build error', () async {
      // Silently ignoring it marks the hot path the developer was trying to
      // keep off the boundary — the opposite of what they asked for.
      final error = await generateError('''
$_imports
@PatchableService(exclude: ['totl'])
class RulesBase {
  int total(int a) => a;
  int other(int a) => a;
}
''');
      expect(error, contains('totl'));
    });
  });

  group('duplicate ids', () {
    test('two functions with the same explicit id are a build error', () async {
      final error = await generateError('''
$_imports
@Patchable(id: 'same')
int _a(int v) => v;

@Patchable(id: 'same')
int _b(int v) => v;
''');
      expect(error, contains('share the dispatch id'));
    });
  });

  group('shim variable names cannot collide with parameters', () {
    test('a parameter named like the shim locals still works', () async {
      final output = await generate('''
$_imports
@patchable
int _f(int _mfSlot, int _mfResult) => _mfSlot;
''');
      // Not a great parameter name, but the generator must not produce code
      // that shadows its own locals.
      expectValidDart(
          'library x;\n${output.replaceFirst("part of 'pricing.dart';", '')}'
          '\nint _f(int a, int b) => a;');
    });
  });

  test('the contract version is recorded in the ABI marker', () async {
    final output = await generate('$_imports\n@patchable\nint _a(int v) => v;');
    expect(output, contains('"contract":'));
  });
}
