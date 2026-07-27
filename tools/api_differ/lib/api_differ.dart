/// Compares the public API of two published versions of a pub package.
library;

import 'src/api_surface.dart';
import 'src/pub_archive_client.dart';

export 'src/api_surface.dart'
    show ApiChange, ApiChangeKind, ApiSurface, diffSurfaces, extractSurface;
export 'src/pub_archive_client.dart' show ArchiveRejected, PubArchiveClient;

/// The result of comparing two versions.
class ApiDiff {
  const ApiDiff({
    required this.package,
    required this.from,
    required this.to,
    required this.changes,
  });

  final String package;
  final String from;
  final String to;
  final List<ApiChange> changes;

  List<ApiChange> get removed =>
      changes.where((c) => c.kind == ApiChangeKind.removed).toList();

  List<ApiChange> get changed =>
      changes.where((c) => c.kind == ApiChangeKind.changed).toList();

  List<ApiChange> get added =>
      changes.where((c) => c.kind == ApiChangeKind.added).toList();

  Map<String, dynamic> toJson() => {
        'package': package,
        'from': from,
        'to': to,
        'changes': changes.map((c) => c.toJson()).toList(),
      };
}

/// Downloads both versions and compares their public surfaces.
///
/// Returns null when either version's sources are unavailable — an empty diff
/// would otherwise read as "nothing changed".
Future<ApiDiff?> compareVersions(
  String package, {
  required String from,
  required String to,
  PubArchiveClient? client,
}) async {
  final archives = client ?? PubArchiveClient();
  try {
    final beforeSources = await archives.libSources(package, from);
    final afterSources = await archives.libSources(package, to);
    if (beforeSources.isEmpty || afterSources.isEmpty) return null;

    return ApiDiff(
      package: package,
      from: from,
      to: to,
      changes: diffSurfaces(
        extractSurface(beforeSources),
        extractSurface(afterSources),
      ),
    );
  } finally {
    if (client == null) archives.close();
  }
}
