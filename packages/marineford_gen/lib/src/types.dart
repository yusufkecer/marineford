import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

/// How a value has to be handed to interpreted code.
enum ArgumentForm {
  /// Pass the value through untouched.
  ///
  /// dart_eval unboxes non-nullable `int`, `double` and `bool` parameters, and
  /// passing a wrapped value to one of those throws inside the interpreter.
  raw,

  /// Wrap with `MarinefordJson.wrap` before passing.
  wrapped,
}

/// Whether interpreted code can accept and return a given type at all.
enum TypeSupport {
  /// Fully supported: the generator knows how to move it across the boundary.
  supported,

  /// Not supported. Carries the reason to put in the build error.
  unsupported,
}

/// The verdict on one parameter or return type.
final class TypeVerdict {
  /// Creates a [TypeVerdict].
  const TypeVerdict.ok(this.form)
      : support = TypeSupport.supported,
        reason = null;

  /// Creates a rejection carrying [reason].
  const TypeVerdict.rejected(this.reason)
      : support = TypeSupport.unsupported,
        form = ArgumentForm.wrapped;

  /// Whether the type can cross the boundary.
  final TypeSupport support;

  /// How to pass it, when it can.
  final ArgumentForm form;

  /// Why it cannot, when it cannot.
  final String? reason;

  /// Whether this type is usable.
  bool get isSupported => support == TypeSupport.supported;
}

/// Decides how a type crosses the boundary, or why it cannot.
///
/// The supported set is the JSON-shaped types plus primitives, and `Future` of
/// any of them as a return type. That is not a placeholder for something more
/// ambitious — it is the boundary where the generator can be *certain* it is
/// emitting correct code. Moving an app's own domain object across needs a
/// dart_eval binding, and guessing at the wrapper class name would produce
/// shims that compile and then silently fall back at runtime. A build error
/// naming the problem is worth more than that.
///
/// [isReturn] matters for `Future`, and only for `Future`: a patch can hand one
/// back, but it cannot await one it was given. It is required rather than
/// defaulted because the wrong answer is not an error, it is a confident
/// verdict naming the wrong position — a legal `Future<int>` return told to
/// "await it on your side", which is advice for a parameter.
TypeVerdict classifyType(DartType type, {required bool isReturn}) {
  if (type is VoidType) return const TypeVerdict.ok(ArgumentForm.wrapped);
  if (type is DynamicType) return const TypeVerdict.ok(ArgumentForm.wrapped);

  final nullable = type.nullabilitySuffix == NullabilitySuffix.question;

  if (type.isDartCoreInt || type.isDartCoreDouble || type.isDartCoreBool) {
    // The trap worth spelling out: making one of these nullable flips how it
    // must be passed, because dart_eval only unboxes the non-nullable form.
    return TypeVerdict.ok(nullable ? ArgumentForm.wrapped : ArgumentForm.raw);
  }

  if (type.isDartCoreString || type.isDartCoreNum || type.isDartCoreObject) {
    return const TypeVerdict.ok(ArgumentForm.wrapped);
  }

  if (type.isDartCoreList ||
      type.isDartCoreMap ||
      type.isDartCoreSet ||
      type.isDartCoreIterable) {
    for (final argument in _typeArguments(type)) {
      if (!_convertibleArgument(argument)) {
        return TypeVerdict.rejected(
            '`${argument.getDisplayString()}` cannot be the element type of a '
            'patched collection. The shim converts what the patch returns and '
            'then checks it against this type, and nothing the interpreter can '
            'produce is a `${argument.getDisplayString()}` — so the patch would '
            'build, load, and then be discarded on every call. Use `dynamic`, '
            'a primitive, `String`, `Map<String, dynamic>` or `List<dynamic>`.');
      }
    }
    return const TypeVerdict.ok(ArgumentForm.wrapped);
  }

  if (type.isDartAsyncStream) {
    return const TypeVerdict.rejected(
        '`Stream` cannot cross the patch boundary. A stream can emit and then '
        'fail, and once an event has reached the listener there is no coherent '
        'way to fall back to the original — which is the guarantee every other '
        'patched call keeps. Mark the function that produces each event '
        'instead.');
  }

  if (type.isDartAsyncFutureOr) {
    return const TypeVerdict.rejected(
        '`FutureOr` cannot cross the patch boundary: the shim would have to '
        'decide whether to await before it knows which one it got. Declare '
        'either the synchronous type or `Future` of it.');
  }

  if (type.isDartAsyncFuture) {
    if (!isReturn) {
      return const TypeVerdict.rejected(
          'a `Future` parameter cannot cross the patch boundary. Await it on '
          'your side and mark a function that takes the resolved value — the '
          'patch cannot await something it was handed.');
    }
    if (nullable) {
      return const TypeVerdict.rejected(
          'a nullable `Future` return cannot cross the patch boundary. The '
          'shim cannot tell "no patch" from "a patch that returned no future". '
          'Return a `Future` of a nullable type instead.');
    }
    // A bare `Future` resolves to `Future<dynamic>`, so there is always exactly
    // one argument to read here.
    final awaited = awaitedType(type)!;
    if (awaited.isDartAsyncFuture || awaited.isDartAsyncFutureOr) {
      return const TypeVerdict.rejected(
          'a nested `Future` return cannot cross the patch boundary. One await '
          'is what the shim knows how to do.');
    }
    final inner = classifyType(awaited, isReturn: true);
    if (!inner.isSupported) {
      return TypeVerdict.rejected('what the `Future` resolves to: '
          '${inner.reason}');
    }
    return const TypeVerdict.ok(ArgumentForm.wrapped);
  }

  if (type is FunctionType) {
    return const TypeVerdict.rejected(
        'function types cannot cross the patch boundary. Pass the data the '
        'callback would have produced instead.');
  }

  return TypeVerdict.rejected(
      '`${type.getDisplayString()}` needs a dart_eval binding to cross the '
      'patch boundary, and marineford_gen cannot generate one for you in v1. '
      'Either change the signature to use JSON-shaped types (Map, List, '
      'String, num, bool), or move the boundary: mark a function further up '
      'the call chain whose parameters are already simple. See the chokepoint '
      'pattern in the README.');
}

