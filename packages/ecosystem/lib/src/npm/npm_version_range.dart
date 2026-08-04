import 'package:pub_semver/pub_semver.dart';

/// Reads npm's version-range syntax into the [VersionConstraint] the resolver
/// works in.
///
/// Both ecosystems are semver, which is why resolution is shared code — but
/// they do not write ranges the same way, and one of the differences is a trap
/// rather than a spelling. `pub_semver` will happily parse `^0.0.3` and mean
/// `>=0.0.3 <0.1.0`; npm means `>=0.0.3 <0.0.4`. Handing an npm constraint
/// straight to [VersionConstraint.parse] therefore produces an answer that is
/// wrong in the direction that matters — it admits versions the manifest
/// excludes, so a resolution can land on a release the project never allowed
/// and report it as installed.
///
/// npm also has three constructions pub has none of: `||` unions, `x`
/// wildcards, and hyphen ranges. Those are ordinary in published manifests
/// rather than exotic.
///
/// Anything this cannot read returns null. That is a per-dependency answer, not
/// a failed report: the package resolves as unknown and the report says so,
/// which is what already happens for a git or path dependency.
///
/// Reference: https://github.com/npm/node-semver#ranges
VersionConstraint? parseNpmRange(String raw) {
  final text = raw.trim();

  // An empty range, `*` and `latest` all mean "whatever you have". `latest` is
  // a dist-tag rather than a range, but it appears in manifests and refusing it
  // would report a dependency nobody has a problem with as unresolvable.
  if (text.isEmpty ||
      text == '*' ||
      text == 'x' ||
      text == 'X' ||
      text == 'latest') {
    return VersionConstraint.any;
  }

  // A union: any of the alternatives will do.
  if (text.contains('||')) {
    final parts = text.split('||');
    final alternatives = <VersionConstraint>[];
    for (final part in parts) {
      final parsed = parseNpmRange(part);
      // One unreadable alternative makes the whole union unreadable: dropping
      // it would narrow the constraint, and a narrower constraint rejects
      // versions the manifest allows.
      if (parsed == null) return null;
      alternatives.add(parsed);
    }
    return VersionConstraint.unionOf(alternatives);
  }

  // A hyphen range, `1.2.3 - 2.3.4`, inclusive at both ends. Detected before
  // the space split below, which would otherwise see three comparators.
  final hyphen = _hyphenRange.firstMatch(text);
  if (hyphen != null) {
    final min = _lowerBound(hyphen.group(1)!);
    final max = _hyphenUpperBound(hyphen.group(2)!);
    if (min == null || max == null) return null;
    return VersionRange(
      min: min,
      max: max.version,
      includeMin: true,
      includeMax: max.inclusive,
    );
  }

  // Otherwise a conjunction: every space-separated comparator must hold.
  final parts = text.split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final constraints = <VersionConstraint>[];
  for (final part in parts) {
    final parsed = _comparator(part);
    if (parsed == null) return null;
    constraints.add(parsed);
  }
  if (constraints.isEmpty) return VersionConstraint.any;

  return constraints.reduce((a, b) => a.intersect(b));
}

/// One comparator: `^1.2.3`, `~1.2`, `>=1.0.0`, `1.x`, `=1.2.3`, `v1.2.3`.
VersionConstraint? _comparator(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return VersionConstraint.any;
  if (text == '*' || text == 'x' || text == 'X') return VersionConstraint.any;

  if (text.startsWith('^')) return _caret(text.substring(1));
  if (text.startsWith('~')) return _tilde(text.substring(1));

  for (final op in const ['>=', '<=', '>', '<', '=']) {
    if (!text.startsWith(op)) continue;
    final rest = text.substring(op.length).trim();
    if (op == '=') return _exact(rest);

    // A partial version stands for a range, and which end of it a comparator
    // wants differs: `>=1.2` starts at 1.2.0, while `>1.2` has to clear the
    // whole 1.2 line and so starts at 1.3.0. `<=1.2` is the mirror of that.
    final bound = op == '>' || op == '<=' ? _upperOf(rest) : _lowerBound(rest);
    if (bound == null) return null;

    // Whether the bound itself is admitted depends on both the operator and
    // whether the version was partial. `>1.2.3` excludes 1.2.3, but `>1.2` has
    // already been turned into 1.3.0 by [_upperOf] — and 1.3.0 *is* allowed,
    // so the bound that stands in for the partial is inclusive. The same
    // reasoning mirrored gives `<=1.2` an exclusive 1.3.0.
    final partial = _isPartial(rest);

    return switch (op) {
      '>=' || '>' => VersionRange(
          min: bound,
          includeMin: op == '>=' || partial,
        ),
      '<=' => VersionRange(max: bound, includeMax: !partial),
      _ => VersionRange(max: bound),
    };
  }

  // A wildcard or partial version: `1.x`, `1.2.*`, `1`, `1.2`.
  if (_isPartial(text)) return _partialRange(text);

  return _exact(text);
}

