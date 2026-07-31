import 'package:flutter/material.dart';

import '../routing/app_route.dart';
import '../theme.dart';

/// The bar across the top of every screen.
///
/// A site header, not a Material `AppBar`, and the difference is the point. An
/// AppBar belongs to the screen under it: it carries that screen's title and a
/// back arrow, and it is replaced wholesale when you navigate. That is the
/// right shape for a phone, where one screen is all there is.
///
/// A web app is not read that way. The header is part of the *page*, not the
/// view: it stays put, it names the product rather than the screen, and it
/// carries navigation between sections rather than a way back out of one. The
/// back arrow goes because the browser already has one, drawn better, in a
/// place people already look.
class AppHeader extends StatelessWidget {
  const AppHeader({
    required this.current,
    required this.onNavigate,
    this.email,
    this.onMenu,
    super.key,
  });

  /// Which section is showing, for the marker under its name.
  final AppRoute current;
  final void Function(AppRoute route) onNavigate;

  /// The signed-in address, when there is a Supabase to ask.
  final String? email;

  /// Opens the project drawer. Null above the breakpoint, where the rail is
  /// already on screen and a button to reveal it would do nothing.
  final VoidCallback? onMenu;

  static const height = 52.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onRegistry = current is! SettingsRoute;

    return Container(
      height: height,
      color: Palette.ink,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          if (onMenu != null)
            IconButton(
              icon: const Icon(Icons.menu, color: Colors.white, size: 20),
              onPressed: onMenu,
            ),
          _Wordmark(
            // The mark without the word on a narrow window. Beside a menu
            // button and two section links there is not room for all three,
            // and of the three the wordmark is the one carrying the least —
            // nobody needs to be told which app they are looking at twice.
            compact: onMenu != null,
            onTap: () => onNavigate(const AppRoute.registry()),
          ),
          SizedBox(width: onMenu != null ? 12 : 22),
          // Sections, not a breadcrumb. There are two, and both are always
          // reachable — which is the behaviour a header buys that a back arrow
          // does not.
          _NavLink(
            label: 'Projects',
            selected: onRegistry,
            onTap: () => onNavigate(const AppRoute.registry()),
          ),
          const SizedBox(width: 16),
          _NavLink(
            label: 'Settings',
            selected: current is SettingsRoute,
            onTap: () => onNavigate(const AppRoute.settings()),
          ),
          const Spacer(),
          // Dropped on a narrow window rather than squeezed. An address is the
          // longest string in this bar and the least urgent thing in it — the
          // account is a click away in Settings — so on a phone it is what
          // gives way. Flexible as well as conditional, because a long address
          // can overrun a window that is not narrow enough to hide it.
          if (email case final address? when onMenu == null)
            Flexible(
              child: Text(
                address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: mono(
                  theme.textTheme.bodySmall,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.onTap, this.compact = false});

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Palette.pub,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 8),
              Text(
                'DepControl',
                style: display(
                  Theme.of(context).textTheme.titleSmall,
                  color: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A section link, marked when it is the one showing.
///
/// The marker is a rule under the label rather than a filled pill: the header
/// is already a solid block of ink, and a second solid shape inside it reads as
/// a button that has been pressed and stuck.
class _NavLink extends StatefulWidget {
  const _NavLink({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavLink> createState() => _NavLinkState();
}

class _NavLinkState extends State<_NavLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lit = widget.selected || _hovered;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: lit ? 1 : 0.6),
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                height: 2,
                width: 26,
                color: widget.selected ? Palette.pub : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
