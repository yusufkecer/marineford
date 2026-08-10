/// Annotations for marineford.
///
/// This package has no dependencies on purpose: your application depends on it
/// to *mark* patchable code, and your patch package depends on it to *provide*
/// replacements. Neither should have to pull in a runtime or a code generator
/// to do so.
library;

/// Marks a top-level function as replaceable by a patch at runtime.
///
/// The generator emits a public wrapper that dispatches to a patch when one is
/// active and falls back to the original body otherwise. Name the annotated
/// function with a leading underscore; the generated wrapper takes the public
/// name:
///
/// ```dart
/// part 'discount.marineford.dart';
///
/// @patchable
/// int _applyDiscount(int total, int units) => total;
/// // generated: int applyDiscount(int total, int units) { ... }
/// ```
///
/// Marking is not free of consequence but is close to free of cost: when no
/// patch is active a marked call measures ~2.4ns against ~1.7ns unmarked. Mark
/// liberally — but never inside a hot loop or per-frame code, where the ~2.5µs
/// cost of actually crossing into the interpreter would show up.
///
/// Code that was not marked before it shipped can never be patched. See
/// [PatchableService] for marking a whole class at once.
final class Patchable {
  /// Creates a [Patchable] annotation.
  const Patchable({this.id});

  /// Overrides the generated dispatch id.
  ///
  /// By default the id is derived from the library URI and the function name,
  /// which is stable across refactors of the body but not across renames. Set
  /// this explicitly when you need the id to survive a rename.
  final String? id;
}

/// Marks a top-level function as replaceable by a patch at runtime.
///
/// Shorthand for `Patchable()`.
const patchable = Patchable();

/// Marks every public method of a class as replaceable by a patch.
///
/// The generator emits a subclass whose overrides dispatch to a patch when one
/// is active. Annotate a base class and use the generated subclass at your call
/// sites:
///
/// ```dart
/// part 'pricing.marineford.dart';
///
/// @PatchableService()
/// class PricingRulesBase {
///   int cartTotal(Cart cart) => 0;
/// }
/// // generated: class PricingRules extends PricingRulesBase { ... }
/// ```
///
/// A patch that replaces one of these methods rewrites the whole body, so it
/// can also repair bugs in the unmarked private helpers that method calls — it
/// simply stops calling them. That makes a service class a good boundary: you
/// do not have to predict which leaf function will break, only which entry
/// point sits above it.
final class PatchableService {
  /// Creates a [PatchableService] annotation.
  const PatchableService({this.name, this.exclude = const []});

  /// Overrides the generated class name prefix used to build dispatch ids.
  final String? name;

  /// Method names to leave unmarked.
  ///
  /// Use for hot paths that should never pay the dispatch check.
  final List<String> exclude;
}

/// Declares a replacement for a marked function, inside a patch package.
///
/// The [id] must match one of the ids in the application's generated id
/// registry; `marineford doctor` verifies this before you publish.
///
/// [version] is a pub_semver constraint checked against the running app's
/// version. Use it to retire a patch automatically once a store release ships
/// the same fix natively:
///
/// ```dart
/// @RuntimeOverride('pkg:app/pricing.dart#PricingRules.cartTotal',
///     version: '>=1.4.0 <1.5.0')
/// int cartTotalFixed(Cart cart) => 0;
/// ```
///
/// The class name is significant: dart_eval's compiler matches this annotation
/// by identifier, so it cannot be renamed or aliased.
// ignore: camel_case_types
final class RuntimeOverride {
  /// Creates a [RuntimeOverride] annotation.
  const RuntimeOverride(this.id, {this.version});

  /// Dispatch id of the marked function this replaces.
  final String id;

  /// pub_semver constraint on the app version this replacement applies to.
  final String? version;
}
