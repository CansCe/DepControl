import 'package:xml/xml.dart';
import 'package:yaml/yaml.dart';

/// Which packages come from a feed the server cannot look up.
///
/// An internal package — `Acme.Payroll.Core` on a private NuGet feed — is not on
/// nuget.org. Left unmarked, the analyzer queries it, gets a 404, and degrades
/// the node to unmeasured: the repository's most sensitive names go into the
/// report as noise carrying no information. Worse, a name squatted on by
/// unrelated software gets reported with somebody else's licence and advisories.
///
/// The codebase already has the right answer and it is not a new mechanism. SDK,
/// path and git dependencies are listed as unchecked *with where they came
/// from*, because "we could not check this" is not "somebody must review this".
/// A private-feed package is the same case, so it is given the same marker.
///
/// **The feed's hostname never travels.** This class reads `NuGet.config`,
/// `.npmrc` and a `pubspec.yaml`'s `hosted:` overrides locally and emits one
/// boolean per package. `https://nuget.acme.internal/v3/index.json` names an
/// internal host, an internal team and quite often an internal product; the
/// server needs to know it cannot look the package up, and nothing more.
class PrivateFeeds {
  const PrivateFeeds({
    this.npmScopes = const {},
    this.nugetPatterns = const [],
    this.dartPackages = const {},
    this.unattributedNuGetSources = const [],
  });

  /// npm scopes served by something other than registry.npmjs.org.
  final Set<String> npmScopes;

  /// NuGet package id patterns mapped to a non-public source. Exact ids, or a
  /// prefix ending in `*` — the two forms NuGet's own source mapping allows.
  final List<String> nugetPatterns;

  /// Dart packages whose `hosted:` names a host other than pub.dev.
  final Set<String> dartPackages;

  /// Non-public NuGet sources that no `packageSourceMapping` attributes any
  /// package to.
  ///
  /// Kept so the CLI can say so out loud. Without a mapping there is no way to
  /// tell which packages came from the private source — NuGet itself resolves
  /// that by asking every configured source in turn — so nothing is marked, and
  /// `--exclude-private` would then withhold nothing while appearing to work.
  /// A promise that silently does nothing is worse than one that is refused.
  final List<String> unattributedNuGetSources;

  bool get isEmpty =>
      npmScopes.isEmpty && nugetPatterns.isEmpty && dartPackages.isEmpty;

  /// Whether [package] of [ecosystem] resolves from a feed the server cannot
  /// reach.
  bool contains(String ecosystem, String package) {
    switch (ecosystem) {
      case 'npm':
        final scope = _scopeOf(package);
        return scope != null && npmScopes.contains(scope);
      case 'nuget':
        return nugetPatterns.any((p) => _matchesNuGet(p, package));
      case 'dart':
        return dartPackages.contains(package);
      default:
        return false;
    }
  }

  /// Everything in [others] and this, merged. Configuration nests: a repository
  /// root `NuGet.config` and a project-level one both apply, and MSBuild reads
  /// them all.
  PrivateFeeds merge(PrivateFeeds other) => PrivateFeeds(
        npmScopes: {...npmScopes, ...other.npmScopes},
        nugetPatterns: [...nugetPatterns, ...other.nugetPatterns],
        dartPackages: {...dartPackages, ...other.dartPackages},
        unattributedNuGetSources: [
          ...unattributedNuGetSources,
          ...other.unattributedNuGetSources,
        ],
      );

  /// Reads an `.npmrc`.
  ///
  /// Only **scoped** registries count. A bare `registry=` line redirects
  /// everything, and the overwhelmingly common reason to write one is a caching
  /// proxy in front of npmjs — marking every package in the repository as
  /// private would withhold the entire report to protect names that are public.
  /// A scope is the deliberate statement that these packages are ours.
  static PrivateFeeds fromNpmrc(String content) {
    final scopes = <String>{};
    for (final line in content.split(RegExp(r'\r?\n'))) {
      final match = _npmScopeRegistry.firstMatch(line.trim());
      if (match == null) continue;
      final host = _hostOf(match.group(2)!);
      if (host == null || _publicNpmHosts.contains(host)) continue;
      scopes.add(match.group(1)!.toLowerCase());
    }
    return PrivateFeeds(npmScopes: scopes);
  }

