import 'package:pub_semver/pub_semver.dart';

import 'nuget_version.dart';

/// Reads NuGet's version-range syntax into the [VersionConstraint] the rest of
/// the application works in.
///
/// **The trap here is the bare version.** `<PackageReference Version="1.0" />`
/// does not mean "1.0". It means *at least* 1.0, with no upper bound — NuGet's
/// documentation is explicit that a bare version is the minimum and that
/// restoring it can install anything above. Every other ecosystem this
/// application reads treats a bare version as an exact pin, so handing
/// `1.0` to any of the other parsers produces a constraint that is wrong in
/// the direction that matters: it rejects the version actually installed, and
/// the report then disagrees with the machine it is describing.
///
/// The bracket forms are the interval notation from school, and they mean
/// exactly what they look like:
///
/// | Written | Means |
/// |---|---|
/// | `1.0` | `>=1.0.0` |
/// | `[1.0]` | exactly 1.0.0 |
/// | `[1.0,2.0)` | `>=1.0.0 <2.0.0` |
/// | `(1.0,2.0]` | `>1.0.0 <=2.0.0` |
/// | `[1.0,)` | `>=1.0.0` |
/// | `(,2.0]` | `<=2.0.0` |
/// | `1.*` | `>=1.0.0 <2.0.0` |
/// | `*` | anything |
///
/// Anything else returns null, including `(,)` — which NuGet itself rejects —
/// and the floating forms with a pre-release filter (`1.0.0-*`). Null is a
/// per-dependency answer, not a failed report: that package resolves as unknown
/// and the report says so.
///
/// Reference: https://learn.microsoft.com/en-us/nuget/concepts/package-versioning#version-ranges
VersionConstraint? parseNuGetRange(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // Floating versions. `*` is any; `1.*` and `1.2.*` clear the line below them.
  // A floating pre-release (`1.0.0-*`) is deliberately not read: it selects
  // among pre-releases of one version, which is a resolution rule rather than
  // a range, and pretending otherwise would admit stable versions the project
  // did not ask for.
  if (text == '*') return VersionConstraint.any;
  if (text.endsWith('.*') && !text.contains('-')) {
    return _floating(text.substring(0, text.length - 2));
  }

  final opensInclusive = text.startsWith('[');
  final opensExclusive = text.startsWith('(');
  if (!opensInclusive && !opensExclusive) {
    // A bare version: the minimum, not the pin.
    final min = NuGetVersion.tryParse(text);
    return min == null ? null : VersionRange(min: min, includeMin: true);
  }

  final closesInclusive = text.endsWith(']');
  final closesExclusive = text.endsWith(')');
  if (!closesInclusive && !closesExclusive) return null;

  final inner = text.substring(1, text.length - 1);
  final comma = inner.indexOf(',');

  // `[1.0]` — the one form with no comma, and the only way NuGet writes an
  // exact version. `(1.0)` is not a range at all and NuGet rejects it.
  if (comma < 0) {
    if (!opensInclusive || !closesInclusive) return null;
    return NuGetVersion.tryParse(inner);
  }
  if (inner.indexOf(',', comma + 1) >= 0) return null;

  final lower = inner.substring(0, comma).trim();
  final upper = inner.substring(comma + 1).trim();

  // `(,)` states nothing at all, and NuGet treats it as invalid rather than as
  // "any". Reading it as "any" here would silently widen a constraint the
  // manifest never expressed.
  if (lower.isEmpty && upper.isEmpty) return null;

  Version? min;
  if (lower.isNotEmpty) {
    min = NuGetVersion.tryParse(lower);
    if (min == null) return null;
  }

  Version? max;
  if (upper.isNotEmpty) {
    max = NuGetVersion.tryParse(upper);
    if (max == null) return null;
  }

  return VersionRange(
    min: min,
    max: max,
    includeMin: min != null && opensInclusive,
    includeMax: max != null && closesInclusive,
  );
}

/// `1.*` and `1.2.*`, as the range they stand for.
///
/// `1.*` is every 1.x, so `>=1.0.0 <2.0.0`; `1.2.*` is `>=1.2.0 <1.3.0`. NuGet
/// resolves a float to the highest matching release, which is what the upper
/// bound has to leave room for.
VersionConstraint? _floating(String prefix) {
  final parts = prefix.split('.');
  if (parts.isEmpty || parts.length > 3) return null;

  final numbers = <int>[0, 0, 0];
  for (var i = 0; i < parts.length; i++) {
    final value = int.tryParse(parts[i]);
    if (value == null || value < 0) return null;
    numbers[i] = value;
  }

  final (major, minor, patch) = (numbers[0], numbers[1], numbers[2]);
  final max = switch (parts.length) {
    1 => Version(major + 1, 0, 0),
    2 => Version(major, minor + 1, 0),
    _ => Version(major, minor, patch + 1),
  };

  return VersionRange(
    min: Version(major, minor, patch),
    max: max,
    includeMin: true,
  );
}
