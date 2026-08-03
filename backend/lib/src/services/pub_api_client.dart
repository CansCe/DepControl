import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../ecosystem/package_registry.dart';
import 'request_cache.dart';

// The OSV advisory types, the published-version record and the registry info
// envelope were defined here when pub.dev was the only registry this server
// knew about. They were never pub-specific — OSV is a cross-ecosystem format
// and semver is shared — so they now live in the ecosystem layer, and are
// re-exported here so that reading pub.dev's client still hands you the types
// it deals in.
export '../ecosystem/package_registry.dart'
    show Advisory, AdvisoryRange, PackageVersion, RegistryInfo;

/// Thin client over the public pub.dev API.
///
/// Docs: https://pub.dev/help/api
///
/// Caching lives here rather than in the analyzer, for the reason
/// [PackageRegistry] states: request shaping belongs to the client that speaks
/// the protocol. It matters more than it sounds. A repository holding twenty
/// manifests is analysed one manifest at a time, and without a cache at this
/// level every manifest that depends on `http` fetches `http` again — the same
/// document, twenty times, for a scan that already takes minutes.
class PubApiClient {
  PubApiClient({http.Client? client, this.baseUrl = 'https://pub.dev'})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  static const _timeout = Duration(seconds: 20);

  /// How long an answer about the *state of pub.dev* stays good for.
  ///
  /// Long enough that one scan — even of a repository with a hundred manifests
  /// — asks about each package once. Short enough that a nightly rescan on a
  /// server that has been up for a week still notices a release published
  /// yesterday, which is the entire job.
  static const _volatile = Duration(minutes: 10);

  /// How long an answer about an *already published artefact* stays good for.
  ///
  /// A version's archive is immutable; its length today is its length forever.
  /// The only reason this expires at all is to stop a cache entry outliving
  /// every possible use of it.
  static const _immutable = Duration(hours: 6);

  /// Package documents already fetched, distilled — see [_PackageDoc].
  ///
  /// Capped near the number of distinct packages a large monorepo resolves, so
  /// a single scan is served entirely from cache and a long-lived process still
  /// has a ceiling.
  final _documents = RequestCache<String, _Document>(
    capacity: 1000,
    ttl: _volatile,
  );

  /// Analysis tags, keyed by the path that produced them, so the per-version
  /// and latest-release endpoints cannot collide. Tag lists are a handful of
  /// short strings each, so this can be held far more generously than the
  /// documents.
  ///
  /// Volatile despite a version's own analysis being fixed, because the same
  /// cache holds the *latest release's* score, and that moves.
  final _tags = RequestCache<String, _Tags>(capacity: 4000, ttl: _volatile);

  /// Archive sizes, keyed `package@version`. A HEAD per package per manifest is
  /// pure repetition — the archive does not change weight between manifests,
  /// or between scans.
  final _sizes = RequestCache<String, _Size>(
    capacity: 4000,
    ttl: _immutable,
  );

  /// Package names as pub.dev defines them: a Dart identifier.
  ///
  /// Names reach this client from fetched pubspecs, which are untrusted. An
  /// unchecked name is interpolated into the request path, and something like
  /// `../../admin` normalises the API prefix away — the host stays pub.dev, but
  /// the request stops being the one this client meant to make.
  ///
  /// A leading underscore is legal and is not a corner case: `_fe_analyzer_shared`
  /// is pulled in by every project that depends on `analyzer`. Rejecting it made
  /// this client answer null for the package silently, so its latest version, its
  /// advisories and its license all came back as unknown rather than as an error.
  static final _packageName = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$');

  /// Whether [name] is a package name pub.dev could serve, by the rule above.
  ///
  /// Public because the rule belongs to pub.dev rather than to this client, and
  /// [DartRegistry] answers the same question for the ecosystem layer. A second
  /// copy of the pattern is how the leading-underscore bug gets reintroduced.
  static bool isPackageName(String name) => _packageName.hasMatch(name);

  /// The newest version pub.dev has published for [package].
  ///
  /// This client no longer fetches advisories. It used to, from
  /// `/api/packages/<package>/advisories`, but that endpoint serves *withdrawn*
  /// advisories alongside live ones with nothing in the response to tell them
  /// apart — see [DartRegistry.info]. Advisories for both ecosystems now come
  /// from OSV, which is where pub.dev's came from in the first place.
  Future<String?> latestVersion(String package) async =>
      (await _document(package))?.latest;

  /// pub.dev's analysis tags for one published version of [package], which is
  /// where its detected license is published.
  ///
  /// Beware what "no analysis" looks like here. pub.dev keeps one analysis per
  /// version and drops the old ones, but a dropped version still answers with a
  /// tag list — just a shorter one, holding the facts that need no analysis
  /// (`publisher:dart.dev`, `is:obsolete`) and no `license:` tag at all. So an
  /// empty list is not the signal a caller wants; the absence of the tag it
  /// came for is. [LicenseCatalog] reads that distinction.
  ///
  /// Endpoint: `/api/packages/<package>/versions/<version>/score` -> `tags`.
  Future<List<String>> versionTags(String package, String version) async {
    try {
      Version.parse(version);
    } on FormatException {
      return const [];
    }
    return _tagsAt('/api/packages/$package/versions/$version/score', package);
  }

