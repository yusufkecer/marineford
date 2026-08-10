import 'dart:convert';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:marineford_annotation/marineford_annotation.dart';
import 'package:source_gen/source_gen.dart';

import 'types.dart';

/// Prefix of the machine-readable ABI record lines in a generated file.
///
/// The records live in the generated source rather than in a side output on
/// purpose: a `part` builder can only write one file, and duplicating the
/// analysis in a second builder would let the two disagree about what a library
/// contains. Carrying the data in the same file makes that impossible.
const String abiMarker = 'MARINEFORD-ABI: ';

/// One patchable function, as recorded for the ABI fingerprint and the id
/// registry.
final class ShimRecord {
  /// Creates a [ShimRecord].
  const ShimRecord({
    required this.id,
    required this.parameterTypes,
    required this.returnType,
    required this.origin,
  });

  /// Dispatch id, as it must appear in the patch's `@RuntimeOverride`.
  final String id;

  /// Canonical parameter type names.
  final List<String> parameterTypes;

  /// Canonical return type name.
  final String returnType;

  /// Human-readable location, for `marineford doctor`.
  final String origin;

  /// JSON form written to the side output the ABI builder aggregates.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'params': parameterTypes,
        'returns': returnType,
        'origin': origin,
      };
}

/// Generates dispatch shims for `@patchable` and `@PatchableService`.
///
/// The shims are the whole performance story. Each one is a single static field
/// read against null before anything else happens, so a marked function that is
/// not currently patched costs ~2.4ns against ~1.7ns unmarked. Everything else
/// — building an argument list, looking up a map, parsing a version constraint —
/// happens only once a patch is actually live.
final class ShimGenerator extends Generator {
  /// Creates a [ShimGenerator].
  ShimGenerator();

  static const _patchable = TypeChecker.typeNamed(Patchable);
  static const _service = TypeChecker.typeNamed(PatchableService);

  /// Everything generated during this build, for the ABI side output.
  final List<ShimRecord> records = <ShimRecord>[];

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    records.clear();
    final buffer = StringBuffer();
    final libraryId = _libraryId(buildStep.inputId);

    for (final element in library.allElements) {
      if (element is TopLevelFunctionElement &&
          _patchable.hasAnnotationOfExact(element)) {
        buffer.writeln(_generateFunction(element, libraryId));
      } else if (element is ClassElement &&
          _service.hasAnnotationOfExact(element)) {
        buffer.writeln(_generateService(element, libraryId, library));
      }
    }

    if (buffer.isEmpty) return null;

    // The ABI records ride along inside the generated file as machine-readable
    // comments. The aggregating step reads them back out rather than resolving
    // every library a second time — and because they live in the same file as
    // the shims they describe, the two can never drift apart.
    final marked = StringBuffer();
    for (final record in records) {
      marked.writeln('// $abiMarker${jsonEncode(record.toJson())}');
    }
    marked
      ..writeln()
      ..write(buffer);
    return marked.toString();
  }

  String _generateFunction(TopLevelFunctionElement element, String libraryId) {
    final privateName = element.name;
    if (privateName == null || !privateName.startsWith('_')) {
      throw InvalidGenerationSourceError(
        'A @patchable function must be private so the generator can own the '
        'public name. Rename `$privateName` to `_$privateName`; callers keep '
        'using `$privateName`, which will be generated.',
        element: element,
      );
    }
    final publicName = privateName.substring(1);
    final id = _readId(element) ?? '$libraryId#$publicName';

    final signature = _Signature.of(
        element.formalParameters, element.returnType,
        element: element, id: id);
    records.add(ShimRecord(
      id: id,
      parameterTypes: signature.canonicalTypes,
      returnType: signature.canonicalReturn,
      origin: '$libraryId $publicName()',
    ));

    return '''
/// Generated dispatch shim for [$privateName].
///
/// Calls the patched implementation of `$id` when one is live, and
/// `$privateName` otherwise.
${signature.returnDisplay} $publicName(${signature.declaration}) {
${_body(id, signature, '$privateName(${signature.forwarding})')}
}
''';
  }

  String _generateService(
      ClassElement element, String libraryId, LibraryReader library) {
    final annotation = _service.firstAnnotationOfExact(element)!;
    final reader = ConstantReader(annotation);
    final baseName = element.name;
    if (baseName == null) {
      throw InvalidGenerationSourceError('unnamed class', element: element);
    }

    final explicit = reader.peek('name')?.stringValue;
    final generatedName = explicit ??
        (baseName.endsWith('Base')
            ? baseName.substring(0, baseName.length - 4)
            : '${baseName}Patchable');
    if (generatedName == baseName) {
      throw InvalidGenerationSourceError(
        'The generated class would collide with `$baseName`. Name the '
        'annotated class `${baseName}Base`, or pass an explicit name to '
        '@PatchableService.',
        element: element,
      );
    }

    final excluded = <String>{
      for (final value
          in reader.peek('exclude')?.listValue ?? const <DartObject>[])
        value.toStringValue() ?? '',
    };

    final methods = <MethodElement>[
      for (final method in element.methods)
        if (!method.isStatic &&
            !(method.name?.startsWith('_') ?? true) &&
            !excluded.contains(method.name))
          method,
    ];

    if (methods.isEmpty) {
      throw InvalidGenerationSourceError(
        '`$baseName` has no public instance methods to make patchable. Either '
        'add one or drop the @PatchableService annotation.',
        element: element,
      );
    }

    final fields = StringBuffer();
    final sync = StringBuffer();
    final overrides = StringBuffer();

    for (var i = 0; i < methods.length; i++) {
      final method = methods[i];
      final name = method.name!;
      final id = '$libraryId#$generatedName.$name';
      final signature = _Signature.of(
          method.formalParameters, method.returnType,
          element: method, id: id);

      records.add(ShimRecord(
        id: id,
        parameterTypes: signature.canonicalTypes,
        returnType: signature.canonicalReturn,
        origin: '$libraryId $generatedName.$name()',
      ));

      fields.writeln('  int? _s$i;');
      sync.writeln("    _s$i = Patch.slot(r'$id');");
      overrides.writeln('''
  @override
  ${signature.returnDisplay} $name(${signature.declaration}) {
    _sync();
${_body(id, signature, 'super.$name(${signature.forwarding})', slotExpression: '_s$i')}
  }
''');
    }

    return '''
/// Generated patchable façade over [$baseName].
///
/// Use this class at your call sites. Each method dispatches to a patch when
/// one is live and to `$baseName` otherwise.
class $generatedName extends $baseName {
  int _generation = -1;
${fields.toString().trimRight()}

  /// Refreshes the cached slots when a patch is activated or removed.
  ///
  /// Comparing an int is cheaper than a map lookup, and this runs on every
  /// call, so the cheap version is the one that matters.
  @pragma('vm:prefer-inline')
  void _sync() {
    if (_generation == Patch.generation) return;
    _generation = Patch.generation;
${sync.toString().trimRight()}
  }

${overrides.toString().trimRight()}
}
''';
  }

  /// The shared shim body: check, dispatch, unwrap, fall back.
  String _body(String id, _Signature signature, String fallback,
      {String? slotExpression}) {
    final lines = StringBuffer();
    // A service caches its slot in a field and hands the expression in; a
    // top-level function looks it up here. Either way the hot path ends up as
    // one read and one null check.
    lines.writeln(slotExpression == null
        ? "    final _s = Patch.slot(r'$id');"
        : '    final _s = $slotExpression;');
    lines.writeln('    if (_s != null) {');
    lines.writeln('      final _r = ${signature.invocation('_s', id)};');
    if (signature.returnsVoid) {
      lines.writeln('      if (_r != null) return;');
    } else if (signature.returnIsNullable) {
      lines.writeln('      if (identical(_r, patchedNull)) return null;');
      lines.writeln('      if (_r != null) return ${signature.unwrap('_r')};');
    } else {
      lines.writeln('      if (_r != null && !identical(_r, patchedNull)) {');
      lines.writeln('        return ${signature.unwrap('_r')};');
      lines.writeln('      }');
    }
    lines.writeln('    }');
    lines.write('    return $fallback;');
    return lines.toString();
  }

  String? _readId(Element element) {
    final annotation = _patchable.firstAnnotationOfExact(element);
    if (annotation == null) return null;
    return ConstantReader(annotation).peek('id')?.stringValue;
  }

  static String _libraryId(AssetId id) => 'pkg:${id.package}/${id.path}';
}

