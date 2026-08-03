import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';

/// Small badge for how a dependency is pulled in.
///
/// Sits beside the package name in the compact layout, where a whole column
/// for one short word is not worth the width.
class DepKindBadge extends StatelessWidget {
  const DepKindBadge({super.key, required this.kind});

  final DepKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = Surfaces.of(context);

    // Deliberately muted: the kind is context, not the headline. Direct
    // dependencies get the brand colour because they are the ones a developer
    // can actually change; the rest recede.
    final (label, color) = switch (kind) {
      DepKind.direct => ('direct', surfaces.accent),
      DepKind.dev => (
          'dev',
          surfaces.isDark ? const Color(0xFFC4A2F5) : const Color(0xFF7B4FBF),
        ),
      DepKind.transitive => ('transitive', surfaces.faint),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontSize: 10,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
