import 'package:backend/src/repository/api_diff_store.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

ApiDiff diffFor(
  String package, {
  String from = '1.0.0',
  String to = '2.0.0',
  List<ApiChange> changes = const [
    ApiChange(
      kind: ApiChangeKind.removed,
      declaration: 'Client.send',
      before: 'Future<Response> (Request request)',
    ),
  ],
  DateTime? generatedAt,
}) =>
    ApiDiff(
      package: package,
      from: from,
      to: to,
      changes: changes,
      generatedAt: generatedAt,
    );

void main() {
  late InMemoryApiDiffStore store;

  setUp(() => store = InMemoryApiDiffStore());

  group('find', () {
    test('returns nothing before anything is computed', () async {
      expect(await store.find('http', from: '1.0.0', to: '2.0.0'), isNull);
    });

    test('returns a stored diff for the exact version pair', () async {
      await store.save(diffFor('http'));

      final found = await store.find('http', from: '1.0.0', to: '2.0.0');
      expect(found, isNotNull);
      expect(found!.package, 'http');
      expect(found.removed.single.declaration, 'Client.send');
    });

    // A diff is only valid for the two versions it compared: serving
    // 1.0.0 -> 2.0.0 in answer to 1.1.0 -> 2.0.0 would misreport what changes.
    test('does not answer for a different version pair', () async {
      await store.save(diffFor('http'));

      expect(await store.find('http', from: '1.1.0', to: '2.0.0'), isNull);
      expect(await store.find('http', from: '1.0.0', to: '2.1.0'), isNull);
      expect(await store.find('dio', from: '1.0.0', to: '2.0.0'), isNull);
    });
  });

  group('save', () {
    test('stamps a generation time the differ does not provide', () async {
      await store.save(diffFor('http'));

      final found = await store.find('http', from: '1.0.0', to: '2.0.0');
      expect(found!.generatedAt, isNotNull);
    });

    test('keeps a time that was already set', () async {
      final stamped = DateTime.utc(2026, 1, 1);
      await store.save(diffFor('http', generatedAt: stamped));

      final found = await store.find('http', from: '1.0.0', to: '2.0.0');
      expect(found!.generatedAt, stamped);
    });

    test('replaces an earlier copy of the same comparison', () async {
      await store.save(diffFor('http'));
      await store.save(
        diffFor(
          'http',
          changes: const [
            ApiChange(
              kind: ApiChangeKind.added,
              declaration: 'Client.head',
              after: 'Future<Response> (Uri url)',
            ),
          ],
        ),
      );

      final found = await store.find('http', from: '1.0.0', to: '2.0.0');
      expect(found!.changes, hasLength(1));
      expect(found.added.single.declaration, 'Client.head');
    });
  });

  group('requests', () {
    test('records a comparison that was asked for and is missing', () async {
      await store.request('http', from: '1.0.0', to: '2.0.0');

      final pending = await store.pendingRequests();
      expect(pending, hasLength(1));
      expect(pending.single.package, 'http');
      expect(pending.single.from, '1.0.0');
      expect(pending.single.to, '2.0.0');
    });

    // The backlog is a set of pairs: a popular package viewed a hundred times
    // is still one comparison to compute.
    test('asking twice records one request', () async {
      await store.request('http', from: '1.0.0', to: '2.0.0');
      await store.request('http', from: '1.0.0', to: '2.0.0');

      expect(await store.pendingRequests(), hasLength(1));
    });

    test('does not record a request for a diff already stored', () async {
      await store.save(diffFor('http'));
      await store.request('http', from: '1.0.0', to: '2.0.0');

      expect(await store.pendingRequests(), isEmpty);
    });

    test('storing a diff clears its pending request', () async {
      await store.request('http', from: '1.0.0', to: '2.0.0');
      await store.save(diffFor('http'));

      expect(await store.pendingRequests(), isEmpty);
    });

    test('leaves other pending requests alone', () async {
      await store.request('http', from: '1.0.0', to: '2.0.0');
      await store.request('dio', from: '4.0.0', to: '5.0.0');
      await store.save(diffFor('http'));

      final pending = await store.pendingRequests();
      expect(pending.map((r) => r.package), ['dio']);
    });

    test('returns the oldest requests first, up to the limit', () async {
      await store.request('a', from: '1.0.0', to: '2.0.0');
      await store.request('b', from: '1.0.0', to: '2.0.0');
      await store.request('c', from: '1.0.0', to: '2.0.0');

      final pending = await store.pendingRequests(limit: 2);
      expect(pending.map((r) => r.package), ['a', 'b']);
    });
  });
}