/// A Dart source expression that passes [expression] in the right form.
String argumentExpression(String expression, TypeVerdict verdict) =>
    switch (verdict.form) {
      ArgumentForm.raw => expression,
      ArgumentForm.wrapped => 'MarinefordJson.wrap($expression)',
    };

/// A Dart source expression converting a dispatch result back to [type].
///
/// The expression is always nullable, and null always means the same thing:
/// the patch returned something this signature cannot accept. The shim reads
/// that as a patch bug and runs the original function.
///
/// It used to be a cast — `unwrapList(r) as List<String>` — which was wrong
/// twice over. `unwrapList` builds a `List<dynamic>`, so any type argument
/// other than `dynamic` failed the cast on a patch that was working perfectly;
/// and a patch that returned the wrong shape entirely made `unwrapMap` return
/// null, so the cast threw a `TypeError` at the caller instead of falling back.
/// Both were invisible because no test ran a collection return.
///
/// See [returnCanFail] for the one type that cannot fail.
String returnExpression(String expression, DartType type) {
  if (type is DynamicType) return 'MarinefordJson.unwrap($expression)';

  final arguments = type is InterfaceType
      ? <String>[for (final a in type.typeArguments) a.getDisplayString()]
      : const <String>[];
  String argument(int index) =>
      index < arguments.length ? arguments[index] : 'dynamic';

  if (type.isDartCoreMap) {
    return 'MarinefordJson.mapOf<${argument(0)}, ${argument(1)}>($expression)';
  }
  if (type.isDartCoreSet) {
    return 'MarinefordJson.setOf<${argument(0)}>($expression)';
  }
  if (type.isDartCoreList || type.isDartCoreIterable) {
    return 'MarinefordJson.listOf<${argument(0)}>($expression)';
  }
  return 'MarinefordJson.valueOf<${_bareType(type)}>($expression)';
}

