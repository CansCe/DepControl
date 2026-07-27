import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shared/shared.dart';
import 'package:yaml/yaml.dart';

import 'git_fetcher.dart';
import 'pub_api_client.dart';

/// Turns fetched pubspec files into a [DepReport] enriched with pub.dev data.
class PubspecAnalyzer {
  PubspecAnalyzer(this._pub);

  final PubApiClient _pub;

  Future<DepReport> analyze(
    String projectId,
    FetchedPubspecs files,
  ) async {
    final pubspec = Pubspec.parse(files.pubspecYaml);
    final directNames = pubspec.dependencies.keys.toSet();
    final devNames = pubspec.devDependencies.keys.toSet();

    // Locked versions come from pubspec.lock when present; otherwise we only
    // know the direct constraints.
    final locked = files.hasLock ? _parseLock(files.pubspecLock!) : {};

    final names = <String>{...directNames, ...devNames, ...locked.keys};
    final nodes = <DepNode>[];

    for (final name in names) {
      final installed = locked[name] ?? '(unresolved)';
      final constraint = _constraintString(pubspec, name);
      final kind = directNames.contains(name)
          ? DepKind.direct
          : devNames.contains(name)
              ? DepKind.dev
              : DepKind.transitive;

      final info = await _pub.info(name);

      // An advisory applies to specific versions. Only those affecting the
      // version actually in use are attached; without a resolved version we
      // cannot judge, so none are claimed.
      final current = _tryParseVersion(installed);
      final advisories = current == null
          ? const <String>[]
          : [
              for (final advisory in info.advisories)
                if (advisory.affects(current)) advisory.id,
            ];

      final status = _status(installed, info.latest, advisories);

      // Graph edges: this package's regular deps, kept only if they're also in
      // the project's resolved set (so edges never dangle). Skipped when the
      // version isn't a real semver (no lockfile), since pub.dev can't be
      // queried for the dependencies of "(unresolved)".
      final children = _tryParseVersion(installed) == null
          ? const <String>[]
          : (await _pub.dependencyNames(name, installed))
              .where(names.contains)
              .toList();

      nodes.add(
        DepNode(
          name: name,
          kind: kind,
          installed: installed,
          constraint: constraint,
          latest: info.latest,
          status: status,
          advisories: advisories,
          dependencies: children,
        ),
      );
    }

    return DepReport(
      projectId: projectId,
      generatedAt: DateTime.now().toUtc(),
      nodes: nodes,
    );
  }

  String? _constraintString(Pubspec p, String name) {
    final dep = p.dependencies[name] ?? p.devDependencies[name];
    if (dep is HostedDependency) return dep.version.toString();
    return dep?.toString();
  }

  DepStatus _status(
    String installed,
    String? latest,
    List<String> advisories,
  ) {
    if (advisories.isNotEmpty) return DepStatus.vulnerable;
    if (latest == null) return DepStatus.unknown;
    final cur = _tryParseVersion(installed);
    final lat = _tryParseVersion(latest);
    if (cur == null || lat == null) return DepStatus.unknown;
    return cur < lat ? DepStatus.outdated : DepStatus.upToDate;
  }

  /// Parses a semver string, returning null instead of throwing.
  ///
  /// [Version.parse] throws a [FormatException] on anything non-semver, and
  /// `installed` is the sentinel `(unresolved)` for projects with no
  /// `pubspec.lock` — so parsing directly crashed the whole analysis for any
  /// repo that doesn't commit its lockfile. Such versions are simply unknown.
  static Version? _tryParseVersion(String text) {
    try {
      return Version.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// Minimal pubspec.lock reader: package -> resolved version.
  Map<String, String> _parseLock(String lockContent) {
    final doc = loadYaml(lockContent) as YamlMap;
    final packages = doc['packages'] as YamlMap?;
    if (packages == null) return {};
    return {
      for (final entry in packages.entries)
        entry.key as String:
            (entry.value as YamlMap)['version'] as String? ?? '(unknown)',
    };
  }
}
