import 'dart:convert';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
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

/// Version of the contract between generated shims and the runtime.
///
/// Folded into the fingerprint. The shims call `Patch.invokeN` with a specific
/// argument shape and unwrap the result a specific way; if that contract
/// changes, patches built against the old one are not safe to load even though
/// every user-visible signature is identical. Bump this whenever the emitted
/// call sequence changes.
const int kShimContractVersion = 4;

/// Local variable names the generated shims use.
///
/// Prefixed rather than plain `_s` and `_r`, which a user parameter can
/// legitimately be called — and then the shim shadows it and either fails to
/// compile or, worse, compiles against the wrong variable.
const String _slotVar = '_mfSlot';
const String _resultVar = '_mfResult';
const String _typedVar = '_mfTyped';
const String _valueVar = '_mfValue';

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

  /// JSON form embedded in the generated file.
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
/// read away from doing nothing, so a marked function that is not currently
/// patched costs a few nanoseconds. Everything else — building an argument
/// list, looking up a map, parsing a version constraint — happens only once a
/// patch is actually live.
final class ShimGenerator extends Generator {
  /// Creates a [ShimGenerator].
  ShimGenerator();

  static const _patchable = TypeChecker.typeNamed(Patchable);
  static const _service = TypeChecker.typeNamed(PatchableService);

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final records = <ShimRecord>[];
    final buffer = StringBuffer();
    final libraryId = _libraryId(buildStep.inputId);

    for (final element in library.allElements) {
      if (element is TopLevelFunctionElement) {
        if (_patchable.hasAnnotationOfExact(element)) {
          buffer.writeln(_generateFunction(element, libraryId, records));
        }
        continue;
      }
      if (element is ClassElement) {
        // A misplaced @patchable is a build error, not a no-op. The analyzer
        // catches most of these first via @Target, but a class in a library
        // that predates the annotation update would otherwise generate nothing
        // and say nothing — the loudest possible silence.
        _rejectMisplaced(element);
        for (final method in element.methods) {
          _rejectMisplaced(method);
        }
        if (_service.hasAnnotationOfExact(element)) {
          buffer.writeln(_generateService(element, libraryId, records));
        }
      }
    }

    if (buffer.isEmpty) return null;

    _rejectDuplicates(records);

