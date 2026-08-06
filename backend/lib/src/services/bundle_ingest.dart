import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

import '../archived_project.dart';
import '../deps.dart';
import '../ecosystem/ecosystems.dart';
import '../repository/scan_job_store.dart';
import 'dependency_analyzer.dart';
import 'git_fetcher.dart';
import 'scan_watch.dart';

/// An uploaded bundle, read and checked, or a [FormatException] whose message
/// is fit to answer the request with.
///
/// One function for both ingest routes, so `POST /projects` and
/// `POST /projects/<id>/bundle` cannot drift into accepting different things.
CollectedBundle readBundle(Object? raw, {required Ecosystems ecosystems}) {
  if (raw is! Map<String, dynamic>) {
    throw const FormatException(
      'bundle must be the JSON object written by `depcontrol collect`.',
    );
  }
  final bundle = CollectedBundle.fromJson(raw);
  BundleIngest.validate(bundle, ecosystems: ecosystems);
  return bundle;
}

/// Whether a request is too large to be a bundle, judged from what it claims
/// before any of it is read.
///
/// The declared length can be understated by a hostile client, which would only
/// mean the body was parsed before being refused — the caps on manifest and
/// package counts are what actually bound the work. This is the cheap refusal
/// that stops the obvious case.
bool bundleTooLarge(String? contentLength) {
  final declared = int.tryParse(contentLength ?? '');
  return declared != null && declared > BundleIngest.maxBytes;
}

/// What ingesting a bundle produced: a scan to answer with — freshly queued,
/// or the one already in flight for the same project or scan id — or a
/// [Response] refusing the upload outright.
class BundleIngestOutcome {
  const BundleIngestOutcome.accepted(this.status) : refusal = null;

  const BundleIngestOutcome.refused(Response response)
      : refusal = response,
        status = null;

  final ScanStatus? status;
  final Response? refusal;
}

/// The tail every bundle-ingest route shares: validate the bundle and the
/// scan id, apply the project-state checks a re-upload always has, fold into
/// an already-known scan where one exists, and otherwise enqueue.
///
/// [projectId] set means a re-upload to an existing project — the shape
/// `POST /projects/<id>/bundle` and `POST /collector/bundles` (paired to a
/// project) both have. Null means a new project, `POST /projects`'s shape.
/// Which it is also decides [ScanJobKind], exactly as `ScanJob.subject`'s own
/// doc explains: told apart by whether the job knew its project from the
/// start.
///
/// Does **not** check [bundleTooLarge] — that is judged from a header before
/// the body is read, and stays the caller's first move.
Future<BundleIngestOutcome> ingestBundle(
  Deps deps, {
  required String ownerId,
  required Object? rawBundle,
  required Object? rawScanId,
  String? projectId,
}) async {
  final CollectedBundle bundle;
  try {
    bundle = readBundle(rawBundle, ecosystems: deps.ecosystems);
  } on FormatException catch (e) {
    return BundleIngestOutcome.refused(
      Response.json(statusCode: HttpStatus.badRequest, body: {'error': e.message}),
    );
  }

  final scanId = scanIdFrom(rawScanId);
  if (scanId == null) {
    return BundleIngestOutcome.refused(
      Response.json(
        statusCode: HttpStatus.badRequest,
        body: {
          'error': 'scanId is required: 1-$kMaxScanIdLength characters of '
              'A-Z, a-z, 0-9, dot, dash or underscore',
        },
      ),
    );
  }

  if (projectId != null) {
    final project = await deps.repository.byId(projectId, ownerId: ownerId);
    if (project == null) {
      return BundleIngestOutcome.refused(
        Response.json(
          statusCode: HttpStatus.notFound,
          body: {'error': 'project not found'},
        ),
      );
    }

    final archived = archivedProjectRefusal(project, 're-analysis');
    if (archived != null) return BundleIngestOutcome.refused(archived);

    if (!project.isLocal) {
      return BundleIngestOutcome.refused(
        Response.json(
          statusCode: HttpStatus.conflict,
          body: {
            'error': '${project.name} is fetched from a repository',
            'reason': 'This project has a git URL, so it is brought up to '
                'date with POST /projects/<id>/refresh. Bundles are for '
                'repositories this server cannot reach.',
          },
        ),
      );
    }

    // A second upload while one is still running is somebody checking whether
    // the first registered — it carries a newer reading, so the running job is
    // returned rather than queuing a second one, and the caller can upload
    // again once it finishes.
    final running = await deps.scanJobs.unfinishedForProject(project.id);
    if (running != null) {
      return BundleIngestOutcome.accepted(running.toStatus());
    }
  }

  // The same scan asked for twice — a retried request, or a client that did
  // not hear the first answer. Returning the job it already has is the whole
  // of what "at most once" needs here.
  final existing = await deps.scanJobs.byId(scanId, ownerId: ownerId);
  if (existing != null) {
    return BundleIngestOutcome.accepted(existing.toStatus());
  }

  final now = DateTime.now().toUtc();
  final job = await deps.scanJobs.enqueue(
    ScanJob(
      id: scanId,
      ownerId: ownerId,
      kind: projectId == null ? ScanJobKind.add : ScanJobKind.refresh,
      bundle: bundle,
      projectId: projectId,
      progress: ScanProgress(
        phase: ScanPhase.queued,
        startedAt: now,
        phaseStartedAt: now,
      ),
      createdAt: now,
    ),
  );

  deps.scanRunner.wake();

  return BundleIngestOutcome.accepted(job.toStatus());
}

