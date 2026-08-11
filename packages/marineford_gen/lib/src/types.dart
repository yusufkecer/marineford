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
/// v1 supports the JSON-shaped types plus primitives. That is not a placeholder
/// for something more ambitious — it is the boundary where the generator can be
/// *certain* it is emitting correct code. Moving an app's own domain object
/// across needs a dart_eval binding, and guessing at the wrapper class name
/// would produce shims that compile and then silently fall back at runtime.
/// A build error naming the problem is worth more than that.
TypeVerdict classifyType(DartType type) {
  if (type is VoidType) return const TypeVerdict.ok(ArgumentForm.wrapped);
  if (type is DynamicType) return const TypeVerdict.ok(ArgumentForm.wrapped);

  final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
  final name = type.element?.name;

  if (type.isDartCoreInt || type.isDartCoreDouble || type.isDartCoreBool) {
    // The trap worth spelling out: making one of these nullable flips how it
    // must be passed, because dart_eval only unboxes the non-nullable form.
    return TypeVerdict.ok(nullable ? ArgumentForm.wrapped : ArgumentForm.raw);
  }

  if (type.isDartCoreString ||
      type.isDartCoreNum ||
      type.isDartCoreObject ||
      type.isDartCoreList ||
      type.isDartCoreMap ||
      type.isDartCoreSet ||
      type.isDartCoreIterable) {
    return const TypeVerdict.ok(ArgumentForm.wrapped);
  }

  if (name == 'Future' || name == 'Stream') {
    return TypeVerdict.rejected(
        '`$name` cannot cross the patch boundary in v1. Keep the async work in '
        'your own code and mark the synchronous function it awaits instead — '
        'that is usually the part with the bug anyway.');
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
/// Collections come back holding interpreter values, so they need the deep
/// unwrap rather than a plain cast; scalars are already reified by the
/// dispatcher.
String returnExpression(String expression, DartType type) {
  final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
  final display = type.getDisplayString();

  if (type.isDartCoreMap) {
    final call = 'MarinefordJson.unwrapMap($expression)';
    return nullable ? call : '$call as $display';
  }
  if (type.isDartCoreList || type.isDartCoreSet || type.isDartCoreIterable) {
    final call = 'MarinefordJson.unwrapList($expression)';
    return nullable ? call : '$call as $display';
  }
  if (type is DynamicType) return 'MarinefordJson.unwrap($expression)';
  return '$expression as $display';
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
  buffer.write(type.getDisplayString());
  return buffer.toString();
}
