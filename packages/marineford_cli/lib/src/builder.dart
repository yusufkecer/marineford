import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:marineford_core/marineford_core.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'config.dart';
import 'flutter_bridge.dart';
import 'lint.dart';

/// The result of compiling and packing a patch.
final class BuiltPatch {
  /// Creates a [BuiltPatch].
  const BuiltPatch({
    required this.bytes,
    required this.overrideIds,
    required this.rawSize,
    required this.compressedSize,
    required this.warnings,
  });

  /// The complete signed `.mfp`.
  final Uint8List bytes;

  /// Dispatch ids the patch overrides.
  final List<String> overrideIds;

  /// Size of the compiled bytecode before compression.
  final int rawSize;

  /// Size of the compressed payload.
  final int compressedSize;

  /// Lint findings, none of which stopped the build.
  final List<LintFinding> warnings;
}

/// Compiles a patch package and packs it into a signed container.
///
/// Compilation happens here, on the developer's machine, and that is the point:
/// every dart_eval limitation — an unsupported language feature, a compiler
/// crash, a typo in an override id — surfaces as a build failure in front of
/// someone who can fix it, instead of as silence on a user's phone.
final class PatchBuilder {
  /// Creates a [PatchBuilder] for [project].
  const PatchBuilder(this.project);

  /// The project being built.
  final MarinefordProject project;

  /// Compiles, lints, compresses and signs the patch package.
  Future<BuiltPatch> build({
    required PatchSigner signer,
    required AbiFingerprint abi,
    required Version appVersionMin,
    Set<String>? knownIds,
  }) async {
    final sources = _collectSources();
    if (sources.isEmpty) {
      throw CliException(
        'no Dart files found in ${project.patchPackage}/lib',
        hint: 'A patch package needs at least one file with an '
            '@RuntimeOverride function.',
      );
    }

    _rejectPlatformImports(sources);
    _rejectCatchAroundAwait(sources);

    final compiler = Compiler();
    // Only for a patch that asks for it. Unpacking and registering flutter_eval
    // costs 800 KB of JSON and 185 declarations, and a patch that repairs a
    // JSON contract should not pay for a feature it does not use.
    if (usesFlutter(sources)) registerFlutterBridges(compiler);

    final Program program;
    try {
      program = compiler.compile(<String, Map<String, String>>{
        'patch': sources,
      });
    } on Object catch (e) {
      // dart_eval reports most problems as a CompileError naming the offending
      // construct, but on some statement combinations its compiler crashes
      // outright with a RangeError instead. Both reach a developer here, at
      // build time, and both deserve a sentence they can act on rather than a
      // stack trace.
      final text = e.toString();
      final crashed = e is RangeError || e is StateError;
      throw CliException(
        crashed
            ? 'the dart_eval compiler crashed on this patch:\n$text'
            : 'the patch did not compile:\n$text',
        hint: crashed
            ? 'This is a dart_eval bug rather than a mistake in your code, and '
                'it is sensitive to how much a single function does. Split the '
                'largest function in the patch into smaller ones. Keeping '
                'patch functions small is good practice anyway — crossing into '
                'the interpreter costs about 2.5µs per call.'
            : _compileHint(text),
      );
    }

    final overrideIds = program.overrideMap.keys.toList()..sort();
    if (overrideIds.isEmpty) {
      throw const CliException(
        'the patch compiled but declares no @RuntimeOverride functions',
        hint: 'A patch with no overrides changes nothing. Annotate the '
            'functions that should replace the app\'s own.',
      );
    }

    final warnings = PatchLinter(project).run(
      sources: sources,
      program: program,
      appVersionMin: appVersionMin,
      knownIds: knownIds,
    );

    final evc = program.write();
    final payload = Uint8List.fromList(gzip.encode(evc));

    final region = MfpContainer.buildSignedRegion(payload: payload, abi: abi);
    final signature = await signer.sign(region);

    return BuiltPatch(
      bytes: Uint8List.fromList(<int>[...region, ...signature]),
      overrideIds: overrideIds,
      rawSize: evc.length,
      compressedSize: payload.length,
      warnings: warnings,
    );
  }

  Map<String, String> _collectSources() {
    final lib =
        Directory(p.join(project.root.path, project.patchPackage, 'lib'));
    if (!lib.existsSync()) return const <String, String>{};
    final sources = <String, String>{};
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final relative = p.relative(entity.path, from: lib.path);
      sources[p.split(relative).join('/')] = entity.readAsStringSync();
    }
    return sources;
  }

  /// Whole words, not substrings.
  ///
  /// Matching `late` anywhere in the message fires on "translate", "related"
  /// and "latency", and tells the developer their code uses a keyword it does
  /// not. A wrong explanation is worse than none: it sends them looking in the
  /// wrong place.
  static final Map<RegExp, String> _unsupported = <RegExp, String>{
    RegExp(r'\bmixins?\b'): 'dart_eval does not support mixins.',
    RegExp(r'\bextension\b'): 'dart_eval does not support extension methods.',
    RegExp(r'\b(yield|sync\*|async\*)\b'):
        'dart_eval does not support generators (sync* / async*).',
    RegExp(r'\blate\b'): 'dart_eval does not support `late`.',
    RegExp(r'\btypedefs?\b'): 'dart_eval does not support typedefs.',
    RegExp(r'\bdeferred\b'): 'dart_eval does not support deferred imports.',
    RegExp(r'\bisolates?\b'): 'dart_eval does not support isolates.',
  };

  static String _compileHint(String error) {
    for (final entry in _unsupported.entries) {
      if (entry.key.hasMatch(error)) {
        return '${entry.value} Rewrite that part of the patch without it; the '
            'rest of the file is fine.';
      }
    }
    return 'Patch code runs on dart_eval, which implements most but not all '
        'of Dart. Unsupported: mixins, extension methods, generators, '
        'typedefs, `late`, deferred imports, isolates.';
  }
}