/// What a `Future` return resolves to, or null if [type] is not one.
///
/// The shim emits the declared type in its own signature and converts the
/// resolved value to this one, so both are needed and they are never the same.
DartType? awaitedType(DartType type) {
  if (!type.isDartAsyncFuture) return null;
  if (type is! InterfaceType || type.typeArguments.length != 1) return null;
  return type.typeArguments.single;
}

/// Whether [returnExpression]'s result needs a null check before it is used.
///
/// Only `dynamic` is exempt: every value is one, so the conversion has nothing
/// to reject.
bool returnCanFail(DartType type) => type is! DynamicType;

/// [type] without its nullability suffix.
///
/// The conversion helpers are already nullable in their return type; asking for
/// `valueOf<String?>` would make a patch that returned null look like a
/// successful conversion, and the `patchedNull` sentinel has already dealt with
/// that case by the time this runs.
String _bareType(DartType type) {
  final display = type.getDisplayString();
  // Driven by the suffix rather than by the text: a display string can end in
  // `?` because of a type *argument* — `List<String?>` — and trimming that one
  // produces source that does not parse.
  return type.nullabilitySuffix == NullabilitySuffix.question
      ? display.substring(0, display.length - 1)
      : display;
}

/// [type]'s type arguments, or empty for anything that has none.
List<DartType> _typeArguments(DartType type) =>
    type is InterfaceType ? type.typeArguments : const <DartType>[];

/// Whether a collection's element type is one the conversion can honour.
///
/// The shim converts what the patch returned and then tests it with `is`, so
/// the argument has to be a shape the unwrapping actually produces: a scalar,
/// `dynamic`, or the precise containers it builds — `Map<String, dynamic>` and
/// `List<dynamic>`. Anything else compiles into a shim that rejects every
/// element for the life of the patch.
bool _convertibleArgument(DartType type) {
  if (type is DynamicType || type is VoidType) return true;
  if (type.isDartCoreObject ||
      type.isDartCoreInt ||
      type.isDartCoreDouble ||
      type.isDartCoreNum ||
      type.isDartCoreBool ||
      type.isDartCoreString) {
    return true;
  }
  final arguments = _typeArguments(type);
  if (type.isDartCoreMap) {
    return arguments.length == 2 &&
        arguments[0].isDartCoreString &&
        arguments[1] is DynamicType;
  }
  if (type.isDartCoreList || type.isDartCoreIterable) {
    return arguments.length == 1 && arguments.single is DynamicType;
  }
  return false;
}

/// A type name stable enough to hash into the ABI fingerprint.
///
/// `getDisplayString` renders a typedef by its alias, so swapping what
/// `UserId` points at — `String` today, `int` tomorrow — leaves the fingerprint
/// unchanged while every patch built against the old meaning becomes wrong. It
/// also renders two different `Result` classes from two libraries identically.
///
/// This resolves the alias and qualifies the name with the library that
/// declares it, so both cases change the hash.
String canonicalType(DartType type) {
  final alias = type.alias;
  if (alias != null) {
    // Hash what the alias means, not what it is called.
    return canonicalType(alias.element.aliasedType);
  }

  final element = type.element;
  final buffer = StringBuffer();
  if (element != null) {
    final uri = element.library?.uri;
    if (uri != null && !uri.isScheme('dart')) {
      buffer.write('$uri::');
    }
  }
  // The name alone, then the arguments qualified the same way. Writing
  // `getDisplayString()` here left the arguments bare, so `List<Result>` hashed
  // identically whichever library `Result` came from — and `List` is dart:core,
  // so nothing else in the entry distinguished them either. That is the exact
  // collision this function exists to close, one level in.
  buffer.write(element?.name ?? type.getDisplayString());
  final arguments = _typeArguments(type);
  if (arguments.isNotEmpty) {
    buffer
      ..write('<')
      ..write([for (final a in arguments) canonicalType(a)].join(','))
      ..write('>');
  }
  if (type.nullabilitySuffix == NullabilitySuffix.question) buffer.write('?');
  return buffer.toString();
}
