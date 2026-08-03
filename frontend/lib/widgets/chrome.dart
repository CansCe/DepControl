import 'package:flutter/material.dart';

import '../theme.dart';

/// The dark header every screen opens with.
///
/// It carries identity — which project, which ref, which account — and hands
/// the rest of the window to the content. Drawn as part of the body with the
/// app bar floating over it, so the bar's actions sit *in* the band rather than
/// on a separate strip above it with a seam between them.
class InkBand extends StatelessWidget {
  const InkBand({required this.child, this.padding, super.key});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Palette.ink,
      padding: padding ??
          const EdgeInsets.fromLTRB(24, kToolbarHeight + 12, 24, 22),
      child: child,
    );
  }
}

/// A section of a report, marked with the colour of whichever kind of judgement
/// it carries.
///
/// The spine is the app's one structural device, and it encodes something
/// true: three different faculties pass judgement here — security, licensing,
/// and the version arithmetic — with three palettes that must not be read
/// interchangeably. The spine says which one you are about to read before you
/// have read a word of it.
class SpineCard extends StatelessWidget {
  const SpineCard({
    required this.accent,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    super.key,
  });

  final Color accent;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: surfaces.card,
          border: Border.all(color: accent.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: accent),
              Expanded(
                child: Container(
                  color: accent.withValues(alpha: 0.045),
                  padding: padding,
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A heading inside a [SpineCard]: an icon, a title, and whatever summary the
/// section wants to lead with.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    required this.icon,
    required this.title,
    required this.accent,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final Color accent;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 18, color: accent),
        ),
        const SizedBox(width: 11),
        Text(title, style: theme.textTheme.titleMedium),
        if (trailing != null) ...[
          const SizedBox(width: 14),
          Expanded(child: trailing!),
        ],
      ],
    );
  }
}

/// An eyebrow above a block of content — small, tracked-out, in the display
/// face. Names what a region is without spending a heading on it.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {this.color, super.key});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: displayOf(
        context,
        Theme.of(context).textTheme.labelSmall,
        color: color ?? Surfaces.of(context).muted,
        weight: FontWeight.w700,
      ).copyWith(letterSpacing: 1.4, fontSize: 11),
    );
  }
}
