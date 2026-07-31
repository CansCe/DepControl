import 'package:backend/src/repository/changelog_store.dart';
import 'package:backend/src/services/changelog_aggregator.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryChangelogStore store;
  late ChangelogAggregator aggregator;

  setUp(() {
    store = InMemoryChangelogStore();
    aggregator = ChangelogAggregator(store);
  });

  /// Records that `package`'s archive at [version] was read, holding [sections].
  Future<void> haveRead(
    String package,
    String version, {
    required Map<String, String> sections,
    String ecosystem = 'dart',
  }) =>
      store.saveRead(
        package,
        ecosystem: ecosystem,
        version: version,
        entries: [
          for (final entry in sections.entries)
            ChangelogEntry(version: entry.key, notes: entry.value),
        ],
      );

  DepNode node(String name, String version, {String ecosystem = 'dart'}) =>
      DepNode(
        name: name,
        ecosystem: ecosystem,
        kind: DepKind.direct,
        installed: version,
      );

  ReportDiff diffOf(List<DepNode> before, List<DepNode> after) =>
      ReportDiff.between(
        DepReport(
          projectId: 'p1',
          generatedAt: DateTime.utc(2026, 1, 1),
          nodes: before,
        ),
        DepReport(
          projectId: 'p1',
          generatedAt: DateTime.utc(2026, 2, 1),
          nodes: after,
        ),
      );

  group('reading what has been stored', () {
    test('returns the sections the move crosses, newest first', () async {
      await haveRead('http', '1.2.0', sections: {
        '1.2.0': 'Added a thing.',
        '1.1.0': 'Fixed a thing.',
        '1.0.0': 'First.',
      });

      final changelog = await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '1.0.0',
        to: '1.2.0',
      );

      expect(changelog.entries.map((e) => e.version), ['1.2.0', '1.1.0']);
      expect(changelog.entries.first.notes, 'Added a thing.');
      expect(changelog.note, isNull);
    });

    test('the version moved from is excluded', () async {
      // Its notes describe a release the project already had.
      await haveRead('http', '1.1.0', sections: {
        '1.1.0': 'New.',
        '1.0.0': 'Old news.',
      });

      final changelog = await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '1.0.0',
        to: '1.1.0',
      );

      expect(changelog.entries.map((e) => e.version), ['1.1.0']);
    });
  });

  group('what has not been read', () {
    test('is queued and says so, rather than reading as silence', () async {
      final changelog = await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '1.0.0',
        to: '2.0.0',
      );

      expect(changelog.entries, isEmpty);
      expect(changelog.note, contains('Not read yet'));

      final pending = await store.pendingRequests();
      expect(pending.single.package, 'http');
      // The newer end: a changelog is cumulative, so that archive holds the
      // older sections too.
      expect(pending.single.version, '2.0.0');
    });

    test('a downgrade queues the version being left behind', () async {
      // That is the archive whose notes say what is being given up.
      await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '2.0.0',
        to: '1.0.0',
      );

      expect((await store.pendingRequests()).single.version, '2.0.0');
    });

    test('an unreadable version falls back to the version moved to', () async {
      await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '(unresolved)',
        to: '1.5.0',
      );

      expect((await store.pendingRequests()).single.version, '1.5.0');
    });
  });

  group('read but empty', () {
    test('is distinguished from not read at all', () async {
      // A package that ships no changelog. Both cases have no entries, and only
      // one of them is worth checking back on.
      await haveRead('http', '2.0.0', sections: const {});

      final changelog = await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '1.0.0',
        to: '2.0.0',
      );

      expect(changelog.entries, isEmpty);
      expect(changelog.note, contains('was read'));
      expect(changelog.note, isNot(contains('Not read yet')));
      // And it is not queued again — a package with no changelog would
      // otherwise be asked for every day forever.
      expect(await store.pendingRequests(), isEmpty);
    });

    test('a changelog that stopped being updated says so', () async {
      // The archive for the move was read; its changelog just does not mention
      // the versions crossed.
      await haveRead('http', '2.0.0', sections: {'1.0.0': 'The last entry.'});

      final changelog = await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '1.0.0',
        to: '2.0.0',
      );

      expect(changelog.entries, isEmpty);
      expect(changelog.note, contains('was read'));
    });

    test('sections another project already pulled are used, not re-queued',
        () async {
      // A changelog is cumulative, so somebody's upgrade to 3.0.0 stores the
      // 1.x and 2.x sections too. Asking "was 2.0.0's archive read" would queue
      // a fetch for notes already in hand.
      await haveRead('http', '3.0.0', sections: {
        '3.0.0': 'Later.',
        '2.0.0': 'Breaking.',
        '1.5.0': 'Added.',
      });

      final changelog = await aggregator.forMove(
        package: 'http',
        ecosystem: 'dart',
        from: '1.0.0',
        to: '2.0.0',
      );

      expect(changelog.entries.map((e) => e.version), ['2.0.0', '1.5.0']);
      expect(changelog.note, isNull);
      expect(await store.pendingRequests(), isEmpty);
    });
  });

  group('across a whole diff', () {
    test('covers every moved package', () async {
      await haveRead('http', '2.0.0', sections: {'2.0.0': 'Breaking.'});
      await haveRead('yaml', '3.1.3', sections: {'3.1.3': 'Patched.'});

      final diff = diffOf(
        [node('http', '1.0.0'), node('yaml', '3.1.2')],
        [node('http', '2.0.0'), node('yaml', '3.1.3')],
      );

      final changelogs = await aggregator.forDiff(diff);
      expect(changelogs.map((c) => c.package), containsAll(['http', 'yaml']));
    });

    test('added and removed packages are left out', () async {
      // An added package's whole changelog is not news about an upgrade — it is
      // the package. A removed one has no notes anybody is about to act on.
      final diff = diffOf(
        [node('gone', '1.0.0')],
        [node('arrived', '1.0.0')],
      );

      expect(await aggregator.forDiff(diff), isEmpty);
      expect(await store.pendingRequests(), isEmpty);
    });

    test('ecosystems are kept apart', () async {
      // Both registries publish `http`, and they are unrelated software.
      await haveRead('http', '2.0.0',
          sections: {'2.0.0': 'The Dart one.'}, ecosystem: 'dart');

      final diff = diffOf(
        [node('http', '1.0.0', ecosystem: 'npm')],
        [node('http', '2.0.0', ecosystem: 'npm')],
      );

      final changelog = (await aggregator.forDiff(diff)).single;
      expect(changelog.ecosystem, 'npm');
      // The Dart notes must not be served for the npm package.
      expect(changelog.entries, isEmpty);
      expect(changelog.note, contains('Not read yet'));
      expect((await store.pendingRequests()).single.ecosystem, 'npm');
    });
  });

  test('serialisation round-trips', () async {
    await haveRead('http', '1.1.0', sections: {'1.1.0': 'New.'});

    final changelog = await aggregator.forMove(
      package: 'http',
      ecosystem: 'dart',
      from: '1.0.0',
      to: '1.1.0',
    );

    final restored = PackageChangelog.fromJson(changelog.toJson());
    expect(restored.package, 'http');
    expect(restored.from, '1.0.0');
    expect(restored.to, '1.1.0');
    expect(restored.entries.single.notes, 'New.');
  });
}
