import 'dart:convert';
import 'dart:io';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regenerates the Flutter bridge declarations bundled with `marineford_cli`.
///
/// Run it with:
///
/// ```
/// flutter test tool/bridge_dump
/// ```
///
/// This is a test because it has to be. Registering flutter_eval's declarations
/// means loading flutter_eval, which imports `dart:ui`, which the standalone
/// Dart VM does not have — so `dart run` cannot do it and `flutter test` is the
/// only harness that can. The output is checked in; nothing in CI runs this.
///
/// Why bundle the declarations at all: `marineford_cli` compiles patches, and
/// compiling one that imports Flutter needs flutter_eval's bridge definitions.
/// Depending on flutter_eval directly would make the CLI a Flutter package and
/// end `dart pub global activate`. The definitions are pure data — class,
/// enum and function shapes plus a handful of Dart source strings — so they
/// serialise, and a pure Dart CLI can register them from JSON. That the
/// bytecode this produces runs correctly under Flutter is covered end to end by
/// the CLI's own tests.
void main() {
  test('regenerates the bundled Flutter bridge declarations', () {
    final recorder = _Recorder();
    flutterEvalPlugin.configureForCompile(recorder);

    expect(recorder.classes, isNotEmpty,
        reason: 'flutter_eval registered nothing — has its plugin API moved?');

    final json = jsonEncode(<String, Object?>{
      'classes': recorder.classes,
      'enums': recorder.enums,
      'functions': recorder.functions,
      'sources': recorder.sources,
      'exports': recorder.exports,
    });

    final packed = base64.encode(gzip.encode(utf8.encode(json)));
    final version = _flutterEvalVersion();

    final out =
        File('../../packages/marineford_cli/lib/src/flutter_bridge.g.dart');
    out.writeAsStringSync(_render(packed, version, recorder));

    // ignore: avoid_print
    print('flutter_eval $version: ${recorder.classes.length} classes, '
        '${recorder.enums.length} enums, ${recorder.functions.length} '
        'functions, ${recorder.sources.length} sources, '
        '${recorder.exports.length} export mappings');
    // ignore: avoid_print
    print('wrote ${out.path} (${(packed.length / 1024).round()} KB packed, '
        '${(json.length / 1024).round()} KB raw)');
  });
}

/// The resolved flutter_eval version, so the generated file can name it.
///
/// Read from the lock file rather than the pubspec: the pubspec says what is
/// allowed, and what was actually dumped is what matters when the bundled
/// declarations disagree with an app's flutter_eval.
String _flutterEvalVersion() {
  final lock = File('pubspec.lock').readAsStringSync();
  final match =
      RegExp(r'flutter_eval:[\s\S]{0,400}?version: "([^"]+)"').firstMatch(lock);
  return match?.group(1) ?? 'unknown';
}

/// Emits the file already formatted.
///
/// `dart format` cannot split a string literal but it does move the assignment
/// off the declaration line, so a template that ignored this left the tree
/// dirty after every run of the tool — which reads as an uncommitted change
/// nobody made.
String _render(String packed, String version, _Recorder recorder) => '''
// GENERATED — do not edit. Regenerate with: flutter test tool/bridge_dump
//
// flutter_eval $version: ${recorder.classes.length} classes, '''
    '''${recorder.enums.length} enums, ${recorder.functions.length} top-level '''
    '''functions, ${recorder.sources.length} sources, '''
    '''${recorder.exports.length} export mappings.
//
// gzipped and base64'd because this is 800 KB of JSON in the raw, and a Dart
// source file that large is slow to parse on every CLI start. Unpacked lazily,
// and only for a patch that imports Flutter.

/// The flutter_eval release these declarations were taken from.
const String kFlutterBridgeVersion = '$version';

/// flutter_eval's compile-time bridge declarations, gzipped and base64 encoded.
const String kFlutterBridgeData =
    '$packed';
''';

/// Records what a plugin registers, instead of compiling with it.
class _Recorder implements BridgeDeclarationRegistry {
  final classes = <Map<String, dynamic>>[];
  final enums = <Map<String, dynamic>>[];
  final functions = <Map<String, dynamic>>[];
  final sources = <Map<String, String>>[];
  final exports = <Map<String, String>>[];

  @override
  void defineBridgeClass(BridgeClassDef classDef) =>
      classes.add(classDef.toJson());

  @override
  void defineBridgeEnum(BridgeEnumDef enumDef) => enums.add(enumDef.toJson());

  @override
  void defineBridgeTopLevelFunction(BridgeFunctionDeclaration function) =>
      functions.add(function.toJson());

  @override
  void addSource(DartSource source) => sources.add(<String, String>{
        'uri': source.uri.toString(),
        // Always a string source in practice: flutter_eval builds these from
        // constants in its own library. A file-backed one would have nothing
        // to serialise, so it is worth failing loudly rather than silently
        // bundling an empty library.
        'source': source.stringSource ??
            (throw StateError('${source.uri} is file-backed and cannot be '
                'bundled')),
      });

  @override
  void addExportedLibraryMapping(String libraryUri, String exportUri) =>
      exports.add(<String, String>{'library': libraryUri, 'export': exportUri});
}
