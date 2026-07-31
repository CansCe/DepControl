import 'package:flutter/foundation.dart' show kIsWeb;

/// Which of the two builds this is, in one place.
///
/// One codebase ships to a browser tab and to an installed app, and a handful
/// of behaviours genuinely differ between them — not cosmetically, but because
/// the surface underneath is different. A swipe is a gesture on a phone and an
/// invisible affordance under a mouse. Storage that is private to an app is
/// readable from a developer console in a tab. A tab left open on a shared
/// laptop is a different risk from a phone in a pocket.
///
/// `kIsWeb` answers all of that already, and scattering it through the widget
/// tree is what makes those decisions untestable: a widget test runs on neither
/// platform and cannot pretend to be one. This is the seam that lets it.
///
/// Not a general platform abstraction. There is no `isAndroid`, no `isDesktop`,
/// because nothing here branches on those — screen *width* decides layout, and
/// that is a `LayoutBuilder` question rather than a platform one.
class AppSurface {
  const AppSurface({required this.isBrowser});

  /// The browser build.
  static const browser = AppSurface(isBrowser: true);

  /// The installed app.
  static const app = AppSurface(isBrowser: false);

  /// What this build actually is. Overridden by [overrideWith] under test.
  static AppSurface current() => _override ?? const AppSurface(isBrowser: kIsWeb);

  static AppSurface? _override;

  /// Pretends to be [surface] until [clearOverride]. Tests only — the app
  /// never calls this, and there is no path that sets it from user input.
  static void overrideWith(AppSurface surface) => _override = surface;

  static void clearOverride() => _override = null;

  final bool isBrowser;

  /// The word for where the user is, for a sentence that has to name it.
  String get container => isBrowser ? 'this browser' : 'this app';
}
