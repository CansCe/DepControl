import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

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

    // Deliberately muted: the kind is context, not the headline. Direct
    // dependencies get slightly more weight because they are the ones a
    // developer can actually change.
    final (label, color) = switch (kind) {
      DepKind.direct => ('direct', theme.colorScheme.primary),
      DepKind.dev => ('dev', Colors.purple),
      DepKind.transitive => ('transitive', Colors.blueGrey),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontSize: 10,
          height: 1.4,
        ),
      ),
    );
  }
}
