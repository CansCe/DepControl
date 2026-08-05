/// Where a repository's manifests are, worked out from paths alone.
///
/// Every question here is answered from a list of file names: which paths are a
/// manifest and whose, which package a source file belongs to, where a
/// companion file is found, and which paths are generated rather than written.
/// None of it needs the files' contents and none of it needs the network, which
/// is what lets a repository be laid out the same way twice — once by the server
/// reading a downloaded tarball, once by the collector walking a working tree on
/// somebody's own machine.
///
/// That sameness is the point. Two implementations of "which pubspec owns this
/// `.dart` file" would disagree eventually, and the disagreement would surface
/// as a package attributed to the wrong manifest in a report nobody re-derives.
library;

import 'manifest.dart';

/// Where a manifest sits in a repository, and which ecosystem's it is.
class ManifestLocation {
  const ManifestLocation({
    required this.directory,
    required this.ecosystem,
    required this.fileName,
  });

  /// Path from the repository root, empty for the root itself.
  final String directory;

  /// The `Ecosystem.id` whose manifest was found here.
  final String ecosystem;

  /// The manifest's own file name.
  ///
  /// Carried rather than derived from the ecosystem, because .NET names its
  /// project file after the project: there is no `naming.manifest` to look up
  /// once the file has been found, and one directory can legitimately hold
  /// `Acme.csproj` and `Acme.Tests.csproj`.
  final String fileName;

  /// The full path of the manifest, root-relative.
  String get path => directory.isEmpty ? fileName : '$directory/$fileName';

  /// Identity within a repository. The directory alone will not do: one
  /// directory can hold two .NET projects, and one directory can hold a
  /// `pubspec.yaml` beside a `package.json`.
  String get key => '$ecosystem:$path';

  @override
  String toString() => 'ManifestLocation($key)';
}

/// Where [path] is a manifest, which ecosystem's and in which directory, or
/// null for everything else — which is nearly every path in a repository.
///
/// Checks the file name first because this runs once per file in the tree.
ManifestLocation? manifestAt(String path, Iterable<ManifestNaming> naming) {
  final name = fileNameOf(path);
  for (final names in naming) {
    if (!names.isManifest(name)) continue;
    final slash = path.lastIndexOf('/');
    return ManifestLocation(
      directory: slash < 0 ? '' : path.substring(0, slash),
      ecosystem: names.ecosystem,
      fileName: name,
    );
  }
  return null;
}

/// The order manifests should be read in when there are more of them than the
/// budget allows.
///
/// Demonstrations after everything else: `bloc` keeps 23 example apps under
/// `examples/` and its actual libraries under `packages/`, and a plain
/// alphabetical sort spends the whole budget on the examples and reports
/// nothing about the library anyone came to read about. Then shallowest first,
/// so the root leads when there is one.
int compareByReadingOrder(ManifestLocation a, ManifestLocation b) {
  final aIncidental = isIncidentalDirectory(a.directory);
  final bIncidental = isIncidentalDirectory(b.directory);
  if (aIncidental != bIncidental) return aIncidental ? 1 : -1;

  final byDepth = _depth(a.directory).compareTo(_depth(b.directory));
  if (byDepth != 0) return byDepth;

  final byPath = a.directory.compareTo(b.directory);
  return byPath != 0 ? byPath : a.ecosystem.compareTo(b.ecosystem);
}

/// The deepest manifest of [ecosystem] in [locations] whose directory contains
/// [path], or null when none does.
///
/// A file belongs to the package nearest above it, not to the root: in a
/// monorepo `tools/differ/lib/x.dart` is the differ's source, and counting its
/// imports against the root would report the root as depending on packages it
/// has never heard of.
///
/// Restricted to one ecosystem because "nearest" has to mean nearest *of the
/// right kind*. In a Flutter app with a JavaScript front end under `web/`, the
/// manifest nearest a `.dart` file may well be `web/package.json`, and
/// attributing Dart imports to it would report an npm package as depending on
/// Dart packages.
ManifestLocation? nearestManifest(
  String path,
  Iterable<ManifestLocation> locations,
  String ecosystem,
) {
  ManifestLocation? best;
  for (final location in locations) {
    if (location.ecosystem != ecosystem) continue;
    if (location.directory.isEmpty) {
      best ??= location;
      continue;
    }
    if (!path.startsWith('${location.directory}/')) continue;
    if (best == null || location.directory.length > best.directory.length) {
      best = location;
    }
  }
  return best;
}

/// The companion files [naming] asks for, read from [read] at or above
/// [directory], nearest first.
///
/// Nearest wins and the search walks upward, because that is how MSBuild finds
/// a `Directory.Packages.props`: the one in the project's own directory beats
/// the one at the repository root. A companion nobody committed is simply
/// absent, which the parser is expected to cope with — it is a file the
/// manifest may need, not one it must have.
Map<String, String> companionsFor(
  ManifestNaming naming,
  String directory,
  String? Function(String path) read,
) {
  if (naming.companionFiles.isEmpty) return const {};

  final found = <String, String>{};
  for (final name in naming.companionFiles) {
    var at = directory;
    while (true) {
      final content = read(at.isEmpty ? name : '$at/$name');
      if (content != null) {
        found[name] = content;
        break;
      }
      if (at.isEmpty) break;
      final slash = at.lastIndexOf('/');
      at = slash < 0 ? '' : at.substring(0, slash);
    }
  }
  return found;
}

/// Whether a repository path is generated, vendored, or otherwise not the
/// project's own code.
///
/// `build` is here because Dart and Flutter both write there; a repository that
/// keeps hand-written source in a directory of that name loses those imports,
/// which costs a false "declared but not imported" rather than a false
/// accusation of using something undeclared.
bool isGeneratedPath(String path) {
  for (final segment in path.split('/')) {
    if (generatedSegments.contains(segment)) return true;
  }
  return false;
}

/// Directory names whose contents are outputs or third-party copies.
///
/// Committed output only. A working tree holds more of it — `obj/` under every
/// .NET project, and whatever the last build left behind — but that is the
/// collector's problem and not this list's: these are the names worth skipping
/// in a repository somebody published, and a repository that publishes its
/// `obj/` is telling us something we should not silently discard.
const generatedSegments = {
  '.dart_tool',
  '.git',
  '.symlinks',
  'build',
  'node_modules',
  'Pods',
};

/// Whether a package is a demonstration or fixture rather than something the
/// repository exists to ship.
///
/// These are still read and still reported — an example app's dependencies are
/// as capable of carrying an advisory as any other. They just go last, so that
/// when a repository has more packages than the budget the ones dropped are the
/// ones nobody opened the report to see.
bool isIncidentalDirectory(String directory) {
  for (final segment in directory.split('/')) {
    if (_incidentalSegments.contains(segment)) return true;
  }
  return false;
}

const _incidentalSegments = {
  'example',
  'examples',
  'sample',
  'samples',
  'demo',
  'demos',
  'fixture',
  'fixtures',
  'testdata',
};

/// The last segment of a `/`-separated path.
String fileNameOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

int _depth(String directory) =>
    directory.isEmpty ? 0 : directory.split('/').length;
