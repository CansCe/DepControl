import 'dart:math' as math;

/// A parsed CVSS v3 base-score vector.
///
/// Only the Base metric group is read. Advisories publish base vectors; the
/// Temporal and Environmental groups describe a specific deployment, which a
/// dependency scanner is in no position to know anything about.
///
/// The arithmetic is the CVSS v3.1 specification's, section 7.1. It is written
/// out rather than pulled in as a dependency because it is thirty lines that
/// never change, and because the published scores in every advisory make it
/// straightforwardly checkable.
class CvssV3 {
  const CvssV3._({
    required this.attackVector,
    required this.attackComplexity,
    required this.privilegesRequired,
    required this.userInteraction,
    required this.scopeChanged,
    required this.confidentiality,
    required this.integrity,
    required this.availability,
  });

  final double attackVector;
  final double attackComplexity;

  /// Raw code, because its weight depends on [scopeChanged].
  final String privilegesRequired;
  final double userInteraction;
  final bool scopeChanged;
  final double confidentiality;
  final double integrity;
  final double availability;

  static const _attackVector = {
    'N': 0.85,
    'A': 0.62,
    'L': 0.55,
    'P': 0.2,
  };
  static const _attackComplexity = {'L': 0.77, 'H': 0.44};
  static const _userInteraction = {'N': 0.85, 'R': 0.62};
  static const _impact = {'H': 0.56, 'L': 0.22, 'N': 0.0};

  /// Privileges Required is the one metric weighted by Scope: needing
  /// privileges matters less when the attack escapes the thing it started in.
  static const _privilegesUnchanged = {'N': 0.85, 'L': 0.62, 'H': 0.27};
  static const _privilegesChanged = {'N': 0.85, 'L': 0.68, 'H': 0.50};

  /// Parses a vector such as
  /// `CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N`.
  ///
  /// Returns null for anything that is not a complete v3 base vector — a v2
  /// vector, a v4 one, or a truncated string. A wrong score would be worse
  /// than none: it is the number someone triages by.
  static CvssV3? parse(String? vector) {
    if (vector == null) return null;

    final parts = vector.split('/');
    if (parts.isEmpty) return null;

    final version = parts.first;
    if (!version.startsWith('CVSS:3')) return null;

    final metrics = <String, String>{};
    for (final part in parts.skip(1)) {
      final split = part.split(':');
      if (split.length != 2) return null;
      metrics[split[0]] = split[1];
    }

    final scope = metrics['S'];
    if (scope != 'U' && scope != 'C') return null;
    final scopeChanged = scope == 'C';

    final privileges = metrics['PR'];
    final privilegeWeights =
        scopeChanged ? _privilegesChanged : _privilegesUnchanged;

    final attackVector = _attackVector[metrics['AV']];
    final attackComplexity = _attackComplexity[metrics['AC']];
    final userInteraction = _userInteraction[metrics['UI']];
    final confidentiality = _impact[metrics['C']];
    final integrity = _impact[metrics['I']];
    final availability = _impact[metrics['A']];

    if (attackVector == null ||
        attackComplexity == null ||
        userInteraction == null ||
        confidentiality == null ||
        integrity == null ||
        availability == null ||
        privileges == null ||
        !privilegeWeights.containsKey(privileges)) {
      return null;
    }

    return CvssV3._(
      attackVector: attackVector,
      attackComplexity: attackComplexity,
      privilegesRequired: privileges,
      userInteraction: userInteraction,
      scopeChanged: scopeChanged,
      confidentiality: confidentiality,
      integrity: integrity,
      availability: availability,
    );
  }

  /// The base score, 0.0–10.0, to one decimal place.
  double get baseScore {
    final iscBase =
        1 - ((1 - confidentiality) * (1 - integrity) * (1 - availability));

    final impact = scopeChanged
        ? 7.52 * (iscBase - 0.029) - 3.25 * math.pow(iscBase - 0.02, 15)
        : 6.42 * iscBase;

    if (impact <= 0) return 0;

    final privileges = (scopeChanged
        ? _privilegesChanged
        : _privilegesUnchanged)[privilegesRequired]!;
    final exploitability =
        8.22 * attackVector * attackComplexity * privileges * userInteraction;

    final combined = impact + exploitability;
    final raw = scopeChanged ? 1.08 * combined : combined;
    return _roundUp(math.min(raw, 10));
  }

  /// CVSS's own rounding: the smallest one-decimal number that is not less than
  /// the input. Specified this way — via integers — because rounding the
  /// float directly puts scores like 8.6 on the wrong side of the boundary.
  static double _roundUp(num input) {
    final scaled = (input * 100000).round();
    if (scaled % 10000 == 0) return scaled / 100000.0;
    return ((scaled / 10000).floor() + 1) / 10.0;
  }
}
