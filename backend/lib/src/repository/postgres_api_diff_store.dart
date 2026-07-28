import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'api_diff_store.dart';

/// Postgres-backed [ApiDiffStore].
///
/// Two tables: `api_diffs` holds computed comparisons keyed by
/// (package, from, to), and `api_diff_requests` holds the ones still wanted.
/// Neither is owner-scoped — a comparison between two published versions is the
/// same fact for every user — so a diff computed for one project's report is
/// immediately available to every other project that depends on the same
/// package.
///
/// Shares the connection [Pool] with the project repository rather than opening
/// its own: a Supabase pooler has a connection budget, and these queries are
/// infrequent.
class PostgresApiDiffStore implements ApiDiffStore {
  PostgresApiDiffStore(this._pool);

  final Pool _pool;

  @override
  Future<ApiDiff?> find(
    String package, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      Sql.named('''
        select package, from_version, to_version, changes, generated_at
        from api_diffs
        where package = @package:text
          and from_version = @from:text
          and to_version = @to:text
      '''),
      parameters: {'package': package, 'from': from, 'to': to},
    );
    if (result.isEmpty) return null;

    final row = result.first.toColumnMap();
    return ApiDiff(
      package: row['package'] as String,
      from: row['from_version'] as String,
      to: row['to_version'] as String,
      changes: _changesFrom(row['changes']),
      generatedAt: row['generated_at'] as DateTime?,
    );
  }

  @override
  Future<void> save(ApiDiff diff) async {
    await _pool.runTx((session) async {
      await session.execute(
        Sql.named('''
          insert into api_diffs (package, from_version, to_version, changes,
                                 generated_at)
          values (@package:text, @from:text, @to:text, @changes:jsonb,
                  @generatedAt:timestamptz)
          on conflict (package, from_version, to_version) do update set
            changes      = excluded.changes,
            generated_at = excluded.generated_at
        '''),
        parameters: {
          'package': diff.package,
          'from': diff.from,
          'to': diff.to,
          'changes': diff.changes.map((c) => c.toJson()).toList(),
          'generatedAt': diff.generatedAt ?? DateTime.now().toUtc(),
        },
      );

      // The pair is no longer wanted now that it exists.
      await session.execute(
        Sql.named('''
          delete from api_diff_requests
          where package = @package:text
            and from_version = @from:text
            and to_version = @to:text
        '''),
        parameters: {'package': diff.package, 'from': diff.from, 'to': diff.to},
      );
    });
  }

  @override
  Future<void> request(
    String package, {
    required String from,
    required String to,
  }) async {
    // `do nothing` rather than an update: re-asking should not push a pair to
    // the back of an oldest-first queue.
    await _pool.execute(
      Sql.named('''
        insert into api_diff_requests (package, from_version, to_version,
                                       requested_at)
        values (@package:text, @from:text, @to:text, @requestedAt:timestamptz)
        on conflict (package, from_version, to_version) do nothing
      '''),
      parameters: {
        'package': package,
        'from': from,
        'to': to,
        'requestedAt': DateTime.now().toUtc(),
      },
    );
  }

  @override
  Future<List<ApiDiffRequest>> pendingRequests({int limit = 50}) async {
    final result = await _pool.execute(
      Sql.named('''
        select r.package, r.from_version, r.to_version, r.requested_at
        from api_diff_requests r
        where not exists (
          select 1 from api_diffs d
          where d.package = r.package
            and d.from_version = r.from_version
            and d.to_version = r.to_version
        )
        order by r.requested_at
        limit @limit:int8
      '''),
      parameters: {'limit': limit},
    );

    return result.map((row) {
      final columns = row.toColumnMap();
      return ApiDiffRequest(
        package: columns['package'] as String,
        from: columns['from_version'] as String,
        to: columns['to_version'] as String,
        requestedAt: columns['requested_at'] as DateTime?,
      );
    }).toList();
  }

  /// jsonb usually decodes to a parsed Dart list; some driver paths hand it back
  /// as the raw string.
  static List<ApiChange> _changesFrom(Object? raw) {
    final list = switch (raw) {
      final String json => jsonDecode(json),
      final List list => list,
      _ => const [],
    };
    if (list is! List) return const [];
    return list
        .map((e) => ApiChange.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }
}
