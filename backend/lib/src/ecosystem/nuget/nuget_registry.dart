import 'dart:async';
import 'dart:convert';

import 'package:ecosystem/ecosystem.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import '../../services/license_catalog.dart';
import '../../services/request_cache.dart';
import '../osv_client.dart';
import '../package_registry.dart';

/// api.nuget.org, behind [PackageRegistry].
///
/// nuget.org publishes several APIs over the same packages and they are not
/// interchangeable. This client uses two of them:
///
/// * the **registration index** (`/v3/registration5-gz-semver2/{id}/index.json`)
///   for what a scan mostly needs — every published version, what each declares
///   as dependencies, and the licence each was published under. It is the
///   nearest thing NuGet has to npm's packument, and taking one document per
///   package rather than one per version is what keeps a scan's request count
///   proportional to packages instead of to releases;
/// * the **flat container** (`/v3-flatcontainer/{id}/{version}/{id}.{version}.nupkg`)
///   for weight, by asking for the headers of the package itself.
///
/// Everything reaches it lowercased. NuGet package ids are case-insensitive —
/// `newtonsoft.json` and `Newtonsoft.Json` are one package — but its URLs are
/// not, and a request with the manifest's casing on it 404s. The manifest's
/// casing is what gets reported, because it is what the project wrote.
class NuGetRegistry implements PackageRegistry {
  NuGetRegistry({
    http.Client? client,
    OsvClient? osv,
    this.baseUrl = 'https://api.nuget.org',
  })  : _client = client ?? http.Client(),
        _osv = osv ?? OsvClient(client: client);

  final http.Client _client;

  /// Where advisories come from. nuget.org publishes none of its own in a
  /// per-package form — the vulnerability data on the website is GitHub's, via
  /// the same feeds OSV aggregates.
  final OsvClient _osv;

  final String baseUrl;

  static const _timeout = Duration(seconds: 20);

  /// OSV's name for this ecosystem. Case-sensitive, and not [Ecosystem.id].
  static const osvEcosystem = 'NuGet';

  /// The registration resource that serves gzipped, SemVer 2.0 aware documents.
  ///
  /// The plain `registration5-semver1` resource silently omits every version
  /// with SemVer 2.0 build metadata or a dotted pre-release — which is exactly
  /// the four-part and `-beta.1` versions .NET is full of. Reading it would
  /// report packages as having fewer releases than they do, and a project on
  /// one of the omitted versions as installed on something unpublished.
  static const _registrationPath = '/v3/registration5-gz-semver2';

  /// Where the packages themselves are served from, for [sizeOf].
  static const _flatContainerPath = '/v3-flatcontainer';

  /// How long an answer about the *state of the registry* stays good for. As
  /// npm: long enough that one scan asks once, short enough that a re-scan
  /// notices yesterday's release.
  static const _volatile = Duration(minutes: 10);

  /// Most registration pages to fetch for one package.
  ///
  /// A package's registration index inlines its pages while there are few of
  /// them and links to them once there are many — `Newtonsoft.Json` has over
  /// 100 releases across several pages. The newest pages are taken, because a
  /// resolution is choosing what to install today and an advisory is about what
  /// is installed now. A package whose release history is longer than this
  /// loses its oldest versions from resolution, which shows up as a constraint
  /// pinned to something ancient failing to resolve rather than as a wrong
  /// answer.
  static const _maxPages = 4;

  final _registrations = RequestCache<String, _Fetched<_Registration?>>(
    capacity: 2000,
    ttl: _volatile,
  );

  /// Package weights, keyed `package@version`. Held far longer than the
  /// registrations: a published `.nupkg` does not change size.
  final _sizes = RequestCache<String, _Fetched<PackageSize?>>(
    capacity: 4000,
    ttl: const Duration(hours: 6),
  );

  /// NuGet package ids: letters, digits, and the three separators, in
  /// dot-separated segments. At most 100 characters.
  ///
  /// Validated rather than escaped, for the reason [PackageRegistry] states: an
  /// id arrives from a `.csproj` fetched off the internet and is interpolated
  /// into a request path. `..` is refused outright — it is legal in neither a
  /// package id nor a path this server should be issuing.
  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  @override
  bool isValidPackageName(String name) =>
      name.length <= 100 && !name.contains('..') && _name.hasMatch(name);

  @override
  Future<RegistryInfo> info(String package) async {
    // Checked here as well as in the fetch, because this makes a second
    // outbound call to a different host; validating only the one that
    // interpolates the name leaves the other reachable.
    if (!isValidPackageName(package)) return const RegistryInfo(latest: null);

    final (registration, advisories) = await (
      _registration(package),
      _osv.advisoriesFor(package, ecosystem: osvEcosystem),
    ).wait;

    return RegistryInfo(latest: registration?.latest, advisories: advisories);
  }

  @override
  Future<List<PackageVersion>> versions(String package) async =>
      (await _registration(package))?.versions ?? const [];

  @override
  Future<List<String>> dependencyNames(String package, String version) async =>
      (await _registration(package))?.dependencyNames[version] ?? const [];