/// Reads an uploaded [CollectedBundle] into the form the analyzer already
/// takes.
///
/// The bundle arrives *parsed*, which is the whole point of the local collector:
/// the repository was read on the machine that holds it and only its dependency
/// facts travelled. So there is nothing to fetch and nothing to parse here — the
/// work is checking that what arrived is within the same bounds a fetched
/// repository would have been held to, and giving each manifest a name.
///
/// **Every field came from a client**, which is the posture to read this in. Not
/// a hostile-client posture exactly — a bundle only ever describes the uploader's
/// own project — but a bundle is JSON somebody can write by hand, and the caps
/// below are the same ones `GitFetcher` applies to a repository it downloads.
/// Without them the cheap path into the analyzer is also the unbounded one.
class BundleIngest {
  /// Most bundle bytes to accept.
  ///
  /// A real one is small: this repository, seven manifests and 238 package
  /// references, produces about 30 kB. The cap is orders of magnitude above
  /// anything legitimate and still small enough to hold in memory on a 512 MB
  /// machine without thinking about it.
  static const maxBytes = 4 * 1024 * 1024;

  /// Most manifests to read, matching what a fetched repository is capped at —
  /// the bundle path must not be the way to ask for a report the git path would
  /// have refused.
  static const maxManifests = GitFetcher.maxManifests;

  /// Most package references across the whole bundle.
  ///
  /// Counted across manifests rather than per manifest, because the cost is the
  /// registry lookups and those are per package wherever it was declared. The
  /// largest repository measured end to end resolved 1,491 packages, so this is
  /// several times the largest thing anybody has actually scanned.
  static const maxPackages = 10000;

  /// Checks a bundle is something this server will analyze, or throws with a
  /// message fit to answer a request with.
  ///
  /// [FormatException] throughout: every one of these is the caller's to fix,
  /// which is what separates them from the failures a scan discovers later.
  static void validate(CollectedBundle bundle, {required Ecosystems ecosystems}) {
    if (bundle.schema > CollectedBundle.currentSchema) {
      throw FormatException(
        'This bundle was written to schema ${bundle.schema} and this server '
        'reads up to ${CollectedBundle.currentSchema}. Upgrade the server, or '
        'collect again with an older depcontrol.',
      );
    }
    if (bundle.manifests.isEmpty) {
      throw const FormatException('This bundle describes no manifests.');
    }
    if (bundle.manifests.length > maxManifests) {
      throw FormatException(
        'This bundle describes ${bundle.manifests.length} manifests; at most '
        '$maxManifests can be analyzed.',
      );
    }
    if (bundle.packageCount > maxPackages) {
      throw FormatException(
        'This bundle names ${bundle.packageCount} package references; at most '
        '$maxPackages can be analyzed.',
      );
    }

    for (final manifest in bundle.manifests) {
      if (ecosystems.byId(manifest.ecosystem) == null) {
        throw FormatException(
          'This bundle holds a "${manifest.ecosystem}" manifest, which this '
          'server does not scan. It scans '
          '${ecosystems.all.map((e) => e.id).join(', ')}.',
        );
      }
    }
  }

