import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

/// The colour a policy verdict is drawn in.
///
/// Stop / think / go, which is what a verdict is, rather than the advisory
/// palette's severity ramp. The icon and the card's own heading carry the
/// difference between "a lawyer decides this" and "a CVE is open"; the colour
/// only has to say how far through the decision you are.
/// Stop / think / go keeps its three hues on both skins; only the brightness
/// changes, for the same reason every other palette here needed a second set —
/// a colour picked to carry weight on white paper goes muddy on navy.
Color licenseRuleColor(LicenseRule rule, ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  return switch (rule) {
    LicenseRule.forbidden =>
      dark ? const Color(0xFFFF7A85) : const Color(0xFFB3261E),
    LicenseRule.review =>
      dark ? const Color(0xFFF2A93B) : const Color(0xFFA05E00),
    LicenseRule.allowed =>
      dark ? const Color(0xFF34D399) : const Color(0xFF2E7D32),
  };
}

IconData licenseRuleIcon(LicenseRule rule) => switch (rule) {
      LicenseRule.forbidden => Icons.gavel_outlined,
      LicenseRule.review => Icons.pending_actions_outlined,
      LicenseRule.allowed => Icons.check_circle_outline,
    };

/// A verdict, with the license that earned it.
///
/// The license name is on the chip rather than beside it because the name is
/// what a reviewer searches for: "do we have any AGPL" is the question, and
/// "forbidden" on its own does not answer it.
class LicenseRuleChip extends StatelessWidget {
  const LicenseRuleChip({
    required this.rule,
    this.license,
    super.key,
  });

  final LicenseRule rule;

  /// The SPDX id to print alongside the verdict, when there is one.
  final String? license;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = licenseRuleColor(rule, theme);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        license == null ? rule.label : '${rule.label}  ·  $license',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
