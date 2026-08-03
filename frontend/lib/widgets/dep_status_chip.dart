import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';

/// The colour a dependency's status is drawn in.
///
/// Drawn from the semver triad, because that is what a status is a statement
/// about: up to date means no field would move, outdated means one of them
/// would. Vulnerable steps outside the triad into the advisory red, since it is
/// not a version-arithmetic finding at all.
Color depStatusColor(DepStatus status, [Surfaces surfaces = Surfaces.light]) =>
    switch (status) {
      DepStatus.upToDate => surfaces.patch,
      DepStatus.outdated => surfaces.minor,
      DepStatus.vulnerable => surfaces.alarm,
      DepStatus.unknown => surfaces.faint,
    };

/// Small colored badge for a dependency's freshness / security status.
class DepStatusChip extends StatelessWidget {
  const DepStatusChip({super.key, required this.status});

  final DepStatus status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      DepStatus.upToDate => 'up to date',
      DepStatus.outdated => 'outdated',
      DepStatus.vulnerable => 'vulnerable',
      DepStatus.unknown => 'unknown',
    };
    final surfaces = Surfaces.of(context);
    final color = depStatusColor(status, surfaces);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: surfaces.faces.body,
          color: color,
          fontSize: 11.5,
          height: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
