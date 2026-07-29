import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/screens/report_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

/// `a` declares `b`; `lonely` has no edges at all.
const _nodes = [
  DepNode(
    name: 'a',
    kind: DepKind.direct,
    installed: '1.0.0',
    status: DepStatus.upToDate,
    dependencies: ['b'],
  ),
  DepNode(
    name: 'b',
    kind: DepKind.transitive,
    installed: '2.0.0',
    status: DepStatus.outdated,
  ),
  DepNode(
    name: 'lonely',
    kind: DepKind.dev,
    installed: '3.0.0',
    status: DepStatus.unknown,
  ),
];

/// ~50 packages with ~150 edges, matching the size of a real report. Graph size
/// matters: the crash only appeared with a full dependency set.
List<DepNode> largeReport() {
  const names = [
    '_fe_analyzer_shared', 'analyzer', 'args', 'async', 'boolean_selector',
    'cli_config', 'collection', 'convert', 'coverage', 'crypto',
    'dart_flutter_team_lints', 'file', 'frontend_server_client', 'glob',
    'graphs', 'http', 'http_multi_server', 'http_parser', 'io', 'js',
    'lints', 'logging', 'matcher', 'meta', 'mime', 'node_preamble',
    'package_config', 'path', 'pool', 'pub_semver', 'shelf', 'shelf_packages',
    'shelf_static', 'shelf_web_socket', 'source_map_stack_trace', 'source_maps',
    'source_span', 'stack_trace', 'stream_channel', 'string_scanner',
    'term_glyph', 'test', 'test_api', 'test_core', 'typed_data', 'vm_service',
    'watcher', 'web_socket_channel', 'yaml',
  ];

  return [
    for (var i = 0; i < names.length; i++)
      DepNode(
        name: names[i],
        kind: i < 3
            ? DepKind.direct
            : i < 6
                ? DepKind.dev
                : DepKind.transitive,
        installed: '1.${i % 9}.0',
        latest: '1.${(i % 9) + 1}.0',
        status: switch (i % 4) {
          0 => DepStatus.upToDate,
          1 => DepStatus.outdated,
          2 => DepStatus.vulnerable,
          _ => DepStatus.unknown,
        },
        source: DepSource.constraint,
        advisories: i % 4 == 2
            ? [
                DepAdvisory(
                  id: 'GHSA-demo-$i',
                  summary: 'Demo advisory $i.',
                  fixedIn: '1.${(i % 9) + 1}.0',
                ),
              ]
            : const [],
        dependencies: [
          for (var k = 1; k <= 3; k++)
            if (i + k * 2 < names.length) names[i + k * 2],
        ],
      ),
  ];
}

