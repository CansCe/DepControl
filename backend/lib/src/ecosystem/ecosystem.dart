import 'package:pub_semver/pub_semver.dart';

import 'manifest.dart';
import 'package_registry.dart';

export 'manifest.dart';
export 'package_registry.dart';

/// A package ecosystem: one set of manifest files, one registry, one dialect of
/// version constraints, one way of writing an import.
///
/// This exists because a dependency report is the same document whichever
/// ecosystem produced it. "Which packages, at which versions, with which
/// advisories and licenses, reachable from which manifests" is a question about
/// software, not about pub.dev — and answering it for exactly one language
/// limits the tool to the small fraction of repositories written in that
/// language.
///
/// What is *not* behind this interface is as deliberate as what is. Advisories
/// are OSV documents and versions are semver in both ecosystems supported here,
/// so scoring, banding, blame assignment, license classification, resolution
/// and remediation planning are shared code that never learns which ecosystem
/// it is serving. Only the four genuinely divergent things are per-ecosystem:
/// file names, manifest syntax, registry protocol, and constraint dialect.
abstract class Ecosystem {
  /// Stable identifier, stored on every [DepNode] and never shown to a user:
  /// `dart`, `npm`. Persisted, so it does not change once written.
  String get id;

  /// What to call this ecosystem in a report.
  String get displayName;

  /// What this ecosystem's files are called, for repository discovery.
  ManifestNaming get naming;

  /// Where this ecosystem's published packages are looked up.
  PackageRegistry get registry;

  /// Reads a manifest and its lockfile.
  ///
  /// Throws [FormatException] on a manifest this ecosystem cannot parse. A
  /// broken manifest is the user's to fix and the message should say so; it is
  /// not a reason to report a repository as having no dependencies.
  ParsedManifest parse(ManifestFiles files);

  /// Reads which packages a repository's own source reaches for, or null where
  /// no scanner exists for this ecosystem.
  ///
  /// Null rather than a scanner returning the empty set. "Nobody looked" and
  /// "nothing uses it" are different claims and only one of them is worth
  /// acting on — see [DepNode.imported].
  SourceScanner? get sourceScanner;

  /// Reads a constraint written in this ecosystem's dialect, or null when it is
  /// not something resolution can work with.
  ///
  /// Both ecosystems here use semver ranges, but they do not write them the
  /// same way: pub has no `||`, no `1.2.x` wildcards and no hyphen ranges, all
  /// of which are ordinary in npm. Returning null rather than throwing keeps an
  /// exotic constraint on one dependency from failing the whole report — that
  /// package resolves as unknown and says so.
  VersionConstraint? parseConstraint(String text);

  /// How this ecosystem writes "at least [version]" in a manifest, for the
  /// remediation diffs. Both write `^1.2.3`, and they mean subtly different
  /// things by it below 1.0.0, which is why this is not a shared helper.
  String constraintAtLeast(Version version);
}

/// Reads which packages a project's own source actually reaches for.
///
/// A manifest says what a project is *allowed* to use. Only the source says
/// what it *does* use, and the gap between the two is where two ordinary bugs
/// live: a declared dependency nothing imports, and an imported package nothing
/// declares.
abstract class SourceScanner {
  /// Package names imported by [sources].
  ///
  /// [auxiliary] carries the non-source files named by
  /// [ManifestNaming.auxiliaryFiles] — files that reference a package without
  /// any import mentioning it.
  Set<String> scan(
    Iterable<String> sources, {
    Iterable<String> auxiliary = const [],
  });
}