  /// pub.dev's analysis tags for the latest release of [package].
  ///
  /// Endpoint: `/api/packages/<package>/score` -> `tags`.
  Future<List<String>> latestTags(String package) =>
      _tagsAt('/api/packages/$package/score', package);

  Future<List<String>> _tagsAt(String path, String package) async {
    final result = await _tags.run(
      path,
      () async {
        final fetched = await _getJson(path, package);
        final tags = fetched.json?['tags'] as List?;
        return (
          tags: tags == null ? const <String>[] : tags.map((t) => '$t').toList(),
          answered: fetched.answered,
        );
      },
      keep: (result) => result.answered,
    );
    return result.tags;
  }

  /// Every published version of [package], each with the constraints it
  /// declares.
  ///
  /// `/api/packages/<package>` already embeds each version's pubspec, so the
  /// whole resolution input for a package costs a single request.
  Future<List<PackageVersion>> versions(String package) async =>
      (await _document(package))?.versions ?? const [];

  /// The names of the regular (non-dev) dependencies declared by a specific
  /// published version of [package]. Used to build the dependency graph's
  /// edges. Returns empty for versions pub.dev doesn't know (git/sdk/path deps).
  ///
  /// Normally free: the package document embeds every listed version's pubspec,
  /// and it has already been fetched to answer [latestVersion]. This used to be
  /// its own request per package per manifest, which was the single largest
  /// avoidable cost in a scan.
  ///
  /// Endpoint, for the versions the document does not list:
  /// `/api/packages/<package>/versions/<version>` -> `pubspec`.
  Future<List<String>> dependencyNames(String package, String version) async {
    // The version comes from a lockfile the project controls, so it gets the
    // same treatment as the package name.
    try {
      Version.parse(version);
    } on FormatException {
      return const [];
    }

    final listed = (await _document(package))?.dependencyNames[version];
    if (listed != null) return listed;

    // A version the document does not list — a retracted release a lockfile
    // still pins — is served by the per-version endpoint alone, so that request
    // is still worth making. Just no longer for every package on every
    // manifest.
    final fetched = await _getJson(
      '/api/packages/$package/versions/$version',
      package,
    );
    if (fetched.json == null) return const [];
    final pubspec = fetched.json!['pubspec'] as Map<String, dynamic>?;
    final deps = pubspec?['dependencies'] as Map<String, dynamic>?;
    return deps?.keys.toList() ?? const [];
  }

  /// The size of a published version's archive, in compressed bytes.
  ///
  /// pub.dev publishes no size field anywhere in its API — not in the package
  /// document, not in the per-version one — so the only measurement available
  /// is the `Content-Length` of the archive itself, taken with a HEAD so the
  /// bytes are never transferred.
  ///
  /// The URL is built rather than read out of the version document's
  /// `archive_url`, which would cost a second request per package for a field
  /// whose value is this exact string. `/api/archives/<name>-<version>.tar.gz`
  /// is the documented archive endpoint and is what `archive_url` returns.
  /// Should that ever stop being true the HEAD fails and the package reports no
  /// size, which is the same outcome as a package pub.dev has never heard of —
  /// a gap in the report rather than a wrong number in it.
  ///
  /// Returns null on any failure, and callers must read that as "not measured".
  Future<int?> archiveSizeBytes(String package, String version) async {
    if (!_packageName.hasMatch(package)) return null;
    // The version comes out of a lockfile the project controls, so it is
    // untrusted in exactly the way the package name is: it lands in the path.
    if (!_archiveVersion.hasMatch(version)) return null;

    final result = await _sizes.run(
      '$package@$version',
      () => _headArchiveSize(package, version),
      keep: (result) => result.answered,
    );
    return result.bytes;
  }

  Future<_Size> _headArchiveSize(String package, String version) async {
    final http.Response res;
    try {
      res = await _client
          .head(Uri.parse('$baseUrl/api/archives/$package-$version.tar.gz'))
          .timeout(_timeout);
    } on TimeoutException {
      return (bytes: null, answered: false);
    } on http.ClientException {
      return (bytes: null, answered: false);
    }
    // A 5xx is pub.dev failing rather than pub.dev answering, and remembering
    // it would report the package as weightless for the rest of the process.
    if (res.statusCode >= 500) return (bytes: null, answered: false);
    if (res.statusCode != 200) return (bytes: null, answered: true);

    // The raw header, not `Response.contentLength` — that one is derived from
    // the body, and a HEAD has no body, so it reads 0 for every archive on
    // pub.dev however large. Trusting it would report the whole ecosystem as
    // unmeasured while looking like it worked.
    final length = int.tryParse(res.headers['content-length'] ?? '');
    return (bytes: length != null && length > 0 ? length : null, answered: true);
  }

  /// A version string safe to interpolate into an archive path: semver's
  /// character set and nothing else, so no `../` can reach the URL.
  static final _archiveVersion = RegExp(r'^[0-9A-Za-z.+-]{1,64}$');

