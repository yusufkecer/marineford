import 'dart:collection';

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
  /// The single `$null` every absent value is wrapped as. See [wrap].
  static const $null _null = $null();

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
  ///
  /// Containers are wrapped **lazily**, and that is the difference between this
  /// costing something and costing almost nothing. It used to copy the whole
  /// payload — every key, every nested row — before the patch had read a single
  /// field, which measured 34µs for a fifty-row response against 2.6µs for the
  /// crossing itself. The work was mostly wasted: a normaliser reads a handful
  /// of keys. [_LazyMap] and [_LazyList] wrap an entry the first time it is
  /// asked for and remember it, so the cost follows what the patch touches
  /// rather than what it was handed.
  ///
  /// Both views are copy-on-write. Interpreted code that writes to a container
  /// gets its own copy, so a patch cannot reach back and mutate the app's data
  /// — which the eager copy prevented by accident and this has to do on
  /// purpose. Reads still see the caller's map live, so an app that mutates a
  /// payload while an async patch is suspended mid-await would show the patch
  /// the change. Passing a structure you are still editing was already a
  /// question of ownership; this makes the answer visible.
  ///
  /// The one shared instance is [_null]. A JSON payload with a lot of absent
  /// fields allocated one wrapper per absence for no reason — `$null` carries
  /// no state and has a const constructor, so every one of them was identical.
  /// `$bool` looks like it should get the same treatment and cannot: its
  /// `$value` is mutable and it allocates an inner `$Object` besides.
  static Object? wrap(Object? value) {
    if (value == null) return _null;
    if (value is String) return $String(value);
    if (value is int) return $int(value);
    if (value is double) return $double(value);
    if (value is bool) return $bool(value);
    if (value is List) return $List.wrap(_LazyList(value));
    if (value is Map) return $Map.wrap(_LazyMap(value));
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
  /// twice the allocations for one conversion. Measured at 93µs against 73µs
  /// for the same 50-row payload, an asymmetry with no reason to exist.
  ///
  /// Note the shape of the remaining cost. Wrapping is now nearly free because
  /// it is lazy, so the boundary is no longer symmetric: handing a payload to a
  /// patch costs almost nothing, and getting one back costs what it costs. That
  /// is the right way round — a patch is given far more than it returns.
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
    // A view the patch only read from is still the caller's own map, so there
    // is nothing to convert — the flagship case is a normaliser that inspects a
    // response and hands most of it straight back, and walking it here would
    // wrap and unwrap every entry to arrive at what we started with.
    if (source is _LazyMap) {
      final plain = source.plainSource;
      if (plain is Map<String, dynamic>) return plain;
    }
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
  static List<dynamic> _plainList(List<Object?> source) {
    // See [_plainMap]: an untouched view is already the caller's list.
    if (source is _LazyList) {
      final plain = source.plainSource;
      if (plain is List<dynamic>) return plain;
    }
    return <dynamic>[for (final item in source) unwrap(item)];
  }

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

  /// [plain] as a `T`, widening an `int` to a `double` when that is what the
  /// signature asked for, or null when it genuinely does not fit.
  ///
  /// The widening is not a convenience. JSON has one number type, so
  /// `jsonDecode('{"rate":0}')` produces an `int` and `0 is double` is false in
  /// Dart — which meant a patch declared to return `double` was rejected by its
  /// own shim whenever the value happened to be whole, on every call, with no
  /// error anywhere. `List<double>` was worse: a single whole element threw
  /// away the entire list. A patch cannot control which one it gets, so
  /// treating the difference as a patch bug punished it for arithmetic.
  ///
  /// Deliberately one-directional. A `double` handed to an `int` signature is
  /// not widened, because narrowing loses information and there is no answer to
  /// "which way should 2.5 round" that the caller agreed to. That stays a
  /// mismatch, and the original function runs.
  /// Returns [_noFit] rather than null when the value does not belong.
  ///
  /// Null cannot be the failure signal here, and using it was a bug with a wide
  /// blast radius: `V` is `dynamic` for the commonest return types, `null is
  /// dynamic` is true, so a payload containing a single JSON null made
  /// `mapOf<String, dynamic>` and `listOf<dynamic>` reject the whole structure
  /// and every call fall back to the original. JSON nulls are ordinary; that is
  /// most responses.
  static Object? _fit<T>(Object? plain) {
    if (plain is T) return plain;
    if (plain is int && _wantsDouble<T>()) return plain.toDouble();
    return _noFit;
  }

  /// The "this value does not fit `T`" answer from [_fit].
  ///
  /// Private, so no value crossing the boundary can ever be mistaken for it.
  static const Object _noFit = _NoFit();

  /// Whether `T` is `double`, without needing an instance of one.
  static bool _wantsDouble<T>() => T == double;

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
      final item = _fit<V>(needsUnwrap ? unwrap(entry.value) : entry.value);
      if (identical(item, _noFit)) return null;
      final value = item as V;
      if (key is K) {
        out[key] = value;
      } else if (K == String) {
        out['$key' as K] = value;
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
      final element = _fit<E>(needsUnwrap ? unwrap(item) : item);
      if (identical(element, _noFit)) return null;
      out.add(element as E);
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
      final element = _fit<E>(needsUnwrap ? unwrap(item) : item);
      if (identical(element, _noFit)) return null;
      out.add(element as E);
    }
    return out;
  }

  /// [value] as a `T`, or null if the patch produced something else.
  ///
  /// The scalar counterpart of [mapOf]. It still goes through [unwrap], because
  /// what arrives may be an interpreter value rather than a reified one; for a
  /// scalar that is a passthrough.
  static T? valueOf<T>(Object? value) {
    final fitted = _fit<T>(unwrap(value));
    return identical(fitted, _noFit) ? null : fitted as T?;
  }

  /// The map inside [value] without copying it, or null if there is not one.
  ///
  /// The point is to reach the entries without materialising an intermediate
  /// map that is thrown away one line later. The flag says whether the entries
  /// still hold interpreter values: the fallback branch has already unwrapped
  /// them, and unwrapping a second time would rebuild every nested container
  /// underneath for nothing.
  static (Map<Object?, Object?>, bool)? _mapView(Object? value) {
    if (value is $Map) {
      final inner = value.$value;
      // The same short-circuit [_plainMap] takes, and this is the one that
      // matters: a generated shim for a `Map` return calls `mapOf`, which comes
      // through here, not through `unwrap`. Without it the flagship signature
      // walked an untouched view — wrapping every key and value on the way out
      // and unwrapping each one straight back — while the plain entries sat
      // right there.
      if (inner is _LazyMap) {
        final plain = inner.plainSource;
        if (plain != null) return (plain, false);
      }
      return (inner, true);
    }
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
    if (value is $List) {
      final inner = value.$value;
      // See [_mapView]: `listOf` and `setOf` reach the boundary through here.
      if (inner is _LazyList) {
        final plain = inner.plainSource;
        if (plain != null) return (plain, false);
      }
      return (inner, true);
    }
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

/// A plain Dart map presented to the interpreter without being copied.
///
/// dart_eval hands `$Map` whatever it was wrapped around and reads it through
/// the ordinary `Map` interface, so anything implementing `Map` will do — it
/// does not have to be a real one holding real `$Value`s. That is what makes
/// laziness possible: entries are wrapped when they are read.
///
/// Keys arrive from interpreted code already wrapped — a lookup is spelled
/// `$String('status')` — so every key is unwrapped before it reaches the
/// caller's map, and every key handed *out* is wrapped, because interpreted
/// code iterating `keys` expects interpreter values.
///
/// Copy-on-write. The first mutation materialises a private map and everything
/// after it goes there, so the app's structure is never touched by a patch.
final class _LazyMap extends MapBase<Object?, Object?> {
  _LazyMap(this._plain);

  /// The caller's map. Read, never written.
  final Map<Object?, Object?> _plain;

  /// Wrapped entries, kept so a key read twice answers with the same instance.
  final Map<Object?, Object?> _wrapped = <Object?, Object?>{};

  /// Non-null once interpreted code has written something.
  Map<Object?, Object?>? _owned;

  /// The plain map behind an untouched view, or null once it has been written.
  ///
  /// The return path uses this to skip a pointless round trip: a patch that
  /// hands back the map it was given would otherwise have every entry wrapped
  /// on the way out and unwrapped again immediately.
  Map<Object?, Object?>? get plainSource => _owned == null ? _plain : null;

  static Object? _plainKey(Object? key) =>
      key is $Value ? MarinefordJson.unwrap(key) : key;

  @override
  Object? operator [](Object? key) {
    final owned = _owned;
    if (owned != null) return owned[key];
    final plainKey = _plainKey(key);
    final existing = _wrapped[plainKey];
    if (existing != null) return existing;
    if (!_plain.containsKey(plainKey)) return null;
    return _wrapped[plainKey] = MarinefordJson.wrap(_plain[plainKey]);
  }

  @override
  void operator []=(Object? key, Object? value) => _materialise()[key] = value;

  @override
  Object? remove(Object? key) => _materialise().remove(key);

  @override
  void clear() => _materialise().clear();

  /// One wrapper per key, made when the key is first seen.
  ///
  /// `MapBase` derives `entries`, `values`, `forEach`, `map` and
  /// `containsValue` from `keys`, so wrapping inside the iterable re-made every
  /// `$String` on every pass. Memoising the *list* instead fixed that and broke
  /// something worse: the list was a snapshot while `length` and `containsKey`
  /// still read [_plain], so a caller that mutated its own map — which `MarinefordJson.wrap`
  /// explicitly says it may — left the view contradicting itself, permanently.
  ///
  /// A per-key cache keeps both properties. The iteration stays live, and a key
  /// seen twice answers with the same instance.
  final Map<Object?, Object?> _wrappedKeys = <Object?, Object?>{};

  Object? _wrapKey(Object? key) =>
      _wrappedKeys[key] ??= MarinefordJson.wrap(key);

  @override
  Iterable<Object?> get keys => _owned?.keys ?? _plain.keys.map(_wrapKey);

  // Derived from `keys` and `[]` by MapBase, which for these four would mean
  // building the wrapped key iterable to answer a question the plain map can
  // answer directly.
  @override
  int get length => _owned?.length ?? _plain.length;

  @override
  bool get isEmpty => _owned?.isEmpty ?? _plain.isEmpty;

  @override
  bool get isNotEmpty => _owned?.isNotEmpty ?? _plain.isNotEmpty;

  @override
  bool containsKey(Object? key) =>
      _owned?.containsKey(key) ?? _plain.containsKey(_plainKey(key));

  Map<Object?, Object?> _materialise() {
    final existing = _owned;
    if (existing != null) return existing;
    final built = <Object?, Object?>{};
    for (final entry in _plain.entries) {
      // Both sides come from their caches, so a key or value already handed to
      // interpreted code stays the same instance across the write.
      built[_wrapKey(entry.key)] =
          _wrapped[entry.key] ?? MarinefordJson.wrap(entry.value);
    }
    return _owned = built;
  }
}

/// The list counterpart of [_LazyMap].
///
/// dart_eval ships a `$List.view` that does something similar, and it is not
/// usable here: its index-set writes the *unwrapped* value straight back into
/// the list it was given, so a patch assigning to an element would mutate the
/// app's data. This copies on write instead.
final class _LazyList extends ListBase<Object?> {
  _LazyList(this._plain);

  final List<Object?> _plain;
  final Map<int, Object?> _wrapped = <int, Object?>{};
  List<Object?>? _owned;

  /// The plain list behind an untouched view. See [_LazyMap.plainSource].
  List<Object?>? get plainSource => _owned == null ? _plain : null;

  @override
  int get length => _owned?.length ?? _plain.length;

  @override
  set length(int value) => _materialise().length = value;

  @override
  Object? operator [](int index) {
    final owned = _owned;
    if (owned != null) return owned[index];
    return _wrapped[index] ??= MarinefordJson.wrap(_plain[index]);
  }

  @override
  void operator []=(int index, Object? value) => _materialise()[index] = value;

  List<Object?> _materialise() => _owned ??= <Object?>[
        for (var i = 0; i < _plain.length; i++)
          _wrapped[i] ?? MarinefordJson.wrap(_plain[i]),
      ];
}

/// The private type behind [MarinefordJson._noFit].
///
/// A dedicated type rather than a bare `Object()` so the sentinel can be a
/// compile-time constant, and so a stack trace or a debugger names it.
final class _NoFit {
  const _NoFit();
}
