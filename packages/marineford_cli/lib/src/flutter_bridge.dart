import 'dart:convert';
import 'dart:io';

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';

import 'config.dart';
import 'flutter_bridge.g.dart';

export 'flutter_bridge.g.dart' show kFlutterBridgeVersion;

/// Compiling patches that import Flutter, from a CLI that does not have it.
///
/// The obstacle is not subtle: flutter_eval imports `dart:ui`, so a package
/// that depends on it cannot run on the standalone Dart VM. Taking that
/// dependency would turn `marineford` into a Flutter package and end
/// `dart pub global activate`.
///
/// What makes the split possible is that the compiler never needs flutter_eval
/// itself. It needs the *shapes* — which classes exist, what their constructors
/// take, what the enums are — and those are plain data that serialise. The
/// wrapper classes, the half that genuinely needs Flutter, are only used at
/// runtime, inside the app, which has Flutter by definition.
///
/// So the declarations are dumped once by `tool/bridge_dump` and bundled in
/// [kFlutterBridgeData]. Bytecode compiled this way runs unmodified under
/// flutter_eval at runtime; the CLI's own tests build a widget patch and check
/// it.
///
/// The declarations are registered only for a patch that imports Flutter, so a
/// patch that does not pays neither the unpacking nor the registration.

/// Whether any of [sources] imports Flutter.
///
/// Anchored the same way the platform-import guard in `builder.dart` is, and
/// with the same caveat: this reads text, so it can be defeated by anyone
/// spelling an import unusually. That is acceptable here because it is not a
/// boundary — the worst a false negative does is fail the compile with an
/// unknown `Widget`, and the worst a false positive does is register
/// declarations nothing goes on to use.
bool usesFlutter(Map<String, String> sources) =>
    sources.values.any(_flutterImport.hasMatch);

final RegExp _flutterImport = RegExp(
  r'''^\s*(?:import|export)\s+['"]package:flutter/''',
  multiLine: true,
);

/// Registers flutter_eval's bridge declarations on [compiler].
///
/// Unpacks on first use and keeps the result: `build` compiles once per
/// process today, but the cost is 800 KB of JSON and a caller that grew a
/// second compile should not pay it twice.
void registerFlutterBridges(Compiler compiler) {
  final bundle = _bundle ??= _unpack();
  for (final declaration in bundle.classes) {
    compiler.defineBridgeClass(declaration);
  }
  for (final declaration in bundle.enums) {
    compiler.defineBridgeEnum(declaration);
  }
  for (final declaration in bundle.functions) {
    compiler.defineBridgeTopLevelFunction(declaration);
  }
  for (final source in bundle.sources) {
    compiler.addSource(source);
  }
  for (final (library, export) in bundle.exports) {
    compiler.addExportedLibraryMapping(library, export);
  }
}

_Bundle? _bundle;

_Bundle _unpack() {
  final Map<String, dynamic> decoded;
  try {
    decoded =
        jsonDecode(utf8.decode(gzip.decode(base64.decode(kFlutterBridgeData))))
            as Map<String, dynamic>;
  } on Object catch (e) {
    // Only reachable if the generated file was hand-edited or truncated, which
    // is worth saying outright — the alternative is a base64 error surfacing
    // from the middle of a patch build with no hint of where it came from.
    throw CliException(
      'the bundled Flutter bridge declarations could not be read ($e)',
      hint: 'lib/src/flutter_bridge.g.dart is generated. Restore it, or '
          'regenerate it with: flutter test tool/bridge_dump',
    );
  }

  List<Map<String, dynamic>> entries(String key) => <Map<String, dynamic>>[
        for (final entry in decoded[key] as List<dynamic>? ?? const [])
          entry as Map<String, dynamic>,
      ];

  return _Bundle(
    classes: <BridgeClassDef>[
      for (final json in entries('classes')) BridgeClassDef.fromJson(json),
    ],
    enums: <BridgeEnumDef>[
      for (final json in entries('enums')) BridgeEnumDef.fromJson(json),
    ],
    functions: <BridgeFunctionDeclaration>[
      for (final json in entries('functions'))
        BridgeFunctionDeclaration.fromJson(json),
    ],
    sources: <DartSource>[
      for (final json in entries('sources'))
        DartSource(json['uri'] as String, json['source'] as String),
    ],
    exports: <(String, String)>[
      for (final json in entries('exports'))
        (json['library'] as String, json['export'] as String),
    ],
  );
}

class _Bundle {
  const _Bundle({
    required this.classes,
    required this.enums,
    required this.functions,
    required this.sources,
    required this.exports,
  });

  final List<BridgeClassDef> classes;
  final List<BridgeEnumDef> enums;
  final List<BridgeFunctionDeclaration> functions;
  final List<DartSource> sources;
  final List<(String, String)> exports;
}
