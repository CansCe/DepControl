import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'license_policy_store.dart';

/// Postgres-backed [LicensePolicyStore].
///
/// One row per owner, holding the whole policy as JSONB. The shape is this
/// app's rather than the database's on purpose: a policy is read and written
/// whole and never queried across, so normalising it into rule tables would buy
/// joins and cost the ability to add a field without a migration.
///
/// Shares the connection [Pool] with the other stores — see `Deps`.
class PostgresLicensePolicyStore implements LicensePolicyStore {
  PostgresLicensePolicyStore(this._pool);

  final Pool _pool;

  @override
  Future<({LicensePolicy policy, bool isCustom})> forOwner(
    String ownerId,
  ) async {
    final result = await _pool.execute(
      Sql.named('''
        select policy from license_policies where owner_id = @ownerId:uuid
      '''),
      parameters: {'ownerId': ownerId},
    );
    if (result.isEmpty) {
      return (policy: LicensePolicy.standard, isCustom: false);
    }

    // jsonb usually decodes to a parsed Dart map; some driver paths hand it
    // back as the raw string.
    final decoded = switch (result.first.toColumnMap()['policy']) {
      final String json => jsonDecode(json),
      final Map map => map,
      _ => null,
    };
    if (decoded is! Map) {
      return (policy: LicensePolicy.standard, isCustom: false);
    }
    return (
      policy: LicensePolicy.fromJson(decoded.cast<String, dynamic>()),
      isCustom: true,
    );
  }

  @override
  Future<LicensePolicy> save(String ownerId, LicensePolicy policy) async {
    await _pool.execute(
      Sql.named('''
        insert into license_policies (owner_id, policy, updated_at)
        values (@ownerId:uuid, @policy:jsonb, @updatedAt:timestamptz)
        on conflict (owner_id) do update set
          policy     = excluded.policy,
          updated_at = excluded.updated_at
      '''),
      parameters: {
        'ownerId': ownerId,
        'policy': policy.toJson(),
        'updatedAt': DateTime.now().toUtc(),
      },
    );
    return policy;
  }

  @override
  Future<void> reset(String ownerId) async {
    await _pool.execute(
      Sql.named('delete from license_policies where owner_id = @ownerId:uuid'),
      parameters: {'ownerId': ownerId},
    );
  }
}
