import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:yaml/yaml.dart';

import '../ecosystem.dart';
import 'import_scanner.dart';

/// Dart and Flutter packages: `pubspec.yaml`, `pubspec.lock`, pub.dev.
///
/// The reference implementation of [Ecosystem] — everything here was the whole
/// of this application before a second ecosystem existed, so where the
/// interface looks shaped around pub, that is the reason and not an accident.
class DartEcosystem implements Ecosystem {
  const DartEcosystem();

  @override
  String get id => 'dart';

  @override
  String get displayName => 'Dart / Flutter';

  @override
  ManifestNaming get naming => const ManifestNaming(
        ecosystem: 'dart',
        manifests: ['pubspec.yaml'],
        lockFiles: ['pubspec.lock'],
        sourceExtensions: ['.dart'],
        // A lint set is pulled in by `include:` and imported by nothing, which
        // is the only reason `lints` is not reported as unused by every project
        // that uses it.
        auxiliaryFiles: ['analysis_options.yaml'],
      );

  @override
  SourceScanner? get sourceScanner => const DartSourceScanner();

  @override
  ParsedManifest parse(ManifestFiles files) {
    final pubspec = Pubspec.parse(files.manifest);

    return ParsedManifest(
      packageName: pubspec.name,
      dependencies: _declarations(pubspec.dependencies),
      devDependencies: _declarations(pubspec.devDependencies),
      locked: files.lock == null ? const {} : _parseLock(files.lock!),
    );
  }

  @override
  VersionConstraint? parseConstraint(String text) {
    try {
      return VersionConstraint.parse(text);
    } on FormatException {
      return null;
    }
  }

  @override
  String constraintAtLeast(Version version) => '^$version';

  Map<String, DeclaredDependency> _declarations(
    Map<String, Dependency> deps,
  ) =>
      {
        for (final entry in deps.entries)
          entry.key: DeclaredDependency(
            constraint: switch (entry.value) {
              final HostedDependency hosted => hosted.version.toString(),
              final other => other.toString(),
            },
            foreignOrigin: _originOf(entry.value),
          ),
      };

  /// Where a declared dependency comes from, or null when it comes from
  /// pub.dev — the only case anything downstream needs to query.
  static String? _originOf(Dependency dependency) => switch (dependency) {
        HostedDependency() => null,
        SdkDependency() => 'the SDK',
        PathDependency() => 'a path dependency',
        GitDependency() => 'a git dependency',
      };

  /// Minimal `pubspec.lock` reader: package -> resolved version and where it
  /// came from.
  static Map<String, LockedDependency> _parseLock(String lockContent) {
    final doc = loadYaml(lockContent);
    if (doc is! YamlMap) return const {};
    final packages = doc['packages'];
    if (packages is! YamlMap) return const {};

    return {
      for (final entry in packages.entries)
        if (entry.value case final YamlMap package)
          entry.key as String: LockedDependency(
            version: package['version'] as String? ?? '(unknown)',
            foreignOrigin: _lockOrigin(package['source']?.toString()),
          ),
    };
  }

  /// Where a lockfile entry says a package came from, or null for pub.dev.
  ///
  /// An entry with no `source:` is telling us nothing, so it is taken as
  /// published — which is what a lockfile entry without a source almost always
  /// is. An entry naming a source this build does not recognise *is* saying
  /// something, and it is not saying "pub.dev".
  static String? _lockOrigin(String? source) => switch (source) {
        null || 'hosted' => null,
        'sdk' => 'the SDK',
        'path' => 'a path dependency',
        'git' => 'a git dependency',
        _ => 'outside pub.dev',
      };
}

/// [ImportScanner] behind the [SourceScanner] interface.
class DartSourceScanner implements SourceScanner {
  const DartSourceScanner();

  @override
  Set<String> scan(
    Iterable<String> sources, {
    Iterable<String> auxiliary = const [],
  }) =>
      ImportScanner.scan(sources, optionsFiles: auxiliary);
}
