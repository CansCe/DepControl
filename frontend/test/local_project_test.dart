import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/collector/collector_pairing.dart';
import 'package:frontend/scans/scan_queue.dart';
import 'package:frontend/screens/registry_console.dart';
import 'package:frontend/theme.dart';
import 'package:frontend/widgets/project_card.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

/// What the UI says about a project it was handed rather than fetched.
///
/// The one genuinely misleading thing this feature could do is present a bundle
/// somebody collected six months ago as though the server had read the
/// repository this morning. These are the assertions that stop it.
void main() {
  Project local({DateTime? collectedAt}) => Project(
        id: 'p-local',
        name: 'payroll_app',
        source: ProjectSource.local,
        ownerId: 'u1',
        addedAt: DateTime.utc(2026, 1, 1),
        lastCheckedAt: DateTime.now().toUtc(),
        bundleCollectedAt: collectedAt,
      );

  Widget wrap(Widget child) => MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  group('a local project card', () {
    testWidgets('says it was uploaded rather than showing a URL', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          ProjectCard(
            project: local(),
            onOpen: () {},
            onArchive: () {},
            onDelete: () async {},
          ),
        ),
      );

      expect(find.text('payroll_app'), findsOneWidget);
      // There is no URL, and there is not meant to be: it is the one thing
      // about a private repository that would let a hosted service reach it.
      expect(find.text('uploaded bundle'), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
    });
  });

  group('the registry hero', () {
    testWidgets('offers the collector for repositories we cannot reach', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          RegistryConsole(
            controller: TextEditingController(),
            onSubmit: () {},
            onUpload: () {},
            archived: false,
            onFilter: (_) {},
            grid: const SizedBox.shrink(),
            collectorPairing: const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.textContaining('depcontrol collect'), findsOneWidget);
      expect(find.text('Upload bundle'), findsOneWidget);
    });

    testWidgets('keeps the instructions where files cannot be chosen', (
      tester,
    ) async {
      // The app build has no file chooser. The command is still true there, and
      // hiding the whole explanation would leave somebody with an unreachable
      // repository and no idea the feature exists.
      await tester.pumpWidget(
        wrap(
          RegistryConsole(
            controller: TextEditingController(),
            onSubmit: () {},
            archived: false,
            onFilter: (_) {},
            grid: const SizedBox.shrink(),
            collectorPairing: const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.textContaining('depcontrol collect'), findsOneWidget);
      expect(find.text('Upload bundle'), findsNothing);
    });

    testWidgets('is not offered from the archived view', (tester) async {
      await tester.pumpWidget(
        wrap(
          RegistryConsole(
            controller: TextEditingController(),
            onSubmit: () {},
            onUpload: () {},
            archived: true,
            onFilter: (_) {},
            grid: const SizedBox.shrink(),
            collectorPairing: const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.textContaining('depcontrol collect'), findsNothing);
    });
  });

  group('CollectorPairing', () {
    testWidgets('shows the code in the command, and claiming triggers reattach', (
      tester,
    ) async {
      var scansCalled = false;
      final api = ApiClient(
        baseUrl: 'http://test.local',
        accessToken: () async => 'token',
        client: MockClient((request) async {
          final path = request.url.path;
          final now = DateTime.now().toUtc().toIso8601String();

          if (request.method == 'POST' && path == '/collector/sessions') {
            return http.Response(
              jsonEncode({
                'id': 's1',
                'code': 'ABCD-EFGH-IJKL-MNOP',
                'expiresAt':
                    DateTime.now().toUtc().add(const Duration(minutes: 15)).toIso8601String(),
              }),
              201,
            );
          }
          if (request.method == 'GET' && path == '/collector/sessions/s1') {
            // Claimed on the very first poll — nothing under test needs a
            // "still waiting" tick in between.
            return http.Response(
              jsonEncode({
                'id': 's1',
                'state': 'claimed',
                'expiresAt': now,
                'scanId': 'scan-x',
              }),
              200,
            );
          }
          if (request.method == 'GET' && path == '/scans') {
            scansCalled = true;
            return http.Response(
              jsonEncode({
                'scans': [
                  {
                    'scanId': 'scan-x',
                    'state': 'queued',
                    'progress': {
                      'phase': 'queued',
                      'startedAt': now,
                      'phaseStartedAt': now,
                    },
                  },
                ],
              }),
              200,
            );
          }
          // Anything else a queued task's own polling reaches for — a status
          // this test does not otherwise care about, but must not crash on.
          return http.Response(
            jsonEncode({
              'scanId': 'scan-x',
              'state': 'queued',
              'progress': {
                'phase': 'queued',
                'startedAt': now,
                'phaseStartedAt': now,
              },
            }),
            200,
          );
        }),
      );
      final scans = ScanQueue();

      await tester.pumpWidget(
        wrap(CollectorPairing(api: api, scans: scans)),
      );

      await tester.tap(find.text('Pair the collector'));
      await tester.pump();

      expect(
        find.textContaining('depcontrol collect --pair ABCD-EFGH-IJKL-MNOP'),
        findsOneWidget,
      );

      // Fires the pairing widget's own poll, whose "claimed" result is what
      // should call `ScanQueue.reattach`. Several short pumps rather than
      // `pumpAndSettle`: `ScanQueue` keeps its own periodic timer alive for
      // as long as a task is unfinished, which `pumpAndSettle` would wait on
      // forever.
      await tester.pump(const Duration(seconds: 2));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(scansCalled, isTrue);
      expect(find.textContaining('connected'), findsOneWidget);

      // `ScanQueue` keeps a one-shot timer alive for as long as a task is
      // unfinished — real behaviour, since a scan on the server outlives the
      // app that started watching it, but it must not outlive this test.
      // Disposed here rather than via `addTearDown`, which runs after
      // flutter_test's own end-of-test pending-timer check.
      scans.dispose();
    });
  });
}