    final marked = StringBuffer();
    for (final record in records) {
      marked.writeln('// $abiMarker${jsonEncode(record.toJson())}');
    }
    marked
      ..writeln('// $abiMarker'
          '{"contract":$kShimContractVersion}')
      ..writeln()
      ..write(buffer);
    return marked.toString();
  }

  void _rejectMisplaced(Element element) {
    if (!_patchable.hasAnnotationOfExact(element)) return;
    throw InvalidGenerationSourceError(
      '@patchable only applies to top-level functions. A class or a method '
      'annotated with it generates nothing at all, which is worse than an '
      'error. Use @PatchableService on the class instead.',
      element: element,
    );
  }

  void _rejectDuplicates(List<ShimRecord> records) {
    final seen = <String, String>{};
    for (final record in records) {
      final previous = seen[record.id];
      if (previous != null) {
        throw InvalidGenerationSourceError(
          'two patchable functions share the dispatch id "${record.id}": '
          '$previous and ${record.origin}. A patch overriding it would reach '
          'whichever the runtime happened to register last.',
        );
      }
      seen[record.id] = record.origin;
    }
  }

  String _generateFunction(TopLevelFunctionElement element, String libraryId,
      List<ShimRecord> records) {
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

    // Cached the same way a service caches its methods. Without it, a marked
    // function that is not itself patched pays a string hash and a map probe on
    // every call for as long as *any* patch is live — which, for a code-push
    // system, is the normal state of a shipped app. Measured at 8.9ns against
    // 4.5ns; see `bench/`.
    final slotField = '_mfSlot\$$publicName';
    final generationField = '_mfGeneration\$$publicName';

    return '''
int? $slotField;
int $generationField = -1;

/// Generated dispatch shim for [$privateName].
///
/// Calls the patched implementation of `$id` when one is live, and
/// `$privateName` otherwise.
${signature.returnDisplay} $publicName(${signature.declaration}) {
  if ($generationField != Patch.generation) {
    $generationField = Patch.generation;
    $slotField = Patch.slot(r'$id');
  }
${_body(id, signature, '$privateName(${signature.forwarding})', slotExpression: slotField)}
}
''';
  }

  String _generateService(
      ClassElement element, String libraryId, List<ShimRecord> records) {
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

    final declared = <String>{
      for (final method in element.methods)
        if (method.name != null) method.name!,
    };
    final unmatched = excluded.difference(declared);
    if (unmatched.isNotEmpty) {
      throw InvalidGenerationSourceError(
        '`$baseName` has no method named ${unmatched.map((n) => '"$n"').join(', ')}, '
        'but @PatchableService excludes it. A misspelled exclusion leaves the '
        'method you meant to keep off the boundary firmly on it.',
        element: element,
      );
    }

    final abstractMethods = <String>[];
    final methods = <MethodElement>[];
    for (final method in element.methods) {
      final name = method.name;
      if (name == null || method.isStatic || name.startsWith('_')) continue;
      if (excluded.contains(name)) continue;
      if (method.isAbstract) {
        abstractMethods.add(name);
        continue;
      }
      methods.add(method);
    }

    if (abstractMethods.isNotEmpty) {
      throw InvalidGenerationSourceError(
        '`$baseName` declares abstract method'
        '${abstractMethods.length == 1 ? '' : 's'} '
        '${abstractMethods.map((n) => '"$n"').join(', ')}. A shim falls back to '
        '`super`, and there is nothing there to call. Give them bodies, or '
        'list them in @PatchableService(exclude: [...]) and implement them in '
        'a subclass.',
        element: element,
      );
    }

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

      fields.writeln('  int? _mfSlot$i;');
      sync.writeln("    _mfSlot$i = Patch.slot(r'$id');");
      overrides.writeln('''
  @override
  ${signature.returnDisplay} $name(${signature.declaration}) {
    _mfSync();
${_body(id, signature, 'super.$name(${signature.forwarding})', slotExpression: '_mfSlot$i')}
  }
''');
    }

    return '''
/// Generated patchable façade over [$baseName].
///
/// Use this class at your call sites. Each method dispatches to a patch when
/// one is live and to `$baseName` otherwise.
class $generatedName extends $baseName {
${_constructors(element, generatedName, baseName)}  int _mfGeneration = -1;
${fields.toString().trimRight()}

  /// Refreshes the cached slots when a patch is activated or removed.
  ///
  /// Comparing an int is cheaper than a map lookup, and this runs on every
  /// call, so the cheap version is the one that matters.
  @pragma('vm:prefer-inline')
  void _mfSync() {
    if (_mfGeneration == Patch.generation) return;
    _mfGeneration = Patch.generation;
${sync.toString().trimRight()}
  }

${overrides.toString().trimRight()}
}
''';
  }

  /// Forwards the base class's constructors.
  ///
  /// Without this the generated class only has an implicit no-argument
  /// constructor, so `@PatchableService` cannot be used on any service that
  /// takes a dependency — which is most of them.
  String _constructors(
      ClassElement element, String generatedName, String baseName) {
    final buffer = StringBuffer();
    for (final constructor in element.constructors) {
      if (constructor.isFactory) continue;
      final name = constructor.name;
      // Analyzer names the unnamed constructor `new`.
      final isUnnamed = name == null || name.isEmpty || name == 'new';
      final suffix = isUnnamed ? '' : '.$name';

      final positional = <String>[];
      final named = <String>[];
      for (final parameter in constructor.formalParameters) {
        final parameterName = parameter.name;
        if (parameterName == null) continue;
        if (parameter.isNamed) {
          named.add('${parameter.isRequired ? 'required ' : ''}'
              'super.$parameterName');
        } else if (parameter.isOptionalPositional) {
          positional.add('super.$parameterName');
        } else {
          positional.add('super.$parameterName');
        }
      }

      final parameters = <String>[
        ...positional,
        if (named.isNotEmpty) '{${named.join(', ')}}',
      ].join(', ');
      buffer.writeln('  $generatedName$suffix($parameters) : super$suffix();');
    }
    return buffer.isEmpty ? '' : '${buffer.toString().trimRight()}\n\n';
  }

  /// The shared shim body: check, dispatch, unwrap, fall back.
  String _body(String id, _Signature signature, String fallback,
      {required String slotExpression}) {
    final lines = StringBuffer();
    // The caller has already refreshed the cache — a service in `_mfSync`, a
    // top-level function inline — so the hot path here is one read and one null
    // check, whether or not a patch is live.
    lines.writeln('    final $_slotVar = $slotExpression;');
    lines.writeln('    if ($_slotVar != null) {');
    if (signature.isAsync) {
      lines.write(_awaitBody(id, signature, fallback));
      lines.writeln('    }');
      lines.write('    return $fallback;');
      return lines.toString();
    }
    lines.writeln(
        '      final $_resultVar = ${signature.invocation(_slotVar, id)};');
    if (signature.returnsVoid) {
      lines.writeln('      if ($_resultVar != null) return;');
    } else if (signature.returnIsNullable) {
      lines.writeln(
          '      if (identical($_resultVar, patchedNull)) return null;');
      lines.writeln('      if ($_resultVar != null) {');
      lines.write(_convert(signature, indent: '        ', source: _resultVar));
      lines.writeln('      }');
    } else {
      // A patch that returns null where the signature says non-null is a bug in
      // the patch. Falling through to the original is the safe reading: the
      // alternative is a null that the caller's type system says cannot happen.
      lines.writeln('      if ($_resultVar != null && '
          '!identical($_resultVar, patchedNull)) {');
      lines.write(_convert(signature, indent: '        ', source: _resultVar));
      lines.writeln('      }');
    }
    lines.writeln('    }');
    lines.write('    return $fallback;');
    return lines.toString();
  }

  /// Turns the dispatch result into the declared return type, or falls through.
  ///
  /// The conversion is total: null means the patch returned something this
  /// signature cannot accept, and falling through from here runs the original.
  /// Casting instead would hand a `TypeError` to a caller who has no idea a
  /// patch is involved — which is the one failure dispatch promises downloaded
  /// code can never cause.
  String _convert(_Signature signature,
      {required String indent, required String source, String? fallback}) {
    final expression = signature.unwrap(source);
    if (!signature.conversionCanFail) {
      return '${indent}return $expression;\n';
    }
    final buffer = StringBuffer()
      ..write('${indent}final $_typedVar = $expression;\n')
      ..write('${indent}if ($_typedVar != null) return $_typedVar;\n');
    // The synchronous path falls off the end into the shim's shared fallback;
    // a continuation has no end to fall off, so it needs one written here.
    if (fallback != null) buffer.write('${indent}return $fallback;\n');
    return buffer.toString();
  }

  /// The async half of [_body]: the interpreter's future, converted.
  ///
  /// "A patch that fails runs the original" has to survive the await, so the
  /// fallback is called from inside the continuation rather than reached by
  /// falling through. `Patch.awaitPatched` answers null for a patch that threw,
  /// which is the same signal the synchronous dispatcher already uses — so the
  /// three branches below are the synchronous ones, one await later.
  String _awaitBody(String id, _Signature signature, String fallback) {
    const inner = '        ';
    final lines = StringBuffer()
      ..writeln('      return Patch.dispatchAsync(')
      ..writeln('        () => ${signature.invocation(_slotVar, id)},')
      ..writeln("        r'$id',")
      ..writeln('      ).then(($_valueVar) {')
      ..writeln('${inner}if ($_valueVar == null) return $fallback;');
    if (signature.returnsVoid) {
      lines.writeln('${inner}return null;');
    } else if (signature.returnIsNullable) {
      lines
        ..writeln('${inner}if (identical($_valueVar, patchedNull)) '
            'return null;')
        ..write(_convert(signature,
            indent: inner, source: _valueVar, fallback: fallback));
    } else {
      lines
        ..writeln('${inner}if (identical($_valueVar, patchedNull)) '
            'return $fallback;')
        ..write(_convert(signature,
            indent: inner, source: _valueVar, fallback: fallback));
    }
    lines.writeln('      });');
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
    required this.isAsync,
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
      if (name == null) {
        throw InvalidGenerationSourceError(
          '`$id` has an unnamed parameter, which the generator cannot forward '
          'without changing the function\'s arity.',
          element: element,
        );
      }
      if (parameter.isNamed || parameter.isOptionalPositional) {
        throw InvalidGenerationSourceError(
          'Optional and named parameters are not supported on a patchable '
          'function yet. `$id` declares `$name`. Use required positional '
          'parameters, or pass a Map.',
          element: element,
        );
      }
      final verdict = classifyType(parameter.type, isReturn: false);
      if (!verdict.isSupported) {
        throw InvalidGenerationSourceError(
          'Parameter `$name` of `$id`: ${verdict.reason}',
          element: element,
        );
      }
      declaration.add('${parameter.type.getDisplayString()} $name');
      forwarding.add(name);
      canonical.add(canonicalType(parameter.type));
      arguments.add(argumentExpression(name, verdict));
    }

    // What the patch result is converted into. For `Future<T>` that is T: the
    // shim keeps declaring `Future<T>` while everything after the await deals
    // in T, and the two are never the same type.
    final awaited = awaitedType(returnType);
    final resultType = awaited ?? returnType;
    final returnsVoid = resultType is VoidType;

    // `void` skips the conversion check because there is nothing to convert,
    // but a `Future<void>` still has the Future itself to validate.
    if (!returnsVoid || awaited != null) {
      final verdict = classifyType(returnType, isReturn: true);
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
      canonicalReturn: canonicalType(returnType),
      returnDisplay: returnType.getDisplayString(),
      returnsVoid: returnsVoid,
      returnIsNullable:
          resultType.nullabilitySuffix == NullabilitySuffix.question,
      arguments: arguments,
      returnType: resultType,
      isAsync: awaited != null,
    );
  }

  final String declaration;
  final String forwarding;
  final List<String> canonicalTypes;
  final String canonicalReturn;
  final String returnDisplay;
  final bool returnsVoid;
  final bool returnIsNullable;

  /// The type the patch result is converted into.
  ///
  /// For a `Future<T>` shim this is T, not the declared type — see
  /// [returnDisplay] for what the emitted signature says.
  final DartType returnType;

  /// Whether the declared return type is a `Future`.
  final bool isAsync;

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

  /// Whether [unwrap]'s expression can answer null and so needs a check.
  bool get conversionCanFail => returnCanFail(returnType);
}
