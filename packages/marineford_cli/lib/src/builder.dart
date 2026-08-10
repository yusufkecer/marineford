import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:marineford_core/marineford_core.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
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
    required String abi,
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

    final Program program;
    try {
      program = Compiler().compile(<String, Map<String, String>>{
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
      knownIds: knownIds,
    );

    final evc = program.write();
    final payload = Uint8List.fromList(gzip.encode(evc));

    final region = MfpContainer.buildSignedRegion(
      payload: payload,
      abiHash: _abiBytes(abi),
    );
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

  static String _compileHint(String error) {
    const unsupported = <String, String>{
      'mixin': 'dart_eval does not support mixins.',
      'extension': 'dart_eval does not support extension methods.',
      'yield': 'dart_eval does not support generators (sync* / async*).',
      'late': 'dart_eval does not support `late`.',
      'typedef': 'dart_eval does not support typedefs.',
    };
    for (final entry in unsupported.entries) {
      if (error.toLowerCase().contains(entry.key)) {
        return '${entry.value} Rewrite that part of the patch without it; the '
            'rest of the file is fine.';
      }
    }
    return 'Patch code runs on dart_eval, which implements most but not all '
        'of Dart. Unsupported: mixins, extension methods, generators, '
        'typedefs, `late`, deferred imports, isolates.';
  }

  static Uint8List _abiBytes(String abi) {
    if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(abi)) {
      throw CliException(
        'the ABI fingerprint "$abi" is malformed',
        hint: 'Run `dart run build_runner build` in your app so marineford_gen '
            'can regenerate lib/marineford.g.dart.',
      );
    }
    final hex = abi.substring('sha256:'.length);
    return Uint8List.fromList(<int>[
      for (var i = 0; i < 32; i++)
        int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ]);
  }
}