/// Directives that pull in a platform library, ignoring comments and strings.
///
/// Anchored to the start of a line and to the `import`/`export` keyword,
/// because that is where a directive has to be — Dart requires them before any
/// declaration.
final RegExp _platformImport = RegExp(
  r'''^\s*(?:import|export)\s+['"](dart:(?:io|ffi|isolate|mirrors))['"]''',
  multiLine: true,
);

/// A `try` block, taken as far as the `on`/`catch`/`finally` that ends it.
///
/// Approximate by construction — a regex cannot balance braces — but it only
/// has to be good enough to notice an `await` sitting inside one.
final RegExp _tryBlock = RegExp(
  r'\btry\s*\{(.*?)\}\s*(?:on\b|catch\b|finally\b)',
  dotAll: true,
);

/// Refuses a patch that imports a platform library.
///
/// marineford grants a patch no permissions at all, so every one of these calls
/// either throws at runtime or, for the handful dart_eval forgot to gate, is
/// refused by marineford's own sandbox. Either way the code is dead. Letting it
/// compile means shipping a patch that silently does not do what it says, which
/// is the single worst outcome for a system whose entire job is to fix things
/// quietly.
///
/// A guard, not a boundary. Someone determined can spell an import so this
/// misses it — Dart allows adjacent string literals in a URI, among other
/// things — which is exactly why the enforcement lives in the runtime sandbox
/// and not here. This exists so an honest mistake is caught by the person who
/// made it, at build time, with a sentence explaining why.
/// Refuses a `try` block containing an `await`.
///
/// dart_eval does not run the catch. `Await` drops the frame's catch registry
/// at the suspension point and the resume installs a fresh empty one, so
/// everything after the first `await` unwinds straight past every handler the
/// author wrote. A patch whose error handling is written and never runs is
/// worse than one with none: the author believes the case is covered.
///
/// Matched on the text, so the same caveat as [_rejectPlatformImports] applies
/// — a guard against the honest mistake, not a proof. It errs toward flagging:
/// any `await` between a `try {` and its closing brace counts, even one that
/// could not throw.
///
/// The asymmetry with [_rejectPlatformImports] is worth stating, because the
/// two look like the same kind of rule and are not. That one is a lint in front
/// of a *boundary*: spell the import unusually and the sandbox still refuses
/// the call at runtime, so defeating the text match buys nothing. This one has
/// no boundary behind it. Nothing at runtime can tell that a handler was
/// written, so a patch that slips past this — an `await` reached through a
/// helper, a `try` this regex fails to pair — publishes with error handling
/// that silently never runs.
///
/// That is the failure this repository treats as the worst kind, so it is
/// stated rather than papered over: the fix lives in dart_eval, and until it
/// lands the honest position is that a patch author should not write `catch`
/// around `await` at all rather than trust a regex to notice.
void _rejectCatchAroundAwait(Map<String, String> sources) {
  final offenders = <String>[];
  sources.forEach((path, source) {
    for (final match in _tryBlock.allMatches(source)) {
      if (match.group(1)!.contains(RegExp(r'\bawait\b'))) {
        offenders.add(path);
        break;
      }
    }
  });
  if (offenders.isEmpty) return;

  throw CliException(
    'a patch cannot catch around an `await`:\n'
    '${offenders.map((o) => '  $o').join('\n')}',
    hint: 'dart_eval discards the catch at the suspension point, so the '
        'handler never runs and the failure escapes as if it were not there. '
        'Move the await out of the try, or let the failure happen: a patched '
        'function that throws falls back to the original, which is usually the '
        'behaviour the catch was reaching for anyway.',
  );
}

void _rejectPlatformImports(Map<String, String> sources) {
  final offenders = <String>[];
  sources.forEach((path, source) {
    for (final match in _platformImport.allMatches(source)) {
      offenders.add('$path imports ${match.group(1)}');
    }
  });
  if (offenders.isEmpty) return;

  throw CliException(
    'a patch cannot use platform libraries:\n${offenders.map((o) => '  $o').join('\n')}',
    hint: 'Patches are business logic. They run with no file system, network '
        'or process access, so these calls would be refused at runtime and the '
        'patch would silently do nothing. Move the platform work into the app, '
        'mark the function above it with @patchable, and let the patch change '
        'the logic instead.',
  );
}
