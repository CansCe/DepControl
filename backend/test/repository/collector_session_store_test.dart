import 'package:backend/src/repository/collector_session_store.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryCollectorSessionStore store;

  setUp(() => store = InMemoryCollectorSessionStore());

  group('mint', () {
    test('returns a waiting session with no scan yet', () async {
      final grant = await store.mint(
        ownerId: 'u1',
        codeHash: 'hash-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      );

      expect(grant.ownerId, 'u1');
      expect(grant.claimedAt, isNull);
      expect(grant.scanId, isNull);
      expect(grant.toSession().state, CollectorSessionState.waiting);
    });
  });

  group('claim', () {
    test('resolves an unclaimed, unexpired code', () async {
      final minted = await store.mint(
        ownerId: 'u1',
        codeHash: 'hash-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      );

      final claimed = await store.claim('hash-1');

      expect(claimed, isNotNull);
      expect(claimed!.id, minted.id);
      expect(claimed.ownerId, 'u1');
      expect(claimed.toSession().state, CollectorSessionState.claimed);
    });

    test('a code that never existed resolves to nothing', () async {
      expect(await store.claim('never-minted'), isNull);
    });

    // Single-use is the whole point of a pairing code: whoever holds it can
    // submit exactly one bundle, not "until somebody notices".
    test('a second claim of the same code is refused', () async {
      await store.mint(
        ownerId: 'u1',
        codeHash: 'hash-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      );

      final first = await store.claim('hash-1');
      final second = await store.claim('hash-1');

      expect(first, isNotNull);
      expect(second, isNull);
    });

    test('an expired code is refused, not silently claimed', () async {
      await store.mint(
        ownerId: 'u1',
        codeHash: 'hash-1',
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      );

      expect(await store.claim('hash-1'), isNull);
    });
  });

  group('attachScan', () {
    test('records the scan a claim enqueued, readable back by byId', () async {
      final minted = await store.mint(
        ownerId: 'u1',
        codeHash: 'hash-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      );
      await store.claim('hash-1');
      await store.attachScan(minted.id, 'scan-1');

      final grant = await store.byId(minted.id, ownerId: 'u1');
      expect(grant!.scanId, 'scan-1');
    });
  });

  group('byId', () {
    test('is owner-scoped, like every other store here', () async {
      final minted = await store.mint(
        ownerId: 'u1',
        codeHash: 'hash-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      );

      expect(await store.byId(minted.id, ownerId: 'someone-else'), isNull);
      expect(await store.byId(minted.id, ownerId: 'u1'), isNotNull);
    });
  });

  group('CollectorSessionGrant.toSession', () {
    // Expiry is derived at read time rather than stored, so a session that
    // was never claimed reads as expired the moment the clock passes it —
    // without a sweep, and without the row ever being written to say so.
    test('reads an unclaimed, past-expiry grant as expired', () {
      final grant = CollectorSessionGrant(
        id: 's1',
        ownerId: 'u1',
        expiresAt: DateTime.utc(2026, 1, 1, 12),
      );

      final session = grant.toSession(now: DateTime.utc(2026, 1, 1, 12, 1));
      expect(session.state, CollectorSessionState.expired);
    });

    test('reads a claimed grant as claimed even past its expiry', () {
      final grant = CollectorSessionGrant(
        id: 's1',
        ownerId: 'u1',
        expiresAt: DateTime.utc(2026, 1, 1, 12),
        claimedAt: DateTime.utc(2026, 1, 1, 11, 59),
      );

      final session = grant.toSession(now: DateTime.utc(2026, 1, 1, 12, 5));
      expect(session.state, CollectorSessionState.claimed);
    });
  });
}
