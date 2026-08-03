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
  ///
  /// The archived view is the same screen over a different set rather than a
  /// route of its own, but it *is* addressable — the console sidebar offers it
  /// from every screen, and an entry that could only be reached by toggling
  /// something on one particular screen would not be reachable from there.
  const factory AppRoute.registry({bool archived}) = RegistryRoute;

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
      ['archived', ...] => const RegistryRoute(archived: true),
      _ => const RegistryRoute(),
    };
  }
}

class RegistryRoute extends AppRoute {
  const RegistryRoute({this.archived = false});

  /// Whether this is the put-out-of-the-way half of the registry.
  final bool archived;

  @override
  String get location => archived ? '/archived' : '/';

  @override
  bool operator ==(Object other) =>
      other is RegistryRoute && other.archived == archived;

  @override
  int get hashCode => Object.hash(RegistryRoute, archived);
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