/// npm's caret: everything up to the next change in the leftmost non-zero
/// component.
///
/// This is the one that differs from pub below 1.0.0. `^0.2.3` allows the rest
/// of 0.2, and `^0.0.3` allows nothing but 0.0.3 — because in npm's reading the
/// leftmost non-zero component of `0.0.3` is the patch, so a patch bump is a
/// breaking change. pub reads `^0.0.3` as `>=0.0.3 <0.1.0`, admitting 0.0.4.
VersionConstraint? _caret(String raw) {
  final parsed = _partsOf(raw);
  if (parsed == null) return null;

  final min = _lowerBound(raw);
  if (min == null) return null;

  final (major, minor, patch, precision) = parsed;

  final Version max;
  if (major != 0) {
    max = Version(major + 1, 0, 0);
  } else if (minor != 0 || precision < 2) {
    // `^0.2.3` -> <0.3.0, and `^0` -> <1.0.0 since the minor is unstated.
    max = precision < 2 ? Version(1, 0, 0) : Version(0, minor + 1, 0);
  } else if (patch != 0 || precision < 3) {
    // `^0.0.3` -> <0.0.4, and `^0.0` -> <0.1.0 since the patch is unstated.
    max = precision < 3 ? Version(0, 1, 0) : Version(0, 0, patch + 1);
  } else {
    // `^0.0.0` -> only 0.0.0.
    max = Version(0, 0, 1);
  }

  return VersionRange(min: min, max: max, includeMin: true);
}

/// npm's tilde: patch-level changes when a minor is stated, minor-level when it
/// is not. `~1.2.3` -> `>=1.2.3 <1.3.0`; `~1` -> `>=1.0.0 <2.0.0`.
VersionConstraint? _tilde(String raw) {
  final parsed = _partsOf(raw);
  if (parsed == null) return null;

  final min = _lowerBound(raw);
  if (min == null) return null;

  final (major, minor, _, precision) = parsed;
  final max = precision >= 2 ? Version(major, minor + 1, 0) : Version(major + 1, 0, 0);

  return VersionRange(min: min, max: max, includeMin: true);
}

/// A partial version read as its lowest member: `1.2` -> 1.2.0, `1` -> 1.0.0.
Version? _lowerBound(String raw) {
  final parsed = _partsOf(raw);
  if (parsed == null) return null;
  final (major, minor, patch, _) = parsed;

  // A full version keeps its pre-release and build metadata, which decide
  // ordering and cannot be reconstructed from the numbers alone.
  final full = _exactVersion(raw);
  return full ?? Version(major, minor, patch);
}

/// The version just past a partial range, for the comparators that need to
/// clear it: `>1.2` starts after all of 1.2, so at 1.3.0.
Version? _upperOf(String raw) {
  final parsed = _partsOf(raw);
  if (parsed == null) return null;
  final (major, minor, patch, precision) = parsed;

  return switch (precision) {
    1 => Version(major + 1, 0, 0),
    2 => Version(major, minor + 1, 0),
    _ => _exactVersion(raw) ?? Version(major, minor, patch),
  };
}

/// The upper end of a hyphen range, which is inclusive when fully stated and
/// exclusive-of-the-next-line when partial: `1.2.3 - 2.3` ends below 2.4.0.
({Version version, bool inclusive})? _hyphenUpperBound(String raw) {
  final parsed = _partsOf(raw);
  if (parsed == null) return null;
  final (major, minor, _, precision) = parsed;

  return switch (precision) {
    1 => (version: Version(major + 1, 0, 0), inclusive: false),
    2 => (version: Version(major, minor + 1, 0), inclusive: false),
    _ => switch (_exactVersion(raw)) {
        final v? => (version: v, inclusive: true),
        _ => null,
      },
  };
}

/// `1.x`, `1.2.*` and bare `1` / `1.2` as the range they stand for.
VersionConstraint? _partialRange(String raw) {
  final parsed = _partsOf(raw);
  if (parsed == null) return null;
  final (major, minor, _, precision) = parsed;

  if (precision < 1) return VersionConstraint.any;

  final min = Version(major, precision >= 2 ? minor : 0, 0);
  final max = precision >= 2 ? Version(major, minor + 1, 0) : Version(major + 1, 0, 0);

  return VersionRange(min: min, max: max, includeMin: true);
}

VersionConstraint? _exact(String raw) {
  final version = _exactVersion(raw);
  if (version != null) return version;
  return _isPartial(raw) ? _partialRange(raw) : null;
}

Version? _exactVersion(String raw) {
  try {
    return Version.parse(_stripV(raw));
  } on FormatException {
    return null;
  }
}

/// Whether [raw] states fewer than three components, or wildcards one.
bool _isPartial(String raw) {
  final text = _stripV(raw);
  if (text.isEmpty) return false;
  final head = text.split(RegExp('[-+]')).first;
  final parts = head.split('.');
  if (parts.length < 3) return true;
  return parts.any((p) => p == 'x' || p == 'X' || p == '*');
}

/// [raw] as (major, minor, patch, precision), where precision is how many
/// components were actually stated before any wildcard. Null when it is not a
/// version at all.
(int, int, int, int)? _partsOf(String raw) {
  final text = _stripV(raw);
  if (text.isEmpty) return null;

  final head = text.split(RegExp('[-+]')).first;
  final parts = head.split('.');

  var precision = 0;
  final numbers = <int>[0, 0, 0];

  for (var i = 0; i < parts.length && i < 3; i++) {
    final part = parts[i];
    if (part == 'x' || part == 'X' || part == '*' || part.isEmpty) break;
    final value = int.tryParse(part);
    if (value == null || value < 0) return null;
    numbers[i] = value;
    precision = i + 1;
  }

  if (parts.length > 3) return null;
  return (numbers[0], numbers[1], numbers[2], precision);
}

String _stripV(String raw) {
  final text = raw.trim();
  return text.startsWith('v') || text.startsWith('V')
      ? text.substring(1).trim()
      : text;
}

/// `1.2.3 - 2.3.4`, with the hyphen surrounded by whitespace so it is not
/// mistaken for a pre-release separator.
final _hyphenRange = RegExp(r'^(\S+)\s+-\s+(\S+)$');
