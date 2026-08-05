import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/registry_console.dart';
import 'package:frontend/theme.dart';
import 'package:frontend/widgets/project_card.dart';
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
          ),
        ),
      );

      expect(find.textContaining('depcontrol collect'), findsNothing);
    });
  });
}
