import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

/// Converts plain Dart JSON to and from the form interpreted code can read.
///
/// This exists because of a trap that fails silently. Handing a decoded
/// `Map<String, dynamic>` to interpreted code via `$Map.wrap` looks like it
/// works — the call succeeds, nothing throws — but every key lookup returns
/// null. The interpreter looks keys up with `$String('status')` while the
/// underlying map is keyed by a plain `'status'`, and the two are not equal.
/// The patch then quietly takes its fallback branch and you are left debugging
/// a wrong answer with no error to follow.
///
/// So the wrapping has to be deep, keys included, and it has to be the
/// generator's job rather than the caller's. Nobody should have to know this.
///
/// ## Which arguments get wrapped
///
/// dart_eval unboxes some parameters and not others, and passing the wrong form
/// throws inside the interpreter. The rule, established by testing every case:
///
/// | Parameter type in the patch          | Pass          |
/// |--------------------------------------|---------------|
/// | `int`, `double`, `bool` (non-null)   | raw value     |
/// | `int?`, `double?`, `bool?`           | wrapped       |
/// | `String`, `String?`                  | wrapped       |
/// | `num`, `Object`, any class           | wrapped       |
/// | `List`, `Map`                        | either works  |
///
/// Note the trap in the first two rows: making a parameter nullable flips how
/// it must be passed. Generated shims read the declared type and emit the right
/// form; [arg] applies the same rule at runtime for hand-written ones.
abstract final class MarinefordJson {
  /// Prepares [value] for a parameter whose declared type is *not* a
  /// non-nullable `int`, `double` or `bool`.
  ///
  /// Those three are the only types dart_eval unboxes, and they must be passed
  /// through untouched. Everything else goes through [wrap]. Use this when you
  /// are writing a shim by hand and do not want to memorise the table above.
  static Object? arg(Object? value) => wrap(value);

  /// Passes [value] through for a parameter declared as a non-nullable `int`,
  /// `double` or `bool`.
  ///
  /// Exists so hand-written shims can state which rule they are applying
  /// instead of leaving a bare value and a reader wondering whether wrapping
  /// was forgotten.
  static Object? unboxedArg(Object? value) => value;

  /// Wraps decoded JSON — maps, lists, strings, numbers, bools, null — into
  /// interpreter values.
  ///
  /// Anything not JSON-shaped is passed through untouched, so a bridged object
  /// mixed into a structure survives.
  static Object? wrap(Object? value) {
    if (value == null) return $null();
    if (value is String) return $String(value);
    if (value is int) return $int(value);
    if (value is double) return $double(value);
    if (value is bool) return $bool(value);
    if (value is List) {
      return $List.wrap(<Object?>[for (final item in value) wrap(item)]);
    }
    if (value is Map) {
      return $Map.wrap(<Object?, Object?>{
        for (final entry in value.entries) wrap(entry.key): wrap(entry.value),
      });
    }
    return value;
  }

  /// The inverse of [wrap]: turns interpreter values back into plain Dart.
  ///
  /// Needed on the return path too. A patch that hands back a rebuilt map — the
  /// response-normalizer pattern — returns interpreter values, and the app code
  /// downstream expects a real `Map<String, dynamic>`.
  ///
  /// Containers are descended into directly rather than through `$reified`.
  /// `$reified` is itself recursive, so going through it built the entire plain
  /// structure and then this walked the result and built it a second time —
  /// twice the allocations for one conversion. Measured at 68µs against 34µs
  /// for wrapping the same 50-row payload, an asymmetry with no reason to exist.
  /// The `$Value` branch still catches everything else, including a bridged
  /// object nested inside.
  static Object? unwrap(Object? value) {
    if (value is $Map) {
      return <Object?, Object?>{
        for (final entry in value.$value.entries)
          unwrap(entry.key): unwrap(entry.value),
      };
    }
    if (value is $List) {
      return <Object?>[for (final item in value.$value) unwrap(item)];
    }
    if (value is $Value) return unwrap(value.$reified);
    if (value is Map) {
      return <Object?, Object?>{
        for (final entry in value.entries)
          unwrap(entry.key): unwrap(entry.value),
      };
    }
    if (value is List) {
      return <Object?>[for (final item in value) unwrap(item)];
    }
    return value;
  }

  /// [unwrap], then cast to the shape JSON callers actually want.
  ///
  /// Returns null if the patch produced something that is not a map, which is a
  /// patch bug — the caller falls back rather than throwing a cast error deep
  /// inside unrelated code.
  static Map<String, dynamic>? unwrapMap(Object? value) {
    final plain = unwrap(value);
    if (plain is! Map) return null;
    return <String, dynamic>{
      for (final entry in plain.entries) '${entry.key}': entry.value,
    };
  }

  /// [unwrap], then cast to a list.
  ///
  /// Returns null if the patch produced something that is not a list.
  static List<dynamic>? unwrapList(Object? value) {
    final plain = unwrap(value);
    if (plain is! List) return null;
    return plain;
  }
}
