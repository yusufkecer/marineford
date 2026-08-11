import 'package:dart_eval/dart_eval.dart';
import 'package:pub_semver/pub_semver.dart';

import 'config.dart';

/// How much a lint finding should worry you.
enum LintSeverity {
  /// Worth knowing. The patch will work.
  info,

  /// Likely to cause a problem in the field.
  warning,
}

/// One thing the linter noticed.
final class LintFinding {
  /// Creates a [LintFinding].
  const LintFinding(this.severity, this.message, {this.hint});

  /// How much it matters.
  final LintSeverity severity;

  /// What was noticed.
  final String message;

  /// What to do about it.
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message — $hint';
}

/// Checks a compiled patch against the things measurement says go wrong.
///
/// The compiler already rejects code dart_eval cannot run. The linter covers
/// the other category: code that compiles, loads and then behaves badly.
///
/// Every check that can run against the *compiled program* does, rather than
/// against the source text. The version-constraint check is the reason: source
/// matching has to guess at formatting, and it guessed wrong — a long override
/// id makes `dart format` wrap the annotation across lines with a trailing
/// comma, which the pattern did not match, so the single most consequential
/// mistake a patch author can make went unreported. The compiler has already
/// resolved every constraint into `overrideMap`; reading it there cannot be
/// fooled by whitespace.
final class PatchLinter {
  /// Creates a [PatchLinter] for [project].
  const PatchLinter(this.project);

  /// The project being linted.
  final MarinefordProject project;

  /// Iterations above which an interpreted loop starts to cost real time.
  ///
  /// An interpreted loop iteration measured ~110ns, so 1000 iterations is
  /// ~110µs — about 0.7% of a 60fps frame for a single call.
  static const int loopIterationBudget = 1000;

  /// Matches any numeric loop bound, not just four-digit ones.
  static final _loopBound = RegExp(r'<=?\s*(\d+)\s*;');

  /// Runs every check and returns what it found.
  List<LintFinding> run({
    required Map<String, String> sources,
    required Program program,
    required Version appVersionMin,
    Set<String>? knownIds,
  }) {
    final findings = <LintFinding>[
      ..._checkConstraints(program, appVersionMin),
      ..._checkLoops(sources),
    ];
    if (knownIds != null) {
      findings.addAll(_checkIds(program, knownIds));
    }
    return findings;
  }

  /// Reads the constraints the compiler actually recorded.
  ///
  /// An `@RuntimeOverride` with no `version:` does not get "no constraint" — it
  /// gets dart_eval's own default, which is a constraint on the *compiler's*
  /// version and reads as the literal `<null` when that is unset. It then fails
  /// to parse at load time and the override is dropped in silence. A patch like
  /// that compiles, publishes and does nothing.
  Iterable<LintFinding> _checkConstraints(Program program, Version appMin) {
    final findings = <LintFinding>[];
    program.overrideMap.forEach((id, spec) {
      final constraint = spec.versionConstraint;
      if (constraint == null) return;

      final VersionConstraint parsed;
      try {
        parsed = VersionConstraint.parse(constraint);
      } on FormatException {
        findings.add(LintFinding(
          LintSeverity.warning,
          'override "$id" has no usable version constraint '
          '(dart_eval recorded "$constraint")',
          hint: 'Pass an explicit `version:` to @RuntimeOverride. Without one '
              'dart_eval substitutes its own version, the constraint fails to '
              'parse on the device, and the override silently never fires.',
        ));
        return;
      }

      if (!parsed.allows(appMin)) {
        findings.add(LintFinding(
          LintSeverity.warning,
          'override "$id" requires $parsed, which excludes the lowest app '
          'version you are publishing for ($appMin)',
          hint: 'Devices on $appMin will download this patch and then ignore '
              'this override. Widen the constraint or narrow the publish '
              'range.',
        ));
      }
    });
    return findings;
  }

  Iterable<LintFinding> _checkLoops(Map<String, String> sources) {
    final findings = <LintFinding>[];
    sources.forEach((path, source) {
      for (final match in _loopBound.allMatches(source)) {
        final iterations = int.tryParse(match.group(1)!) ?? 0;
        if (iterations > loopIterationBudget) {
          findings.add(LintFinding(
            LintSeverity.warning,
            '$path loops about $iterations times inside the patch',
            hint: 'Interpreted iterations cost roughly 110ns each, so this is '
                'around ${(iterations * 110 / 1000).round()}µs per call. Move '
                'the loop into your compiled code and patch only the decision '
                'it makes.',
          ));
        }
      }
    });
    return findings;
  }

  Iterable<LintFinding> _checkIds(Program program, Set<String> knownIds) {
    final findings = <LintFinding>[];
    final declared = program.overrideMap.keys.toSet();

    for (final id in declared) {
      if (!knownIds.contains(id)) {
        findings.add(LintFinding(
          LintSeverity.warning,
          'override id "$id" does not exist in the app',
          hint: 'Nothing will call it. Check the spelling against '
              'marineford_ids.json, or rebuild the app so the registry is '
              'current.',
        ));
      }
    }

    if (declared.isNotEmpty && declared.intersection(knownIds).isEmpty) {
      findings.add(const LintFinding(
        LintSeverity.warning,
        'this patch overrides nothing the app declares',
        hint: 'Every id in the patch is unknown to the app. That usually means '
            'the app and the patch were built from different revisions.',
      ));
    }
    return findings;
  }

  /// Checks the packed size against the project's budget.
  LintFinding? checkSize(int compressedBytes) {
    if (compressedBytes <= project.sizeBudgetBytes) return null;
    return LintFinding(
      LintSeverity.warning,
      'the packed patch is ${(compressedBytes / 1024).toStringAsFixed(1)} KB, '
      'over the ${(project.sizeBudgetBytes / 1024).round()} KB budget',
      hint: 'Large patches take longer to download on the networks that need '
          'them most. Raise `size_budget_kb` in marineford.yaml if this is '
          'expected.',
    );
  }
}
