import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

/// The colour a severity is drawn in, shared by the chip and anything that
/// needs to agree with it.
///
/// Critical is deliberately a different hue from high rather than a darker red:
/// at a glance across a list, hue separates and lightness does not.
/// The ramp keeps its hues on both skins and only changes brightness. These
/// were picked to survive white paper; on navy every one of them goes to a
/// smear, which is the same problem the semver triad had and gets the same
/// answer — same position on the wheel, lifted until it reads.
Color severityColor(AdvisorySeverity severity, ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  return switch (severity) {
    AdvisorySeverity.critical =>
      dark ? const Color(0xFFD48BF0) : const Color(0xFF7B1FA2),
    AdvisorySeverity.high =>
      dark ? const Color(0xFFFF7A85) : const Color(0xFFC62828),
    AdvisorySeverity.medium =>
      dark ? const Color(0xFFFFA24D) : const Color(0xFFE65100),
    AdvisorySeverity.low =>
      dark ? const Color(0xFF7FB2FF) : const Color(0xFF1565C0),
    AdvisorySeverity.none ||
    AdvisorySeverity.unknown =>
      dark ? const Color(0xFF8D90A0) : Colors.blueGrey,
  };
}

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