  /// Reads a `NuGet.config`, using its `packageSourceMapping` to say which
  /// package ids come from a non-public source.
  static PrivateFeeds fromNuGetConfig(String content) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(content);
    } on XmlException {
      return const PrivateFeeds();
    }

    // key -> whether that source is somewhere the server cannot reach.
    final privateSources = <String>{};
    for (final sources in document.findAllElements('packageSources')) {
      for (final add in sources.findElements('add')) {
        final key = add.getAttribute('key');
        final value = add.getAttribute('value');
        if (key == null || value == null) continue;
        final host = _hostOf(value);
        // A `value` that is not a URL at all is a local folder source, which is
        // as unreachable from the server as any internal host.
        if (host == null || !_publicNuGetHosts.contains(host)) {
          privateSources.add(key);
        }
      }
    }
    if (privateSources.isEmpty) return const PrivateFeeds();

    final patterns = <String>[];
    final mapped = <String>{};
    for (final mapping in document.findAllElements('packageSourceMapping')) {
      for (final source in mapping.findElements('packageSource')) {
        final key = source.getAttribute('key');
        if (key == null || !privateSources.contains(key)) continue;
        mapped.add(key);
        for (final package in source.findElements('package')) {
          final pattern = package.getAttribute('pattern');
          if (pattern != null && pattern.isNotEmpty) patterns.add(pattern);
        }
      }
    }

    return PrivateFeeds(
      nugetPatterns: patterns,
      unattributedNuGetSources: [
        for (final key in privateSources)
          if (!mapped.contains(key)) key,
      ],
    );
  }

  /// Reads a `pubspec.yaml`'s `hosted:` overrides.
  ///
  /// Pub's own answer to a private feed, and one the shared parser deliberately
  /// does not surface: `DartEcosystem` reports a hosted dependency as coming
  /// from the registry whatever host it names, because until now every host it
  /// could name was one the server could reach.
  static PrivateFeeds fromPubspec(String content) {
    final Object? document;
    try {
      document = loadYaml(content);
    } on YamlException {
      return const PrivateFeeds();
    }
    if (document is! YamlMap) return const PrivateFeeds();

    final packages = <String>{};
    for (final section in const ['dependencies', 'dev_dependencies']) {
      if (document[section] case final YamlMap deps) {
        for (final entry in deps.entries) {
          final host = _hostedHostOf(entry.value);
          if (host != null && !_publicPubHosts.contains(host)) {
            packages.add(entry.key.toString());
          }
        }
      }
    }
    return PrivateFeeds(dartPackages: packages);
  }

  /// The host a dependency's `hosted:` names, in either spelling pub allows —
  /// `hosted: https://host` and `hosted: {url: https://host}` — or null when it
  /// names none.
  static String? _hostedHostOf(Object? declaration) {
    if (declaration is! YamlMap) return null;
    final hosted = declaration['hosted'];
    return switch (hosted) {
      final String url => _hostOf(url),
      final YamlMap map => _hostOf(map['url']?.toString() ?? ''),
      _ => null,
    };
  }

  static String? _scopeOf(String package) =>
      package.startsWith('@') && package.contains('/')
          ? package.substring(0, package.indexOf('/')).toLowerCase()
          : null;

  /// NuGet's own pattern rules: an exact id, or a prefix ending in `*`. Ids are
  /// case-insensitive, and so is the match.
  static bool _matchesNuGet(String pattern, String package) {
    final id = package.toLowerCase();
    final p = pattern.toLowerCase();
    if (!p.endsWith('*')) return id == p;
    return id.startsWith(p.substring(0, p.length - 1));
  }

  static String? _hostOf(String value) {
    final url = Uri.tryParse(value.trim());
    return url == null || !url.hasAuthority ? null : url.host.toLowerCase();
  }

  static final _npmScopeRegistry =
      RegExp(r'^(@[^:\s]+)\s*:\s*registry\s*=\s*(\S+)$');

  static const _publicNpmHosts = {'registry.npmjs.org', 'npmjs.org'};
  static const _publicNuGetHosts = {
    'api.nuget.org',
    'www.nuget.org',
    'nuget.org',
  };
  static const _publicPubHosts = {'pub.dev', 'pub.dartlang.org'};
}

/// Where a private-feed package's origin is recorded.
///
/// Reads as prose in a report beside 'a git dependency' and 'the SDK', which is
/// the company it keeps: all four mean "not something the registry can be asked
/// about", and none of them says where instead.
const privateFeedOrigin = 'a private registry';
