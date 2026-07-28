import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

/// The colour a severity is drawn in, shared by the chip and anything that
/// needs to agree with it.
///
/// Critical is deliberately a different hue from high rather than a darker red:
/// at a glance across a list, hue separates and lightness does not.
Color severityColor(AdvisorySeverity severity, ThemeData theme) =>
    switch (severity) {
      AdvisorySeverity.critical => const Color(0xFF7B1FA2),
      AdvisorySeverity.high => const Color(0xFFC62828),
      AdvisorySeverity.medium => const Color(0xFFE65100),
      AdvisorySeverity.low => const Color(0xFF1565C0),
      AdvisorySeverity.none => Colors.blueGrey,
      AdvisorySeverity.unknown => Colors.blueGrey,
    };

/// What to call each band in the interface.
String severityLabel(AdvisorySeverity severity) => switch (severity) {
      AdvisorySeverity.critical => 'Critical',
      AdvisorySeverity.high => 'High',
      AdvisorySeverity.medium => 'Medium',
      AdvisorySeverity.low => 'Low',
      AdvisorySeverity.none => 'No severity',
      AdvisorySeverity.unknown => 'Unrated',
    };

/// A severity band, with its CVSS score when one was published.
///
/// The score is shown next to the band because the band alone hides the
/// difference between a 7.0 and an 8.9, and that difference is often what
/// decides whether something is worth doing today.
class SeverityChip extends StatelessWidget {
  const SeverityChip({required this.severity, this.score, super.key});

  final AdvisorySeverity severity;
  final double? score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = severityColor(severity, theme);
    final label = severityLabel(severity);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        score != null ? '$label  ${score!.toStringAsFixed(1)}' : label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
