import 'package:shared/shared.dart';

/// Notification targets, and the record of what has already been sent.
///
/// The delivery record is the interesting half. A re-scan that finds the same
/// change twice must not announce it twice, and the thing that guarantees it
/// cannot be "we only scan when something changed" — scans get re-run, machines
/// get restarted mid-send, and a scheduler that fires twice is a configuration
/// mistake rather than an impossibility. So delivery is keyed on
/// (target, revision) and claimed *before* the request goes out.
abstract class NotificationStore {
  /// Every target [ownerId] has, newest first.
  Future<List<NotificationTarget>> targetsFor(String ownerId);

  /// The targets that watch [projectId], across its owner's targets.
  ///
  /// Used by the scanner, which has a project and needs to know who to tell.
  Future<List<NotificationTarget>> targetsWatching({
    required String ownerId,
    required String projectId,
  });

  /// Stores [target], returning it as saved.
  Future<NotificationTarget> save(NotificationTarget target);

  /// Deletes [id], returning whether anything was deleted.
  ///
  /// Returns false rather than throwing for a target owned by someone else, so
  /// a caller cannot tell the two apart.
  Future<bool> delete(String id, {required String ownerId});

  /// Claims the right to deliver [revisionId] to [targetId].
  ///
  /// Returns true for the caller that claimed it and false for everyone after,
  /// so a send happens at most once. Claimed before the request rather than
  /// recorded after it, which trades a delivery that might have been lost for a
  /// delivery that might have been doubled — the right way round for an alert
  /// that names a security advisory, since a duplicate is noise and a repeat of
  /// a *stale* alert is worse than either.
  Future<bool> claimDelivery({
    required String targetId,
    required String revisionId,
  });

  /// Records how a claimed delivery turned out.
  ///
  /// Never un-claims. A failed send stays claimed, so the next scan does not
  /// retry it — the change is still in the history and the next *real* change
  /// will be announced. Retrying an alert on a schedule is how a broken webhook
  /// becomes a loop.
  Future<void> recordDelivery({
    required String targetId,
    required String revisionId,
    required bool succeeded,
    String? detail,
  });
}

class InMemoryNotificationStore implements NotificationStore {
  final _targets = <String, NotificationTarget>{};
  final _claimed = <String>{};
  final _outcomes = <String, ({bool succeeded, String? detail})>{};

  static String _key(String targetId, String revisionId) =>
      '$targetId/$revisionId';

  @override
  Future<List<NotificationTarget>> targetsFor(String ownerId) async {
    final owned = _targets.values.where((t) => t.ownerId == ownerId).toList()
      ..sort((a, b) => (b.createdAt ?? DateTime(0))
          .compareTo(a.createdAt ?? DateTime(0)));
    return owned;
  }

  @override
  Future<List<NotificationTarget>> targetsWatching({
    required String ownerId,
    required String projectId,
  }) async =>
      (await targetsFor(ownerId)).where((t) => t.watches(projectId)).toList();

  @override
  Future<NotificationTarget> save(NotificationTarget target) async {
    _targets[target.id] = target;
    return target;
  }

  @override
  Future<bool> delete(String id, {required String ownerId}) async {
    final target = _targets[id];
    if (target == null || target.ownerId != ownerId) return false;
    _targets.remove(id);
    return true;
  }

  @override
  Future<bool> claimDelivery({
    required String targetId,
    required String revisionId,
  }) async =>
      _claimed.add(_key(targetId, revisionId));

  @override
  Future<void> recordDelivery({
    required String targetId,
    required String revisionId,
    required bool succeeded,
    String? detail,
  }) async {
    _outcomes[_key(targetId, revisionId)] =
        (succeeded: succeeded, detail: detail);
  }

  /// How a delivery turned out, for tests.
  ({bool succeeded, String? detail})? outcomeOf(
    String targetId,
    String revisionId,
  ) =>
      _outcomes[_key(targetId, revisionId)];
}