  /// The distilled package document for [package], fetched at most once.
  Future<_PackageDoc?> _document(String package) async {
    final result = await _documents.run(
      package,
      () async {
        final fetched = await _getJson('/api/packages/$package', package);
        return (
          doc: fetched.json == null ? null : _PackageDoc.parse(fetched.json!),
          answered: fetched.answered,
        );
      },
      keep: (result) => result.answered,
    );
    return result.doc;
  }

  /// GETs [path] on [baseUrl] and decodes it.
  ///
  /// [package] is validated rather than escaped: a name that is not a package
  /// name is not a request worth making, and refusing it here means no caller
  /// has to remember to check.
  ///
  /// Reports whether pub.dev *answered* as well as what it said, and the two
  /// are not the same thing. A 404 is pub.dev telling us it has no such
  /// package, which is a fact worth keeping; a timeout is pub.dev telling us
  /// nothing at all. This client used to collapse both into null, which was
  /// harmless while nothing was cached and would now mean one slow moment
  /// getting remembered as "that package does not exist".
  Future<_Fetched> _getJson(String path, String package) async {
    if (!_packageName.hasMatch(package)) return (json: null, answered: true);

    final http.Response res;
    try {
      res = await _client.get(Uri.parse('$baseUrl$path')).timeout(_timeout);
    } on TimeoutException {
      // One slow package should not fail a whole report; the node simply
      // reports what could not be established.
      return (json: null, answered: false);
    } on http.ClientException {
      // A reset connection or a name that would not resolve. Previously
      // uncaught here, which meant a single network blip anywhere in a scan
      // took the whole report down with it — npm's client has always caught it.
      return (json: null, answered: false);
    }
    if (res.statusCode >= 500) return (json: null, answered: false);
    if (res.statusCode != 200) return (json: null, answered: true);

    try {
      final decoded = jsonDecode(res.body);
      return (
        json: decoded is Map<String, dynamic> ? decoded : null,
        answered: true,
      );
    } on FormatException {
      return (json: null, answered: true);
    }
  }

  void close() => _client.close();
}

/// One GET's outcome: what pub.dev said, and whether it said anything.
typedef _Fetched = ({Map<String, dynamic>? json, bool answered});

/// A cached document lookup, carrying whether pub.dev was reachable.
typedef _Document = ({_PackageDoc? doc, bool answered});

/// A cached tag lookup, carrying whether pub.dev was reachable.
typedef _Tags = ({List<String> tags, bool answered});

/// A cached archive HEAD, carrying whether pub.dev was reachable.
typedef _Size = ({int? bytes, bool answered});

/// What this client keeps from `/api/packages/<name>`.
///
/// Distilled rather than held as the raw JSON, and that is the point of it.
/// pub.dev's package document carries every published version with its full
/// pubspec, alongside archive URLs, publication dates and retraction flags that
/// nothing here reads; for a package with a long release history that runs to
/// megabytes. Keeping a few hundred of those on a small machine is its own way
/// to kill a scan, so what survives the response is the three things the
/// analysis actually asks for.
class _PackageDoc {
  const _PackageDoc({
    required this.latest,
    required this.versions,
    required this.dependencyNames,
  });

  /// The newest published version, as pub.dev's `latest` reports it.
  final String? latest;

  /// Every listed version with the constraints it declares, which is the whole
  /// input to constraint resolution.
  final List<PackageVersion> versions;

  /// Version -> the regular dependency names that version declares.
  ///
  /// Kept separately from [versions] rather than derived from it, because the
  /// two want different things: resolution can only use dependencies whose
  /// constraint it can parse, while a graph edge exists whether or not the
  /// constraint is a plain range.
  final Map<String, List<String>> dependencyNames;

  static _PackageDoc parse(Map<String, dynamic> json) {
    final latest = json['latest'] as Map<String, dynamic>?;
    final list = (json['versions'] as List?) ?? const [];

    final versions = <PackageVersion>[];
    final dependencyNames = <String, List<String>>{};

    for (final entry in list.whereType<Map<String, dynamic>>()) {
      final raw = entry['version']?.toString();
      if (raw == null) continue;
      final Version version;
      try {
        version = Version.parse(raw);
      } on FormatException {
        continue;
      }

      final pubspec = entry['pubspec'] as Map<String, dynamic>?;
      final deps = pubspec?['dependencies'] as Map<String, dynamic>?;
      final environment = pubspec?['environment'] as Map<String, dynamic>?;

      dependencyNames[raw] = deps?.keys.toList() ?? const [];
      versions.add(
        PackageVersion(
          version: version,
          sdkConstraint: environment?['sdk']?.toString(),
          dependencies: {
            for (final e in (deps ?? const {}).entries)
              // Only plain string constraints are hosted deps; a map means
              // git/path/sdk, which pub.dev cannot resolve for us.
              if (e.value is String) e.key: e.value as String,
          },
        ),
      );
    }

    return _PackageDoc(
      latest: latest?['version'] as String?,
      versions: versions,
      dependencyNames: dependencyNames,
    );
  }
}
