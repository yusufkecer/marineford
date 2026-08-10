import 'package:dart_eval/dart_eval.dart';

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
/// Nothing here is a hard error, because every one of these is a judgement call
/// the developer is better placed to make — but silence would be worse, since
/// all of them are invisible until a user feels them.
final class PatchLinter {
  /// Creates a [PatchLinter] for [project].
  const PatchLinter(this.project);

  /// The project being linted.
  final MarinefordProject project;

  /// Iterations above which an interpreted loop starts to cost real time.
  ///
  /// An interpreted loop iteration measured ~107ns, so 1000 iterations is
  /// ~107µs — about 0.6% of a 60fps frame for a single call. Ten thousand is
  /// over a millisecond and worth mentioning.
  static const int loopIterationBudget = 1000;

  static final _loopBound = RegExp(r'<\s*(\d{4,})\s*;');
  static final _overrideId =
      RegExp(r'''@RuntimeOverride\s*\(\s*['"]([^'"]+)['"]''');
  static final _overrideWithoutVersion =
      RegExp(r'''@RuntimeOverride\s*\(\s*['"][^'"]+['"]\s*\)''');

  /// Runs every check and returns what it found.
  List<LintFinding> run({
    required Map<String, String> sources,
    required Program program,
    Set<String>? knownIds,
  }) {
    final findings = <LintFinding>[];
    final declared = <String>{};

    sources.forEach((path, source) {
      for (final match in _overrideId.allMatches(source)) {
        declared.add(match.group(1)!);
      }

      if (_overrideWithoutVersion.hasMatch(source)) {
        findings.add(const LintFinding(
          LintSeverity.warning,
          'an @RuntimeOverride has no `version:` constraint',
          hint: 'Without one, dart_eval defaults the constraint to its own '
              'version, which no app will ever satisfy — so the override '
              'silently never fires. Always pass an explicit version range.',
        ));
      }

      for (final match in _loopBound.allMatches(source)) {
        final iterations = int.tryParse(match.group(1)!) ?? 0;
        if (iterations > loopIterationBudget) {
          findings.add(LintFinding(
            LintSeverity.warning,
            '$path loops about $iterations times inside the patch',
            hint: 'Interpreted iterations cost roughly 107ns each, so this is '
                'around ${(iterations * 107 / 1000).round()}µs per call. Move '
                'the loop into your compiled code and patch only the decision '
                'it makes.',
          ));
        }
      }
    });

    if (knownIds != null) {
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
      final unpatched = knownIds.difference(declared);
      if (declared.isNotEmpty && unpatched.length == knownIds.length) {
        findings.add(const LintFinding(
          LintSeverity.warning,
          'this patch overrides nothing the app declares',
          hint: 'Every id in the patch is unknown to the app. That usually '
              'means the app and the patch were built from different '
              'revisions.',
        ));
      }
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
