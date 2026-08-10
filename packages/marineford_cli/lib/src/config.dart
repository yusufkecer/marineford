import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Thrown when the project is not set up the way a command needs.
///
/// Carries a message meant to be the whole of what the user sees: what is
/// wrong, and what to type next. A CLI that prints a stack trace has failed
/// twice.
final class CliException implements Exception {
  /// Creates a [CliException].
  const CliException(this.message, {this.hint});

  /// What went wrong.
  final String message;

  /// What to do about it.
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message\n\n$hint';
}

/// `marineford.yaml`, the per-project configuration.
final class MarinefordProject {
  /// Creates a [MarinefordProject].
  const MarinefordProject({
    required this.appId,
    required this.root,
    this.channel = 'prod',
    this.baseUrl,
    this.patchPackage = 'patch',
    this.appPackage = '.',
    this.sizeBudgetBytes = 256 * 1024,
  });

  /// Application id. Must match what the app passes to `MarinefordConfig`.
  final String appId;

  /// Directory holding `marineford.yaml`.
  final Directory root;

  /// Default release channel.
  final String channel;

  /// Public base URL the manifest will be served from, if known.
  final String? baseUrl;

  /// Path to the patch package, relative to [root].
  final String patchPackage;

  /// Path to the app package, relative to [root].
  final String appPackage;

  /// Warn above this compressed patch size.
  final int sizeBudgetBytes;

  /// Where the signing key lives. Never committed.
  File get privateKeyFile =>
      File(p.join(root.path, '.marineford', 'signing.key'));

  /// Where the public key is cached for convenience.
  File get publicKeyFile =>
      File(p.join(root.path, '.marineford', 'signing.pub'));

  /// Where builds land.
  Directory get outputDirectory => Directory(p.join(root.path, 'out'));

  /// The id registry `marineford_gen` writes for the app.
  File get idRegistryFile =>
      File(p.join(root.path, appPackage, 'marineford_ids.json'));

  /// Finds `marineford.yaml` by walking up from [start].
  static MarinefordProject load([Directory? start]) {
    var directory = start ?? Directory.current;
    while (true) {
      final file = File(p.join(directory.path, 'marineford.yaml'));
      if (file.existsSync()) return _parse(file, directory);
      final parent = directory.parent;
      if (parent.path == directory.path) {
        throw const CliException(
          'no marineford.yaml found in this directory or any parent',
          hint: 'Run `marineford init` in your project root to create one.',
        );
      }
      directory = parent;
    }
  }

  static MarinefordProject _parse(File file, Directory root) {
    final Object? parsed;
    try {
      parsed = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw CliException('${file.path} is not valid YAML: ${e.message}');
    }
    if (parsed is! YamlMap) {
      throw CliException('${file.path} must be a YAML map');
    }

    final appId = parsed['app_id'];
    if (appId is! String || appId.isEmpty) {
      throw CliException('${file.path} is missing `app_id`');
    }
    final budget = parsed['size_budget_kb'];

    return MarinefordProject(
      appId: appId,
      root: root,
      channel: parsed['channel'] as String? ?? 'prod',
      baseUrl: parsed['base_url'] as String?,
      patchPackage: parsed['patch_package'] as String? ?? 'patch',
      appPackage: parsed['app_package'] as String? ?? '.',
      sizeBudgetBytes: budget is int ? budget * 1024 : 256 * 1024,
    );
  }

  /// Reads the ids `marineford_gen` recorded for the app.
  ///
  /// Returns null when the registry is missing, which usually means
  /// `build_runner` has not been run since the last change.
  MarinefordIdRegistry? readIdRegistry() {
    if (!idRegistryFile.existsSync()) return null;
    try {
      final decoded = jsonDecode(idRegistryFile.readAsStringSync());
      if (decoded is! Map<String, Object?>) return null;
      return MarinefordIdRegistry(
        abi: decoded['abi'] as String? ?? '',
        ids: <String>{
          for (final entry in decoded['ids'] as List? ?? const [])
            if (entry is Map && entry['id'] is String) entry['id'] as String,
        },
      );
    } on Object {
      return null;
    }
  }
}

/// The patchable surface of a build, as recorded by the generator.
final class MarinefordIdRegistry {
  /// Creates a [MarinefordIdRegistry].
  const MarinefordIdRegistry({required this.abi, required this.ids});

  /// The ABI fingerprint the app was built with.
  final String abi;

  /// Every dispatch id the app exposes.
  final Set<String> ids;
}