  /// The licence nuget.org holds for one published version.
  ///
  /// `licenseExpression` is the modern field and an SPDX expression, which is
  /// the same shape npm's is. `licenseUrl` is the deprecated form and is
  /// deliberately **not** read as a licence: it is a link, frequently to a
  /// repository file or to a page that has since moved, and turning
  /// `https://github.com/x/y/blob/master/LICENSE` into an SPDX id would be
  /// inventing the one field a compliance report exists to be sure of. A
  /// package that publishes only a URL reads as undetermined, which sends it to
  /// a human.
  @override
  Future<PackageLicense> licenseFor(
    String package,
    String installed,
    String? latest,
  ) async {
    final registration = await _registration(package);
    if (registration == null) return PackageLicense.undetermined;

    final exact = registration.licenses[_key(installed)];
    if (exact != null && exact.isNotEmpty) {
      return PackageLicense(
        spdxId: exact,
        // Null from the catalogue means never heard of it, which under the
        // standard policy sends it to a human rather than to "probably fine".
        category: LicenseCatalog.categoryFor(exact) ?? LicenseCategory.unknown,
        source: LicenseSource.installedVersion,
        readFromVersion: installed,
      );
    }

    if (latest != null && latest != installed) {
      final fromLatest = registration.licenses[_key(latest)];
      if (fromLatest != null && fromLatest.isNotEmpty) {
        return PackageLicense(
          spdxId: fromLatest,
          category:
              LicenseCatalog.categoryFor(fromLatest) ?? LicenseCategory.unknown,
          source: LicenseSource.latestRelease,
          readFromVersion: latest,
        );
      }
    }

    return PackageLicense.undetermined;
  }

  /// The compressed size of the published `.nupkg`.
  ///
  /// Reported as [SizeBasis.archive] rather than converted, for the reason
  /// pub.dev's is: a `.nupkg` is a zip of assemblies and its compression ratio
  /// depends entirely on what is inside, so multiplying by a guess would turn a
  /// measured number into an invented one.
  ///
  /// A HEAD rather than a download, and the registration document is not asked
  /// for it — nuget.org's registration entries do not carry a size, and the
  /// catalog that does is a different API with a different shape.
  @override
  Future<PackageSize?> sizeOf(String package, String version) async {
    if (!isValidPackageName(package)) return null;

    final normalised = NuGetVersion.normalise(version);
    if (normalised == null) return null;

    final result = await _sizes.run(
      '${_key(package)}@$normalised',
      () async {
        final id = _key(package);
        // The file name uses NuGet's own spelling of the version, not the
        // normalised one this application stores: `5.2.7.4000.nupkg`.
        final file = NuGetVersion.format(NuGetVersion.tryParse(version)!);
        final url = Uri.parse(
          '$baseUrl$_flatContainerPath/$id/$file/$id.$file.nupkg',
        );

        final http.Response response;
        try {
          response = await _client.head(url).timeout(_timeout);
        } on TimeoutException {
          return (value: null, answered: false);
        } on http.ClientException {
          return (value: null, answered: false);
        }
        if (response.statusCode >= 500) return (value: null, answered: false);
        if (response.statusCode != 200) return (value: null, answered: true);

        final length = int.tryParse(
          response.headers['content-length'] ?? '',
        );
        return (
          value: length == null || length <= 0
              ? null
              : PackageSize(bytes: length, basis: SizeBasis.archive),
          answered: true,
        );
      },
      keep: (result) => result.answered,
    );
    return result.value;
  }

  Future<_Registration?> _registration(String package) async {
    final result = await _registrations.run(
      _key(package),
      () async {
        final index = await _getJson(
          '$_registrationPath/${_key(package)}/index.json',
          package,
        );
        if (index.json == null) {
          return (value: null, answered: index.answered);
        }

        final pages = await _pagesOf(index.json!, package);
        return (value: _Registration.parse(pages), answered: true);
      },
      // An unreachable registry must not be remembered as a package that does
      // not exist; a 404 may be.
      keep: (result) => result.answered,
    );
    return result.value;
  }

  /// The registration pages for a package, inline where the index inlined them
  /// and fetched where it did not.
  Future<List<Map<String, dynamic>>> _pagesOf(
    Map<String, dynamic> index,
    String package,
  ) async {
    final items = index['items'];
    if (items is! List) return const [];

    final inline = <Map<String, dynamic>>[];
    final linked = <String>[];

    for (final page in items.whereType<Map<String, dynamic>>()) {
      if (page['items'] is List) {
        inline.add(page);
      } else if (page['@id'] case final String url) {
        linked.add(url);
      }
    }

    // Newest last, so the newest links are the ones worth spending requests on.
    for (final url in linked.skip(
      linked.length > _maxPages ? linked.length - _maxPages : 0,
    )) {
      final fetched = await _getAbsolute(url, package);
      if (fetched.json != null) inline.add(fetched.json!);
    }

    return inline;
  }

  /// A package id as nuget.org spells it in a URL.
  static String _key(String value) => value.trim().toLowerCase();

  Future<_Json> _getJson(String path, String package) =>
      _getAbsolute('$baseUrl$path', package);

