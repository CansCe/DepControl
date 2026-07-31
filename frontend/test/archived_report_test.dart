import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/routing/app_route.dart';
import 'package:frontend/screens/report_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

final _report = DepReport(
  projectId: 'p1',
  generatedAt: DateTime.utc(2026, 1, 1),
  nodes: const [
    DepNode(
      name: 'http',
      kind: DepKind.direct,
      installed: '0.13.0',
      latest: '1.5.0',
      constraint: '^0.13.0',
      status: DepStatus.outdated,
    ),
    DepNode(
      name: 'yaml',
      kind: DepKind.direct,
      installed: '3.1.2',
      latest: '3.1.3',
      status: DepStatus.vulnerable,
      advisories: [
        DepAdvisory(
          id: 'GHSA-demo',
          severity: AdvisorySeverity.high,
          cvssScore: 7.5,
          fixedIn: '3.1.3',
        ),
      ],
    ),
  ],
);

Project project({bool archived = false}) => Project(
      id: 'p1',
      gitUrl: 'https://github.com/acme/demo.git',
      name: 'demo',
      ownerId: 'u1',
      lastCheckedAt: DateTime.utc(2026, 1, 1),
      archivedAt: archived ? DateTime.utc(2026, 1, 3) : null,
    );

/// Fails any request the screen should not be making for an archived project.
({ApiClient api, List<String> calls}) clientFor() {
  final calls = <String>[];
  final api = ApiClient(
    accessToken: () async => 'token',
    client: MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      return http.Response(
        jsonEncode({
          'project': <String, dynamic>{},
          'report': _report.toJson(),
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  return (api: api, calls: calls);
}

Future<void> pump(
  WidgetTester tester,
  Project p,
  ApiClient api, {
  // The report opens on its packages, so a test about advisories or licenses
  // has to say which panel it means.
  ReportTab tab = ReportTab.packages,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      // AppShell provides the Scaffold in the app; the screen has no bar of
      // its own any more.
      home: Scaffold(body: ReportScreen(project: p, api: api, tab: tab)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('an archived project', () {
    testWidgets('offers no re-analyze', (tester) async {
      final c = clientFor();
      await pump(tester, project(archived: true), c.api);

      expect(find.text('Re-analyze'), findsNothing);
    });

    testWidgets('says the report is a snapshot', (tester) async {
      final c = clientFor();
      await pump(tester, project(archived: true), c.api);

      expect(find.textContaining('Archived'), findsOneWidget);
      expect(find.textContaining('not kept up to date'), findsOneWidget);
    });

    // "Outdated" is a comparison against pub.dev as it is now, which is
    // exactly what archiving stepped away from.
    testWidgets('drops the currency comparison from the summary',
        (tester) async {
      final c = clientFor();
      await pump(tester, project(archived: true), c.api);

      expect(find.text('dependencies'), findsOneWidget);
      expect(find.text('outdated'), findsNothing);
    });

    testWidgets('drops the Latest and Status columns', (tester) async {
      final c = clientFor();
      await pump(tester, project(archived: true), c.api);

      expect(find.text('Installed'), findsOneWidget);
      expect(find.text('Latest'), findsNothing);
      expect(find.text('Status'), findsNothing);
    });

    // Advisories are facts about the versions in the snapshot, so they stay;
    // planning a fix re-fetches the repository, so it does not.
    testWidgets('keeps advisories but not the remediation offer',
        (tester) async {
      final c = clientFor();
      await pump(
        tester,
        project(archived: true),
        c.api,
        tab: ReportTab.advisories,
      );

      expect(find.textContaining('GHSA-demo'), findsWidgets);
      expect(find.textContaining('Work out how to fix'), findsNothing);
    });

    // The two reads that serve stored data, and nothing else: no repository
    // fetch, no pub.dev. The license report belongs in the same category as the
    // dependency report — it runs the policy over rows already in the database
    // — which is why archiving does not take it away.
    testWidgets('reads stored data and reaches outward for nothing',
        (tester) async {
      final c = clientFor();
      await pump(tester, project(archived: true), c.api);

      // One call, not two. Splitting the report into panels made the license
      // report lazy: it is fetched when somebody opens that tab rather than on
      // every visit to every report, which is a saved round trip per view.
      expect(c.calls, ['GET /projects/p1']);
    });

    testWidgets('fetches the license report when that panel is opened',
        (tester) async {
      final c = clientFor();
      await pump(
        tester,
        project(archived: true),
        c.api,
        tab: ReportTab.licenses,
      );

      // Still stored data on both counts: the policy runs over rows already in
      // the database, which is why archiving does not take it away.
      expect(c.calls, ['GET /projects/p1', 'GET /projects/p1/licenses']);
    });
  });

  group('an active project', () {
    testWidgets('still offers re-analyze and the comparison', (tester) async {
      final c = clientFor();
      await pump(tester, project(), c.api);

      expect(find.text('Re-analyze'), findsOneWidget);
      expect(find.text('outdated'), findsWidgets);
      expect(find.text('Latest'), findsOneWidget);
    });

    testWidgets('offers to plan a fix, which archiving is what removes',
        (tester) async {
      final c = clientFor();
      await pump(tester, project(), c.api, tab: ReportTab.advisories);

      expect(find.textContaining('Work out how to fix'), findsOneWidget);
    });
  });
}
