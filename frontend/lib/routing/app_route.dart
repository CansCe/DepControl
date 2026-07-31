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

  /// One project's dependency report, open at one of its panels.
  const factory AppRoute.report(String projectId, {ReportTab tab}) =
      ReportRoute;

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
      ['projects', final id, final tab, ...] when id.isNotEmpty =>
        ReportRoute(id, tab: ReportTab.parse(tab)),
      ['projects', final id] when id.isNotEmpty => ReportRoute(id),
      ['settings', ...] => const SettingsRoute(),
      _ => const RegistryRoute(),
    };
  }
}

/// The panels a report is split across.
///
/// Four peer views of one report rather than one column three thousand pixels
/// tall. They are in the URL because a tab that is not is a tab nobody can
/// link to: "the advisories on widget-factory" is exactly the thing somebody
/// pastes into a ticket, and it would otherwise always open on the packages.
enum ReportTab {
  /// Every package. The default, because it is what people came for.
  packages,
  advisories,
  licenses,
  tree;

  /// What the tab is called in the URL. [packages] contributes nothing, so the
  /// ordinary report link stays `/projects/<id>`.
  String get slug => this == ReportTab.packages ? '' : name;

  String get label => switch (this) {
        ReportTab.packages => 'Packages',
        ReportTab.advisories => 'Advisories',
        ReportTab.licenses => 'Licenses',
        ReportTab.tree => 'Tree',
      };

  /// Reads a path segment, falling back to [packages] for anything else — an
  /// unrecognised tab is a link that nearly worked, and the report is more use
  /// than a 404.
  static ReportTab parse(String? slug) =>
      ReportTab.values.where((t) => t.name == slug).firstOrNull ??
      ReportTab.packages;
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
  const ReportRoute(this.projectId, {this.tab = ReportTab.packages});

  final String projectId;
  final ReportTab tab;

  /// Encoded, because the id lands in a URL. Project ids are uuids today and
  /// this does not depend on that staying true.
  @override
  String get location {
    final base = '/projects/${Uri.encodeComponent(projectId)}';
    return tab.slug.isEmpty ? base : '$base/${tab.slug}';
  }

  /// Identity is the project *and* the panel, so switching tabs is a route
  /// change the address bar follows.
  @override
  bool operator ==(Object other) =>
      other is ReportRoute && other.projectId == projectId && other.tab == tab;

  @override
  int get hashCode => Object.hash(ReportRoute, projectId, tab);
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