void main() {
  group('ReportScreen', () {
    ApiClient apiReturning(DepReport report) => ApiClient(
          accessToken: () async => 'token',
          client: MockClient((_) async => http.Response(
                jsonEncode({
                  'project': <String, dynamic>{},
                  'report': report.toJson(),
                }),
                200,
                headers: {'content-type': 'application/json'},
              )),
        );

    final project = Project(
      id: 'p1',
      gitUrl: 'https://github.com/acme/demo.git',
      name: 'demo',
      ownerId: 'u1',
    );

    // Full-size report: the crash only showed up with a real dependency set.
    final report = DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026, 1, 1),
      nodes: largeReport(),
    );

    // Regression: the report used to host a whole-graph canvas that asserted
    // during layout and left a red screen on the way back to the registry.
    testWidgets('can be opened and closed again', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReportScreen(
                      project: project,
                      api: apiReturning(report),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('demo'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('re-analyze calls the refresh endpoint and updates the view',
        (tester) async {
      final requested = <String>[];
      final api = ApiClient(
        accessToken: () async => 'token',
        client: MockClient((request) async {
          requested.add('${request.method} ${request.url.path}');
          // Refresh returns a smaller report so the change is observable.
          final isRefresh = request.url.path.endsWith('/refresh');
          final body = isRefresh
              ? DepReport(
                  projectId: 'p1',
                  generatedAt: DateTime.utc(2026, 2, 1),
                  nodes: _nodes,
                )
              : report;
          return http.Response(
            jsonEncode({
              'project': project.toJson(),
              'report': body.toJson(),
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(home: ReportScreen(project: project, api: api)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Re-analyze'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        requested,
        contains('POST /projects/p1/refresh'),
        reason: 'must re-analyze, not just re-read the stored report',
      );
      expect(find.textContaining('Re-analyzed'), findsOneWidget);
    });

    testWidgets('a failed re-analyze surfaces the error', (tester) async {
      final api = ApiClient(
        accessToken: () async => 'token',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/refresh')) {
            return http.Response(
              jsonEncode({'error': 'repository not found'}),
              400,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'project': project.toJson(),
              'report': report.toJson(),
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(home: ReportScreen(project: project, api: api)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Re-analyze'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('repository not found'), findsOneWidget);
    });

    testWidgets('selecting a package explains why it is there', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReportScreen(project: project, api: apiReturning(report)),
        ),
      );
      await tester.pumpAndSettle();

      // `coverage` is transitive in largeReport(), pulled in by `args`.
      final row = find.text('coverage').first;
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.textContaining('Why is coverage here?'), findsOneWidget);
      expect(find.textContaining('Pulled in through'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    group('what the source imports', () {
      DepReport reportOf(List<DepNode> nodes) => DepReport(
            projectId: 'p1',
            generatedAt: DateTime.utc(2026, 1, 1),
            nodes: nodes,
          );

      Future<void> show(WidgetTester tester, DepReport shown) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ReportScreen(project: project, api: apiReturning(shown)),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('names a package imported without being declared',
          (tester) async {
        await show(
          tester,
          reportOf(const [
            DepNode(
              name: 'http',
              kind: DepKind.direct,
              installed: '1.0.0',
              imported: true,
              dependencies: ['meta'],
            ),
            DepNode(
              name: 'meta',
              kind: DepKind.transitive,
              installed: '1.16.0',
              imported: true,
            ),
          ]),
        );

        expect(
          find.textContaining('1 package imported without being declared'),
          findsOneWidget,
        );
        expect(find.textContaining('meta'), findsWidgets);
      });

      testWidgets('names a declared dependency nothing imports',
          (tester) async {
        await show(
          tester,
          reportOf(const [
            DepNode(
              name: 'http',
              kind: DepKind.direct,
              installed: '1.0.0',
              imported: true,
            ),
            DepNode(
              name: 'crypto',
              kind: DepKind.direct,
              installed: '3.0.0',
              imported: false,
            ),
          ]),
        );

        expect(
          find.textContaining('No Dart source imports crypto'),
          findsOneWidget,
        );
      });

      // The silence that matters: a report from a scan that never read source
      // must not imply it read some and found nothing.
      testWidgets('says nothing when no source was scanned', (tester) async {
        await show(
          tester,
          reportOf(const [
            DepNode(name: 'http', kind: DepKind.direct, installed: '1.0.0'),
            DepNode(
              name: 'meta',
              kind: DepKind.transitive,
              installed: '1.16.0',
            ),
          ]),
        );

        expect(find.textContaining('without being declared'), findsNothing);
        expect(find.textContaining('No Dart source imports'), findsNothing);
      });
    });

    group('the advisories card', () {
      /// A report with one vulnerable direct package and one vulnerable
      /// transitive package, which is the distinction the card has to make.
      final vulnerable = DepReport(
        projectId: 'p1',
        generatedAt: DateTime.utc(2026, 1, 1),
        nodes: const [
          DepNode(
            name: 'app_dep',
            kind: DepKind.direct,
            installed: '1.0.0',
            status: DepStatus.upToDate,
            dependencies: ['buried'],
          ),
          DepNode(
            name: 'http',
            kind: DepKind.direct,
            installed: '0.13.0',
            status: DepStatus.vulnerable,
            advisories: [
              DepAdvisory(
                id: 'GHSA-direct',
                summary: 'Header injection.',
                fixedIn: '0.13.3',
              ),
            ],
          ),
          DepNode(
            name: 'buried',
            kind: DepKind.transitive,
            installed: '2.0.0',
            status: DepStatus.vulnerable,
            advisories: [
              DepAdvisory(id: 'GHSA-transitive', fixedIn: '2.1.0'),
            ],
          ),
        ],
      );

      /// Two packages whose advisories differ in severity, listed in the
      /// report in the *wrong* order so the sort has something to do.
      final graded = DepReport(
        projectId: 'p1',
        generatedAt: DateTime.utc(2026, 1, 1),
        nodes: const [
          DepNode(
            name: 'mild_dep',
            kind: DepKind.direct,
            installed: '1.0.0',
            status: DepStatus.vulnerable,
            advisories: [
              DepAdvisory(
                id: 'GHSA-mild',
                severity: AdvisorySeverity.low,
                cvssScore: 3.1,
              ),
            ],
          ),
          DepNode(
            name: 'nasty_dep',
            kind: DepKind.direct,
            installed: '1.0.0',
            status: DepStatus.vulnerable,
            advisories: [
              DepAdvisory(
                id: 'GHSA-nasty',
                severity: AdvisorySeverity.critical,
                cvssScore: 9.8,
              ),
            ],
          ),
        ],
      );

      testWidgets('shows the band and the score', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ReportScreen(project: project, api: apiReturning(graded)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Critical  9.8'), findsOneWidget);
        expect(find.text('Low  3.1'), findsOneWidget);
      });

      testWidgets('summarises the breakdown by band', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ReportScreen(project: project, api: apiReturning(graded)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('1 critical'), findsOneWidget);
        expect(find.text('1 low'), findsOneWidget);
      });

      // The reader deals with the top of this list and runs out of time
      // somewhere further down, so the worst thing has to be at the top.
      testWidgets('lists the worst package first', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ReportScreen(project: project, api: apiReturning(graded)),
          ),
        );
        await tester.pumpAndSettle();

        // The chips are unique to the advisories card; the package names also
        // appear in the dependency table below, which sorts independently.
        final critical = tester.getTopLeft(find.text('Critical  9.8')).dy;
        final low = tester.getTopLeft(find.text('Low  3.1')).dy;
        expect(critical, lessThan(low));
      });

      testWidgets('names the version that fixes each advisory',
          (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ReportScreen(
              project: project,
              api: apiReturning(vulnerable),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Fixed in 0.13.3.'), findsOneWidget);
        expect(find.textContaining('Header injection'), findsOneWidget);
      });

      // Telling someone to upgrade a package they do not declare is useless
      // advice — the fix has to come through whatever pulls it in.
      testWidgets('names the direct dependency behind a transitive advisory',
          (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ReportScreen(
              project: project,
              api: apiReturning(vulnerable),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('arrives through app_dep'),
          findsOneWidget,
        );
      });

      testWidgets('says nothing about provenance for a direct dependency',
          (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ReportScreen(
              project: project,
              api: apiReturning(vulnerable),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('arrives through'), findsOneWidget);
        expect(find.textContaining('do not depend on http'), findsNothing);
      });
    });

    testWidgets('shows the dependency summary', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReportScreen(project: project, api: apiReturning(report)),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('dependencies'), findsOneWidget);
      // These appear both as summary labels and as per-row status chips.
      expect(find.text('outdated'), findsWidgets);
      expect(find.text('vulnerable'), findsWidgets);
    });
  });
}
