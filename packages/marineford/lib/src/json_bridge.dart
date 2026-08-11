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
    if (value is $Map) return _plainMap(value.$value);
    if (value is $List) return _plainList(value.$value);
    if (value is $Value) return unwrap(value.$reified);
    if (value is Map) return _plainMap(value);
    if (value is List) return _plainList(value);
    return value;
  }

  /// A decoded map, typed as precisely as its keys allow.
  ///
  /// `Map<String, dynamic>` whenever every key is a string, which is every JSON
  /// object. The precision is load-bearing rather than cosmetic: a shim
  /// converting to `List<Map<String, dynamic>>` tests each element with `is`,
  /// and `Map<Object?, Object?>` fails that test however string-keyed it
  /// happens to be — so a patch returning a list of JSON objects, the most
  /// ordinary response shape there is, was discarded as if it had returned
  /// garbage.
  static Object _plainMap(Map<Object?, Object?> source) {
    final typed = <String, dynamic>{};
    Map<Object?, Object?>? untyped;
    for (final entry in source.entries) {
      final key = unwrap(entry.key);
      final item = unwrap(entry.value);
      if (untyped != null) {
        untyped[key] = item;
      } else if (key is String) {
        typed[key] = item;
      } else {
        // One non-string key and the precise form is unavailable; carry over
        // what has been built rather than walking the entries twice.
        untyped = <Object?, Object?>{...typed, key: item};
      }
    }
    return untyped ?? typed;
  }

  /// A decoded list. `List<dynamic>` is as precise as this can be: the elements
  /// are only known one at a time, and the shim's own conversion is what
  /// applies the declared element type.
  static List<dynamic> _plainList(List<Object?> source) =>
      <dynamic>[for (final item in source) unwrap(item)];

  /// The shape JSON callers actually want, built in one pass.
  ///
  /// This is the return path of the flagship case — a normaliser sitting on an
  /// HTTP response — so it is worth not doing the work twice. Calling [unwrap]
  /// and then re-keying its result built the whole map once as an untyped map
  /// and immediately built it again as the typed one: two allocations and two
  /// rounds of hashing for one conversion, measured at 7.1µs against 3.4µs to
  /// wrap the same fifty-key payload on the way in. Descending into the
  /// interpreter's own map and emitting the target type directly halves it.
  ///
  /// Returns null if the patch produced something that is not a map, which is a
  /// patch bug — the caller falls back rather than throwing a cast error deep
  /// inside unrelated code.
  static Map<String, dynamic>? unwrapMap(Object? value) {
    final source = _mapView(value);
    if (source == null) return null;
    final (entries, needsUnwrap) = source;
    return <String, dynamic>{
      for (final entry in entries.entries)
        _stringKey(entry.key): needsUnwrap ? unwrap(entry.value) : entry.value,
    };
  }

  /// [unwrap] for a list, in one pass.
  ///
  /// Returns null if the patch produced something that is not a list.
  static List<dynamic>? unwrapList(Object? value) {
    final source = _listView(value);
    if (source == null) return null;
    final (items, needsUnwrap) = source;
    return <dynamic>[
      for (final item in items) needsUnwrap ? unwrap(item) : item,
    ];
  }

  /// [value] as a `Map<K, V>`, or null if the patch did not produce one.
  ///
  /// Null rather than a thrown cast, and that is the whole point. A patch that
  /// returns the wrong shape is a patch bug, and the shim's answer to a patch
  /// bug is to run the original function. A cast here would instead reach the
  /// caller as a `TypeError` — the one outcome dispatch promises never to
  /// produce from downloaded code.
  ///
  /// String keys keep the leniency [unwrapMap] has always had: a patch that
  /// used a number as a key still gets a usable map. Any other mismatch is a
  /// mismatch.
  static Map<K, V>? mapOf<K, V>(Object? value) {
    final source = _mapView(value);
    if (source == null) return null;
    final (entries, needsUnwrap) = source;
    final out = <K, V>{};
    for (final entry in entries.entries) {
      final key = needsUnwrap ? unwrap(entry.key) : entry.key;
      final item = needsUnwrap ? unwrap(entry.value) : entry.value;
      if (item is! V) return null;
      if (key is K) {
        out[key] = item;
      } else if (K == String) {
        out['$key' as K] = item;
      } else {
        return null;
      }
    }
    return out;
  }

  /// [value] as a `List<E>`, or null if the patch did not produce one.
  ///
  /// See [mapOf] for why this returns null instead of casting.
  static List<E>? listOf<E>(Object? value) {
    final source = _listView(value);
    if (source == null) return null;
    final (items, needsUnwrap) = source;
    final out = <E>[];
    for (final item in items) {
      final element = needsUnwrap ? unwrap(item) : item;
      if (element is! E) return null;
      out.add(element);
    }
    return out;
  }

  /// [value] as a `Set<E>`, or null if the patch did not produce one.
  ///
  /// Interpreted collections arrive as lists, so a declared `Set` return needs
  /// building rather than casting — a list is never a set, whatever its
  /// element type. Built in one pass: routing through [listOf] would allocate
  /// the collection twice on a path that is already the expensive half of a
  /// dispatched call.
  static Set<E>? setOf<E>(Object? value) {
    final source = _listView(value);
    if (source == null) return null;
    final (items, needsUnwrap) = source;
    final out = <E>{};
    for (final item in items) {
      final element = needsUnwrap ? unwrap(item) : item;
      if (element is! E) return null;
      out.add(element);
    }
    return out;
  }

  /// [value] as a `T`, or null if the patch produced something else.
  ///
  /// The scalar counterpart of [mapOf]. It still goes through [unwrap], because
  /// what arrives may be an interpreter value rather than a reified one; for a
  /// scalar that is a passthrough.
  static T? valueOf<T>(Object? value) {
    final plain = unwrap(value);
    return plain is T ? plain : null;
  }

  /// The map inside [value] without copying it, or null if there is not one.
  ///
  /// The point is to reach the entries without materialising an intermediate
  /// map that is thrown away one line later. The flag says whether the entries
  /// still hold interpreter values: the fallback branch has already unwrapped
  /// them, and unwrapping a second time would rebuild every nested container
  /// underneath for nothing.
  static (Map<Object?, Object?>, bool)? _mapView(Object? value) {
    if (value is $Map) return (value.$value, true);
    if (value is Map) return (value, true);
    // Anything else that might still be a map — a bridged type, a $Value that
    // is not $Map — cannot be inspected without converting it first. That path
    // pays the copy the fast one avoids, which is the right trade: it is rare,
    // and the alternative is special-casing every $Value subtype dart_eval has.
    final plain = unwrap(value);
    return plain is Map ? (plain, false) : null;
  }

  /// The list inside [value] without copying it, or null if there is not one.
  ///
  /// See [_mapView] for what the flag means.
  static (List<Object?>, bool)? _listView(Object? value) {
    if (value is $List) return (value.$value, true);
    if (value is List) return (value, true);
    final plain = unwrap(value);
    return plain is List ? (plain, false) : null;
  }

  /// A JSON object key as a string.
  ///
  /// Keys arrive as `$String` and unwrap to real strings, so the common case is
  /// a plain return. A patch that used a number as a key still gets a usable
  /// map rather than a cast error.
  static String _stringKey(Object? key) {
    final plain = unwrap(key);
    return plain is String ? plain : '$plain';
  }
}
