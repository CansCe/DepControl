import 'package:flutter/foundation.dart';

/// Every place this app can be, as a value.
///
/// Three of them, which is the whole reason this is hand-written rather than a
/// routing package: parsing `/projects/<id>` out of a path and turning it back
/// into one is a dozen lines, and a dependency to do it would land in an app
/// whose entire purpose is telling people what their dependencies cost. The
/// list is closed and the parser is total — an unrecognised path is [registry]
/// rather than an error — so there is no route table to fall out of sync.
@immutable
sealed class AppRoute {
  const AppRoute();

  /// The registry: every project, and the form that adds one.
  const factory AppRoute.registry() = RegistryRoute;

  /// One project's dependency report.
  const factory AppRoute.report(String projectId) = ReportRoute;

  /// Account, session, and — on the app build — the device PIN.
  const factory AppRoute.settings() = SettingsRoute;

  /// What goes in the address bar.
  String get location;

  /// Reads a path back into a route.
  ///
  /// Total by construction: anything unrecognised is the registry. A 404 page
  /// would be the alternative, and for an app with three routes it would mostly
  /// be shown to people whose link picked up a trailing character.
  factory AppRoute.parse(String? location) {
    final path = Uri.tryParse(location ?? '/')?.pathSegments ?? const [];

    return switch (path) {
      ['projects', final id, ...] when id.isNotEmpty => ReportRoute(id),
      ['settings', ...] => const SettingsRoute(),
      _ => const RegistryRoute(),
    };
  }
}

class RegistryRoute extends AppRoute {
  const RegistryRoute();

  @override
  String get location => '/';

  @override
  bool operator ==(Object other) => other is RegistryRoute;

  @override
  int get hashCode => (RegistryRoute).hashCode;
}

class ReportRoute extends AppRoute {
  const ReportRoute(this.projectId);

  final String projectId;

  /// Encoded, because the id lands in a URL. Project ids are uuids today and
  /// this does not depend on that staying true.
  @override
  String get location => '/projects/${Uri.encodeComponent(projectId)}';

  @override
  bool operator ==(Object other) =>
      other is ReportRoute && other.projectId == projectId;

  @override
  int get hashCode => Object.hash(ReportRoute, projectId);
}

class SettingsRoute extends AppRoute {
  const SettingsRoute();

  @override
  String get location => '/settings';

  @override
  bool operator ==(Object other) => other is SettingsRoute;

  @override
  int get hashCode => (SettingsRoute).hashCode;
}