/// The pieces of a signature the templates need.
final class _Signature {
  _Signature._({
    required this.declaration,
    required this.forwarding,
    required this.canonicalTypes,
    required this.canonicalReturn,
    required this.returnDisplay,
    required this.returnsVoid,
    required this.returnIsNullable,
    required List<String> arguments,
    required this.returnType,
  }) : _arguments = arguments;

  static _Signature of(
    List<FormalParameterElement> parameters,
    DartType returnType, {
    required Element element,
    required String id,
  }) {
    final declaration = <String>[];
    final forwarding = <String>[];
    final canonical = <String>[];
    final arguments = <String>[];

    for (final parameter in parameters) {
      final name = parameter.name;
      if (name == null) continue;
      if (parameter.isNamed || parameter.isOptionalPositional) {
        throw InvalidGenerationSourceError(
          'Optional and named parameters are not supported on a patchable '
          'function yet. `$id` declares `$name`. Use required positional '
          'parameters, or pass a Map.',
          element: element,
        );
      }
      final verdict = classifyType(parameter.type);
      if (!verdict.isSupported) {
        throw InvalidGenerationSourceError(
          'Parameter `$name` of `$id`: ${verdict.reason}',
          element: element,
        );
      }
      declaration.add('${parameter.type.getDisplayString()} $name');
      forwarding.add(name);
      canonical.add(parameter.type.getDisplayString());
      arguments.add(argumentExpression(name, verdict));
    }

    final returnsVoid = returnType is VoidType;
    if (!returnsVoid) {
      final verdict = classifyType(returnType);
      if (!verdict.isSupported) {
        throw InvalidGenerationSourceError(
          'Return type of `$id`: ${verdict.reason}',
          element: element,
        );
      }
    }

    return _Signature._(
      declaration: declaration.join(', '),
      forwarding: forwarding.join(', '),
      canonicalTypes: canonical,
      canonicalReturn: returnType.getDisplayString(),
      returnDisplay: returnType.getDisplayString(),
      returnsVoid: returnsVoid,
      returnIsNullable: returnType.getDisplayString().endsWith('?'),
      arguments: arguments,
      returnType: returnType,
    );
  }

  final String declaration;
  final String forwarding;
  final List<String> canonicalTypes;
  final String canonicalReturn;
  final String returnDisplay;
  final bool returnsVoid;
  final bool returnIsNullable;
  final DartType returnType;
  final List<String> _arguments;

  /// The `Patch.invokeN(...)` call for this arity.
  String invocation(String slot, String id) {
    final joined = _arguments.isEmpty ? '' : ', ${_arguments.join(', ')}';
    if (_arguments.length <= 3) {
      return "Patch.invoke${_arguments.length}($slot$joined, r'$id')";
    }
    return "Patch.invokeN($slot, [${_arguments.join(', ')}], r'$id')";
  }

  /// Converts the dispatch result back to the declared return type.
  String unwrap(String expression) => returnExpression(expression, returnType);
}
