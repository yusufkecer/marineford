/// Annotations for marineford.
///
/// This package has no dependencies on purpose: your application depends on it
/// to *mark* patchable code, and your patch package depends on it to *provide*
/// replacements. Neither should have to pull in a runtime or a code generator
/// to do so.
library;

import 'package:meta/meta_meta.dart';

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
/// patch is active a marked call measures a few nanoseconds against a direct
/// one. Mark liberally — but never inside a hot loop or per-frame code, where
/// the microseconds it costs to actually cross into the interpreter would show
/// up.
///
/// Code that was not marked before it shipped can never be patched. See
/// [PatchableService] for marking a whole class at once.
///
/// Restricted to top-level functions by [Target]. Putting it on a class or a
/// method used to generate nothing at all and say nothing about it — the most
/// natural mistake there is, with total silence as its result.
@Target(<TargetKind>{TargetKind.function})
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

/// Marks every public instance method of a class as replaceable by a patch.
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
/// Only methods declared on the annotated class are covered — not inherited
/// ones, and not getters or setters. The generated class forwards whatever
/// constructors the base declares, so a service that takes dependencies works
/// unchanged.
///
/// A patch that replaces one of these methods rewrites the whole body, so it
/// can also repair bugs in the unmarked private helpers that method calls — it
/// simply stops calling them. That makes a service class a good boundary: you
/// do not have to predict which leaf function will break, only which entry
/// point sits above it.
@Target(<TargetKind>{TargetKind.classType})
final class PatchableService {
  /// Creates a [PatchableService] annotation.
  const PatchableService({this.name, this.exclude = const <String>[]});

  /// Overrides the generated class name.
  ///
  /// By default a trailing `Base` is stripped, so `PricingRulesBase` generates
  /// `PricingRules`.
  final String? name;

  /// Method names to leave unmarked.
  ///
  /// Use for hot paths that should never pay the dispatch check. A name here
  /// that matches no method is a build error rather than a silent no-op: an
  /// excluded-but-misspelled hot path is marked, which is the opposite of what
  /// was asked for.
  final List<String> exclude;
}

/// Declares a replacement for a marked function, inside a patch package.
///
/// The [id] must match one of the ids in the application's generated id
/// registry; `marineford doctor` verifies this before you publish.
///
/// [version] is a pub_semver constraint checked against the running app's
/// version. It is effectively required: leave it out and dart_eval substitutes
/// a constraint on *its own* version, which no app satisfies, so the override
/// compiles, publishes and silently never fires. `marineford build` warns.
///
/// ```dart
/// @RuntimeOverride('pkg:app/lib/pricing.dart#PricingRules.cartTotal',
///     version: '>=1.4.0 <1.5.0')
/// int cartTotalFixed(Cart cart) => 0;
/// ```
///
/// The class name is significant: dart_eval's compiler matches this annotation
/// by identifier, so it cannot be renamed or aliased. It is also deliberately
/// *not* restricted by [Target] — the patch package is compiled by dart_eval,
/// not by the Dart SDK, and the analyzer never sees it.
final class RuntimeOverride {
  /// Creates a [RuntimeOverride] annotation.
  const RuntimeOverride(this.id, {this.version});

  /// Dispatch id of the marked function this replaces.
  final String id;

  /// pub_semver constraint on the app version this replacement applies to.
  final String? version;
}
