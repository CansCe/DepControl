import 'package:shared/shared.dart';

/// Where a company's license rules live.
///
/// Owner-scoped like everything else here: the policy is a statement about what
/// one organisation will ship, and there is no such thing as a policy that is
/// correct for everyone. A user who has never edited theirs reads back
/// [LicensePolicy.standard] rather than an empty policy, so a compliance report
/// is useful on the first run — an empty policy would clear every dependency,
/// which is the one answer guaranteed to be wrong.
abstract class LicensePolicyStore {
  /// [ownerId]'s policy, or [LicensePolicy.standard] if they have not set one —
  /// saying which.
  ///
  /// `isCustom` is not decoration. "Your policy forbids this package" and
  /// "nobody here has written a policy yet and the default forbids this
  /// package" send a reader to two different places, and only the store knows
  /// which one it just handed back.
  Future<({LicensePolicy policy, bool isCustom})> forOwner(String ownerId);

  /// Replaces [ownerId]'s policy wholesale.
  ///
  /// Whole-document rather than a patch: a policy is read as one thing, and
  /// merging partial edits into stored rules is how a category quietly keeps a
  /// value the editor thought they had removed.
  Future<LicensePolicy> save(String ownerId, LicensePolicy policy);

  /// Drops [ownerId]'s policy, so they read the standard one again.
  Future<void> reset(String ownerId);
}

/// In-memory [LicensePolicyStore], used when no database is configured and by
/// tests. State is lost on restart.
class InMemoryLicensePolicyStore implements LicensePolicyStore {
  final _policies = <String, LicensePolicy>{};

  @override
  Future<({LicensePolicy policy, bool isCustom})> forOwner(
    String ownerId,
  ) async {
    final stored = _policies[ownerId];
    return stored == null
        ? (policy: LicensePolicy.standard, isCustom: false)
        : (policy: stored, isCustom: true);
  }

  @override
  Future<LicensePolicy> save(String ownerId, LicensePolicy policy) async {
    _policies[ownerId] = policy;
    return policy;
  }

  @override
  Future<void> reset(String ownerId) async => _policies.remove(ownerId);
}
