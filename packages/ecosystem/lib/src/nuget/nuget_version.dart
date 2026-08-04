import 'package:pub_semver/pub_semver.dart';

/// Reads NuGet's version syntax into the semver `pub_semver` works in.
///
/// **NuGet versions are not semver, and the difference is a fourth number.**
/// `NHibernate 5.2.7.4000` is an ordinary published version; so is
/// `4.5.0.0`. `Version.parse` throws on both, and `pub_semver` is load-bearing
/// far past this file — the analyzer's outdated check, `Advisory.affects`, the
/// upgrade risk banding and the resolver all compare parsed versions.
///
/// What makes this worth its own file is the *shape* of the failure. Every
/// consumer of a version string in this codebase parses it through a tolerant
/// `tryParse` that returns null rather than throwing, because a registry can
/// always serve something strange. So an unnormalised `5.2.7.4000` does not
/// crash a scan: it produces a node that is never outdated, never affected by
/// an advisory, and never risk-banded — a report that looks complete and
/// quietly says nothing. Normalising here, at the ecosystem boundary, is what
/// keeps that from being the default answer for every .NET project.
///
/// The revision becomes build metadata: `5.2.7.4000` → `5.2.7+4000`.
///
/// **`pub_semver` orders build metadata, and the semver specification does
/// not.** That divergence — documented on `Version.compareTo`, and the reason
/// this mapping is worth using at all — is what makes the revision survive:
/// `5.2.7 < 5.2.7+4000 < 5.2.7+5000`, which is the order NuGet itself puts
/// those releases in. Had build metadata been ignored, as the specification
/// says it should be, two releases differing only in the revision would compare
/// equal and a project pinned to the older one would never be reported as
/// behind.
///
/// It reads correctly in the other direction too. An advisory range of
/// `>=5.2.0 <5.3.0` still admits `5.2.7+4000`, so the revision does not hide a
/// vulnerable package from a range written without one.
///
/// Reference: https://learn.microsoft.com/en-us/nuget/concepts/package-versioning
class NuGetVersion {
  const NuGetVersion._();

  /// [text] as a comparable version, or null when it is not one.
  ///
  /// Null rather than throwing, for the reason every parser here returns null:
  /// one unreadable version in a manifest must not fail the report. That
  /// package is reported with an unknown version and the report says so.
  static Version? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    // Split off pre-release and build metadata before counting numbers, so the
    // dots inside `1.0.0-beta.1` are not mistaken for a fourth component.
    final plus = trimmed.indexOf('+');
    final withoutBuild = plus < 0 ? trimmed : trimmed.substring(0, plus);
    final original = plus < 0 ? null : trimmed.substring(plus + 1);

    final dash = withoutBuild.indexOf('-');
    final core = dash < 0 ? withoutBuild : withoutBuild.substring(0, dash);
    final preRelease = dash < 0 ? null : withoutBuild.substring(dash + 1);
    // `1.0.0-*` is a floating pre-release — a resolution rule, not a version.
    // It reaches here because it is shaped like one.
    if (preRelease != null &&
        (preRelease.isEmpty || preRelease.contains('*'))) {
      return null;
    }

    final parts = core.split('.');
    if (parts.isEmpty || parts.length > 4) return null;

    final numbers = <int>[0, 0, 0, 0];
    for (var i = 0; i < parts.length; i++) {
      final value = int.tryParse(parts[i]);
      // `int.tryParse` accepts a leading `+` and `-`; a version component is
      // digits and nothing else.
      if (value == null || value < 0 || !_digits.hasMatch(parts[i])) return null;
      numbers[i] = value;
    }

    // NuGet normalises a zero revision away — `1.2.3.0` *is* `1.2.3`, and the
    // registry serves it under that name. Carrying the zero through would put
    // a `+0` on most four-part versions for no gain.
    final revision = numbers[3];
    final build = revision != 0 ? '$revision' : original;

    return Version(
      numbers[0],
      numbers[1],
      numbers[2],
      pre: preRelease,
      build: build,
    );
  }

  /// [text] as the string form the rest of the application stores and compares.
  ///
  /// This is what lands in `DepNode.installed`, so it is deliberately the
  /// *normalised* text rather than the manifest's own: everything downstream
  /// parses that field with `Version.parse`, and a string it cannot read is a
  /// node nothing can say anything about. `5.2.7.4000` is therefore stored and
  /// displayed as `5.2.7+4000`.
  ///
  /// Null when [text] is not a version, which callers turn into "unknown"
  /// rather than into a guess.
  static String? normalise(String text) => tryParse(text)?.toString();

  /// [version] written back in NuGet's own spelling.
  ///
  /// The inverse of the revision rule above: a build made only of digits was a
  /// fourth component when it arrived, so it goes back as one. A manifest edit
  /// this application suggests has to be a manifest edit NuGet can read, and
  /// `5.2.7+4000` is not one.
  static String format(Version version) {
    final build = version.build.join('.');
    if (build.isEmpty || !_digits.hasMatch(build)) return version.toString();
    final pre = version.preRelease.isEmpty ? '' : '-${version.preRelease.join('.')}';
    return '${version.major}.${version.minor}.${version.patch}.$build$pre';
  }

  /// How NuGet writes "at least [version]" in a manifest.
  ///
  /// The bracket form rather than a bare `5.2.7`, because NuGet reads a bare
  /// version as a *minimum* already — but only in a `PackageReference`, and
  /// only when nothing else pins it. `[5.2.7,)` says the same thing in the one
  /// spelling that means it everywhere.
  static String atLeast(Version version) => '[${format(version)},)';

  static final _digits = RegExp(r'^\d+$');
}
