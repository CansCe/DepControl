import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';

/// What a package needs from you, worst first.
///
/// One band per kind of demand rather than per kind of fact: a vulnerable
/// package and a breaking upgrade are both work, but they are not the same
/// work, and they do not go to the same person.
enum DepBand {
  vulnerable,
  breaking,
  routine,
  current,
  unread;

  Color get color => switch (this) {
        // Borrowed from the advisory ramp rather than the semver triad: a CVE
        // is not a version-bump decision, and it should not look like one.
        DepBand.vulnerable => const Color(0xFFC62828),
        DepBand.breaking => Palette.major,
        DepBand.routine => Palette.minor,
        DepBand.current => Palette.patch,
        DepBand.unread => Palette.slate,
      };

  String get label => switch (this) {
        DepBand.vulnerable => 'vulnerable',
        DepBand.breaking => 'breaking',
        DepBand.routine => 'routine',
        DepBand.current => 'current',
        DepBand.unread => 'unknown',
      };

  /// Which band [node] falls in.
  ///
  /// Ordered by what would interrupt your day first: an advisory outranks a
  /// major bump, which outranks a routine one.
  static DepBand of(DepNode node) {
    if (node.advisories.isNotEmpty) return DepBand.vulnerable;
    return switch (assessUpgrade(node).risk) {
      UpgradeRisk.breaking => DepBand.breaking,
      UpgradeRisk.minor || UpgradeRisk.patch => DepBand.routine,
      UpgradeRisk.none => DepBand.current,
      UpgradeRisk.unknown => DepBand.unread,
    };
  }
}

/// Every dependency as one tick, worst first — the lockfile made visible.
///
/// A count tells you eighteen things are outdated. This tells you eighteen out
/// of a hundred and fifty, and shows you the shape of the rest in the same
/// glance. Deliberately one mark per package rather than a proportional bar:
/// the unit this app deals in is a package, and a bar that smooths a hundred
/// and fifty of them into five rectangles has thrown away the only thing that
/// made the number real.
///
/// Ticks stay legible by having a floor width and wrapping if they run out of
/// room, so a tree of eight and a tree of eight hundred both read.
class DependencySpectrum extends StatelessWidget {
  const DependencySpectrum({
    required this.nodes,
    this.showCurrency = true,
    super.key,
  });

  final List<DepNode> nodes;

  /// False for an archived project, where "outdated" is a comparison against a
  /// pub.dev the snapshot stepped away from. The spectrum then reports only
  /// what is a fact about the snapshot: which packages carry advisories.
  final bool showCurrency;

  static const _tickWidth = 5.0;
  static const _tickGap = 2.0;
  static const _rowHeight = 22.0;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) return const SizedBox.shrink();

    final bands = <DepBand>[
      for (final node in nodes)
        if (!showCurrency)
          node.advisories.isNotEmpty ? DepBand.vulnerable : DepBand.unread
        else
          DepBand.of(node),
    ]..sort((a, b) => a.index.compareTo(b.index));

    final counts = <DepBand, int>{};
    for (final band in bands) {
      counts.update(band, (n) => n + 1, ifAbsent: () => 1);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final perRow =
                (constraints.maxWidth / (_tickWidth + _tickGap)).floor();
            final rows = perRow < 1 ? 1 : (bands.length / perRow).ceil();

            return SizedBox(
              height: rows * _rowHeight,
              width: double.infinity,
              child: Wrap(
                spacing: _tickGap,
                runSpacing: _tickGap,
                children: [
                  for (final band in bands)
                    Tooltip(
                      message: band.label,
                      child: Container(
                        width: _tickWidth,
                        height: _rowHeight - _tickGap,
                        decoration: BoxDecoration(
                          color: band.color,
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 18,
          runSpacing: 6,
          children: [
            for (final entry in counts.entries)
              _Key(band: entry.key, count: entry.value),
          ],
        ),
      ],
    );
  }
}

/// `18 routine`, with the swatch that says which ticks those are.
class _Key extends StatelessWidget {
  const _Key({required this.band, required this.count});

  final DepBand band;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: band.color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          '$count ${band.label}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.86),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
