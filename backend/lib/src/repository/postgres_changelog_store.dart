import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'changelog_store.dart';

/// Postgres-backed [ChangelogStore]. Tables in `backend/sql/changelogs.sql`.
class PostgresChangelogStore implements ChangelogStore {
  const PostgresChangelogStore(this._pool);

  final Pool _pool;

  @override
  Future<List<ChangelogEntry>> entriesFor(
    String package, {
    required String ecosystem,
  }) async {
    final result = await _pool.execute(
      Sql.named('''
        select version, notes, released
        from changelog_entries
        where ecosystem = @ecosystem:text and package = @package:text
      '''),
      parameters: {'ecosystem': ecosystem, 'package': package},
    );

    return [
      for (final row in result)
        ChangelogEntry(
          version: row.toColumnMap()['version'] as String,
          notes: row.toColumnMap()['notes'] as String,
          released: row.toColumnMap()['released'] as DateTime?,
        ),
    ];
  }

  @override
  Future<bool> hasRead(
    String package, {
    required String ecosystem,
    required String version,
  }) async {
    final result = await _pool.execute(
      Sql.named('''
        select 1 from changelog_reads
        where ecosystem = @ecosystem:text
          and package = @package:text
          and version = @version:text
      '''),
      parameters: {
        'ecosystem': ecosystem,
        'package': package,
        'version': version,
      },
    );
    return result.isNotEmpty;
  }

  @override
  Future<void> saveRead(
    String package, {
    required String ecosystem,
    required String version,
    required List<ChangelogEntry> entries,
    String? failure,
  }) async {
    // One transaction: a reading that recorded its entries but not the fact
    // that it happened would be repeated forever, and one that recorded the
    // read but not the entries would answer "nothing to say" for a package that
    // has plenty.
    await _pool.runTx((session) async {
      for (final entry in entries) {
        await session.execute(
          Sql.named('''
            insert into changelog_entries
              (ecosystem, package, version, notes, released, read_from)
            values
              (@ecosystem:text, @package:text, @version:text, @notes:text,
               @released:date, @readFrom:text)
            on conflict (ecosystem, package, version) do update set
              notes     = excluded.notes,
              released  = excluded.released,
              read_from = excluded.read_from,
              read_at   = now()
          '''),
          parameters: {
            'ecosystem': ecosystem,
            'package': package,
            'version': entry.version,
            'notes': entry.notes,
            'released': entry.released,
            'readFrom': version,
          },
        );
      }

      await session.execute(
        Sql.named('''
          insert into changelog_reads (ecosystem, package, version, failure)
          values (@ecosystem:text, @package:text, @version:text, @failure:text)
          on conflict (ecosystem, package, version) do update set
            failure = excluded.failure,
            read_at = now()
        '''),
        parameters: {
          'ecosystem': ecosystem,
          'package': package,
          'version': version,
          'failure': failure,
        },
      );

      await session.execute(
        Sql.named('''
          delete from changelog_requests
          where ecosystem = @ecosystem:text
            and package = @package:text
            and version = @version:text
        '''),
        parameters: {
          'ecosystem': ecosystem,
          'package': package,
          'version': version,
        },
      );
    });
  }

  @override
  Future<void> request(
    String package, {
    required String ecosystem,
    required String version,
  }) async {
    // `do nothing` rather than an update: re-asking must not push a version to
    // the back of an oldest-first queue. The `not exists` keeps an already-read
    // archive out of the backlog, including the ones that were read and had
    // nothing to say.
    await _pool.execute(
      Sql.named('''
        insert into changelog_requests (ecosystem, package, version)
        select @ecosystem:text, @package:text, @version:text
        where not exists (
          select 1 from changelog_reads
          where ecosystem = @ecosystem:text
            and package = @package:text
            and version = @version:text
        )
        on conflict (ecosystem, package, version) do nothing
      '''),
      parameters: {
        'ecosystem': ecosystem,
        'package': package,
        'version': version,
      },
    );
  }

  @override
  Future<List<ChangelogRequest>> pendingRequests({int limit = 50}) async {
    final result = await _pool.execute(
      Sql.named('''
        select r.ecosystem, r.package, r.version, r.requested_at
        from changelog_requests r
        where not exists (
          select 1 from changelog_reads d
          where d.ecosystem = r.ecosystem
            and d.package = r.package
            and d.version = r.version
        )
        order by r.requested_at
        limit @limit:int8
      '''),
      parameters: {'limit': limit},
    );

    return [
      for (final row in result)
        ChangelogRequest(
          ecosystem: row.toColumnMap()['ecosystem'] as String,
          package: row.toColumnMap()['package'] as String,
          version: row.toColumnMap()['version'] as String,
          requestedAt: row.toColumnMap()['requested_at'] as DateTime?,
        ),
    ];
  }
}
