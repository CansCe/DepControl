import 'package:flutter/foundation.dart';
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
///
/// Painted rather than built. Every tick used to be a `Tooltip` wrapping a
/// `Container`, which is two widgets, an element, a render object and a gesture
/// recognizer each — on a 1,400-package monorepo that is the single most
/// expensive thing on the screen, and it was rebuilt on every scroll frame and
/// every `setState` above it. The band each tick belongs to is also worked out
/// once here rather than per build: [DepBand.of] runs [assessUpgrade], which
/// parses two versions and a constraint, so recomputing it meant several
/// thousand semver parses per frame.
class DependencySpectrum extends StatefulWidget {
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

  @override
  State<DependencySpectrum> createState() => _DependencySpectrumState();
}

class _DependencySpectrumState extends State<DependencySpectrum> {
  static const _tickWidth = 5.0;
  static const _tickGap = 2.0;
  static const _rowHeight = 22.0;

  late List<DepBand> _bands;
  late Map<DepBand, int> _counts;

  @override
  void initState() {
    super.initState();
    _classify();
  }

  @override
  void didUpdateWidget(covariant DependencySpectrum old) {
    super.didUpdateWidget(old);
    if (old.nodes != widget.nodes || old.showCurrency != widget.showCurrency) {
      _classify();
    }
  }

  void _classify() {
    _bands = <DepBand>[
      for (final node in widget.nodes)
        if (!widget.showCurrency)
          node.advisories.isNotEmpty ? DepBand.vulnerable : DepBand.unread
        else
          DepBand.of(node),
    ]..sort((a, b) => a.index.compareTo(b.index));

    _counts = <DepBand, int>{};
    for (final band in _bands) {
      _counts.update(band, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final perRow =
                (constraints.maxWidth / (_tickWidth + _tickGap)).floor();
            final columns = perRow < 1 ? 1 : perRow;
            final rows = (_bands.length / columns).ceil();

            return Semantics(
              // The ticks carry no text, so the shape has to be sayable. One
              // label for the block rather than 1,400 tooltips nobody on a
              // touch screen could have hovered anyway — the legend underneath
              // is what a sighted reader actually decodes them with.
              label: _spokenSummary(_counts),
              child: SizedBox(
                height: rows * _rowHeight,
                width: double.infinity,
                child: CustomPaint(
                  painter: _SpectrumPainter(
                    bands: _bands,
                    columns: columns,
                    tickWidth: _tickWidth,
                    tickGap: _tickGap,
                    rowHeight: _rowHeight,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 18,
          runSpacing: 6,
          children: [
            for (final entry in _counts.entries)
              _Key(band: entry.key, count: entry.value),
          ],
        ),
      ],
    );
  }
}

String _spokenSummary(Map<DepBand, int> counts) {
  final parts = [
    for (final entry in counts.entries) '${entry.value} ${entry.key.label}',
  ];
  return 'Dependency spectrum: ${parts.join(', ')}.';
}

/// Draws the ticks directly.
///
/// A few thousand `drawRRect` calls into one layer, against a widget, element
/// and render object per tick — the same picture for a fraction of the frame,
/// and no rebuild cost at all when something above merely changes state.
class _SpectrumPainter extends CustomPainter {
  const _SpectrumPainter({
    required this.bands,
    required this.columns,
    required this.tickWidth,
    required this.tickGap,
    required this.rowHeight,
  });

  final List<DepBand> bands;
  final int columns;
  final double tickWidth;
  final double tickGap;
  final double rowHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final paints = <DepBand, Paint>{
      for (final band in DepBand.values) band: Paint()..color = band.color,
    };
    final height = rowHeight - tickGap;
    const radius = Radius.circular(1.5);

    for (var i = 0; i < bands.length; i++) {
      final row = i ~/ columns;
      final column = i % columns;
      final rect = Rect.fromLTWH(
        column * (tickWidth + tickGap),
        row * rowHeight,
        tickWidth,
        height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        paints[bands[i]]!,
      );
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) =>
      old.columns != columns ||
      old.tickWidth != tickWidth ||
      old.tickGap != tickGap ||
      old.rowHeight != rowHeight ||
      !listEquals(old.bands, bands);
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
