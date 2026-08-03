import 'package:flutter/widgets.dart';

/// How much room there is, named rather than measured at each call site.
///
/// A width question, never a platform one. The browser build is the reason
/// these exist — it is the one that gets opened on a 27-inch monitor — but a
/// tablet in landscape and a browser window dragged narrow are the same problem
/// and get the same answer. Nothing here asks [AppSurface] anything.
enum Layout {
  /// One column. A phone, or a browser window someone has made narrow.
  compact,

  /// Room for a second column of content.
  medium,

  /// A desktop browser, where the constraint is no longer width but how far the
  /// eye will travel across a line.
  expanded;

  static const _mediumFrom = 720.0;
  static const _expandedFrom = 1100.0;

  static Layout of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);

  static Layout forWidth(double width) => switch (width) {
        >= _expandedFrom => Layout.expanded,
        >= _mediumFrom => Layout.medium,
        _ => Layout.compact,
      };

  bool get isCompact => this == Layout.compact;
  bool get isWide => this != Layout.compact;

  /// Whether there is room for the console shell — the fixed rail, the top bar
  /// and the tabbed report.
  ///
  /// Only [expanded], and deliberately not [medium]. The rail costs 240 pixels
  /// that are never content, and at 900 the two-column project grid and the
  /// four stat cards both fold; what is left is the console's furniture around
  /// a column narrower than the layout it replaced. The existing light layout
  /// already handles that width well, so that is what a half-width browser
  /// window keeps.
  bool get isConsole => this == Layout.expanded;

  /// How many project cards sit side by side.
  int get registryColumns => switch (this) {
        Layout.compact => 1,
        Layout.medium => 2,
        Layout.expanded => 3,
      };
}

/// Stops a column of text growing as wide as the window.
///
/// A registry stretched across a 2560-pixel monitor puts the project name at
/// one end of the desk and its menu at the other, and every row becomes a
/// head-turn to read. Bounding it is the single thing that makes the app stop
/// looking like a phone screen someone pulled at the corners.
///
/// [max] defaults to a wide-but-readable measure. Tables pass something larger:
/// a dependency table is columns rather than prose, and the reason to bound
/// prose does not apply to it.
class BoundedWidth extends StatelessWidget {
  const BoundedWidth({required this.child, this.max = 1000, super.key});

  final Widget child;
  final double max;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: max),
          // The inner `double.infinity` is not redundant. `Center` hands down
          // *loose* constraints, so a child that sizes to its content — which a
          // Column does, stretch or not — would shrink-wrap to its widest row
          // instead of filling the width it is allowed. That collapses a table
          // to the width of its longest package name.
          child: SizedBox(width: double.infinity, child: child),
        ),
      );
}
