import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

/// Small colored badge for a dependency's freshness / security status.
class DepStatusChip extends StatelessWidget {
  const DepStatusChip({super.key, required this.status});

  final DepStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      DepStatus.upToDate => ('up to date', Colors.green),
      DepStatus.outdated => ('outdated', Colors.orange),
      DepStatus.vulnerable => ('vulnerable', Colors.red),
      DepStatus.unknown => ('unknown', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.shade900,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