  /// What this report was not told, in one sentence.
  ///
  /// Both disclosure flags land here rather than in fields of their own, because
  /// `coverageNote` is already the place a report admits to being partial and
  /// the frontend already renders it. Redaction without the label would leave a
  /// report rendering "manifest 3 of 7" with nothing saying why, and a withheld
  /// count that was quietly dropped would make `--exclude-private` a promise
  /// with no evidence it was kept.
  ///
  /// The collector's own note — the manifest cap, a file that would not parse —
  /// comes first, since it is about what was *read* rather than what was
  /// deliberately withheld.
  static String? coverageNoteFor(CollectedBundle bundle) {
    final parts = <String>[
      if (bundle.coverageNote case final note? when note.isNotEmpty) note,
      if (bundle.pathsRedacted)
        'Collected with --redact-paths, so manifests are numbered rather than '
            'named and no package name from this repository is shown.',
      if (bundle.privatePackagesWithheld > 0)
        '${bundle.privatePackagesWithheld} package reference'
            '${bundle.privatePackagesWithheld == 1 ? ' was' : 's were'} '
            'withheld by --exclude-private and '
            '${bundle.privatePackagesWithheld == 1 ? 'is' : 'are'} missing from '
            'these totals.',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// The bundle's manifests, named and ready to analyze.
  static List<AnalyzableManifest> read(CollectedBundle bundle) {
    final labels = _labelsFor(bundle);

    return [
      for (final (index, manifest) in bundle.manifests.indexed)
        (
          label: labels[index],
          ecosystem: manifest.ecosystem,
          // Null and empty are different answers here as everywhere: null says
          // the collector had no scanner for this ecosystem and nobody looked,
          // which must not become an accusation that nothing is used.
          imported: manifest.importedPackages?.toSet(),
          parsed: parse(manifest),
        ),
    ];
  }

  /// One collected manifest as the analyzer's own parsed form.
  ///
  /// A straight transcription — the reading was done by the same [Ecosystem]
  /// implementation on the developer's machine, which is what `packages/
  /// ecosystem` exists for. Nothing is re-derived here, because anything
  /// re-derived would be re-derived from less than the collector had.
  static ParsedManifest parse(CollectedManifest manifest) => ParsedManifest(
        packageName: manifest.packageName,
        dependencies: {
          for (final dependency in manifest.dependencies)
            if (!dependency.dev && dependency.name.isNotEmpty)
              dependency.name: DeclaredDependency(
                constraint: dependency.constraint,
                foreignOrigin: dependency.origin,
              ),
        },
        devDependencies: {
          for (final dependency in manifest.dependencies)
            if (dependency.dev && dependency.name.isNotEmpty)
              dependency.name: DeclaredDependency(
                constraint: dependency.constraint,
                foreignOrigin: dependency.origin,
              ),
        },
        locked: {
          for (final package in manifest.locked)
            if (package.name.isNotEmpty)
              package.name: LockedDependency(
                version: package.version,
                foreignOrigin: package.origin,
              ),
        },
      );

  /// What to call each manifest in the report.
  ///
  /// Redaction is answered here rather than at the collector, and positionally:
  /// a bundle collected with `--redact-paths` carries opaque ids, and a report
  /// that rendered one as though it were a directory name would be claiming to
  /// name something it was deliberately not told. "manifest 3 of 7" says exactly
  /// what is known — the same discipline as `coverageNote` and
  /// null-means-unmeasured.
  static List<String> _labelsFor(CollectedBundle bundle) {
    final total = bundle.manifests.length;
    if (bundle.pathsRedacted) {
      return [
        for (var i = 1; i <= total; i++) 'manifest $i of $total',
      ];
    }

    final plain = [for (final m in bundle.manifests) _plainLabel(m)];

    // Qualified by ecosystem only where it has to be, exactly as a fetched
    // repository is: a root holding both a `pubspec.yaml` and a `package.json`
    // has two manifests that would otherwise both be called "repository root".
    return [
      for (final (index, manifest) in bundle.manifests.indexed)
        plain.where((label) => label == plain[index]).length > 1
            ? '${plain[index]} (${manifest.ecosystem})'
            : plain[index],
    ];
  }

  static String _plainLabel(CollectedManifest manifest) {
    final fileName = manifest.fileName;
    if (fileName == null || fileName.isEmpty) {
      return manifest.directory.isEmpty ? 'repository root' : manifest.directory;
    }
    return manifest.directory.isEmpty
        ? fileName
        : '${manifest.directory}/$fileName';
  }
}