  /// GETs [url] and decodes it, reporting whether nuget.org answered.
  ///
  /// The answered flag is not the same as a body: a 404 is nuget.org saying it
  /// has no such package, while a timeout or a 502 is nuget.org saying nothing.
  /// Both arrive as null, and only the first is safe to remember.
  ///
  /// Linked registration pages are absolute URLs out of the index document, so
  /// they are checked against [baseUrl] before being requested — a document
  /// fetched from the internet must not be able to point this server at an
  /// address of its choosing.
  Future<_Json> _getAbsolute(String url, String package) async {
    if (!isValidPackageName(package)) return (json: null, answered: true);
    if (!url.startsWith('$baseUrl/')) return (json: null, answered: true);

    final http.Response response;
    try {
      response = await _client.get(Uri.parse(url)).timeout(_timeout);
    } on TimeoutException {
      return (json: null, answered: false);
    } on http.ClientException {
      return (json: null, answered: false);
    }
    if (response.statusCode >= 500) return (json: null, answered: false);
    if (response.statusCode != 200) return (json: null, answered: true);

    try {
      final decoded = jsonDecode(response.body);
      return (
        json: decoded is Map<String, dynamic> ? decoded : null,
        answered: true,
      );
    } on FormatException {
      return (json: null, answered: true);
    }
  }

  void close() {
    _client.close();
    _osv.close();
  }
}

/// One GET's outcome: what nuget.org said, and whether it said anything.
typedef _Json = ({Map<String, dynamic>? json, bool answered});

/// A cached lookup of any kind, carrying whether nuget.org was reachable.
typedef _Fetched<T> = ({T value, bool answered});

/// What this client keeps from a package's registration pages.
///
/// Distilled rather than held raw, as npm's packument is: a registration page
/// carries catalog URLs, descriptions, authors and per-framework dependency
/// groups for every release, and a scan holds hundreds of these at once on a
/// machine with a few hundred megabytes.
class _Registration {
  const _Registration({
    required this.latest,
    required this.versions,
    required this.dependencyNames,
    required this.licenses,
  });

  /// The current release: the highest **listed, stable** version, falling back
  /// to the highest pre-release for a package that has only ever shipped those.
  ///
  /// Not simply the last entry. Registration pages are ordered by version, but
  /// a package whose newest release is `5.0.0-preview.3` is not on 5.0.0-
  /// preview.3 as far as anyone restoring it is concerned, and reporting it as
  /// the latest would tell every project on 4.x that it is behind.
  final String? latest;

  final List<PackageVersion> versions;

  /// Version -> the names of the packages it depends on, across every target
  /// framework it declares.
  ///
  /// Merged across frameworks rather than kept per framework. A graph edge says
  /// "this package can pull that one in", which is true if any framework's
  /// group names it, and the report has no vocabulary for a dependency that
  /// exists only on .NET Framework.
  final Map<String, List<String>> dependencyNames;

  /// Version -> the SPDX expression it was published under, where it published
  /// one.
  final Map<String, String> licenses;

  static _Registration parse(List<Map<String, dynamic>> pages) {
    final versions = <PackageVersion>[];
    final dependencyNames = <String, List<String>>{};
    final licenses = <String, String>{};
    final listed = <Version>[];

    for (final page in pages) {
      final items = page['items'];
      if (items is! List) continue;

      for (final leaf in items.whereType<Map<String, dynamic>>()) {
        final entry = leaf['catalogEntry'];
        // In a linked page the entry is a URL rather than a document. Following
        // it would be one request per release, which is the cost this client is
        // built to avoid.
        if (entry is! Map<String, dynamic>) continue;

        final raw = entry['version'];
        if (raw is! String) continue;
        final version = NuGetVersion.tryParse(raw);
        if (version == null) continue;
        final key = version.toString();

        final dependencies = <String, String>{};
        final names = <String>[];
        for (final group
            in (entry['dependencyGroups'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()) {
          for (final dependency in (group['dependencies'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()) {
            final id = dependency['id'];
            if (id is! String || id.isEmpty) continue;
            if (!names.contains(id)) names.add(id);
            final range = dependency['range'];
            if (range is String && range.isNotEmpty) {
              dependencies.putIfAbsent(id, () => range);
            }
          }
        }

        versions.add(
          PackageVersion(version: version, dependencies: dependencies),
        );
        dependencyNames[key] = names;

        final expression = entry['licenseExpression'];
        if (expression is String && expression.isNotEmpty) {
          licenses[key] = expression;
        }

        // `listed: false` is an unlisted release — still installable by exact
        // version, deliberately hidden from anyone browsing. It must not become
        // the version everybody is told they are behind.
        if (leaf['listed'] != false && entry['listed'] != false) {
          listed.add(version);
        }
      }
    }

    listed.sort();
    final stable = listed.where((v) => !v.isPreRelease).toList();
    final latest = stable.isNotEmpty
        ? stable.last
        : (listed.isNotEmpty ? listed.last : null);

    return _Registration(
      latest: latest?.toString(),
      versions: versions,
      dependencyNames: dependencyNames,
      licenses: licenses,
    );
  }
}
