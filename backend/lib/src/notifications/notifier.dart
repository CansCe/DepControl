import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import '../repository/notification_store.dart';
import '../services/logger.dart';
import 'notification_message.dart';
import 'webhook_url.dart';

/// What happened when a change was announced.
class NotificationOutcome {
  const NotificationOutcome({
    this.sent = 0,
    this.skipped = 0,
    this.alreadySent = 0,
    this.failed = 0,
  });

  /// Delivered.
  final int sent;

  /// Did not clear the target's bar.
  final int skipped;

  /// Another run had already claimed this change for this target.
  final int alreadySent;

  /// Cleared the bar, was claimed, and the request did not succeed.
  final int failed;

  int get considered => sent + skipped + alreadySent + failed;

  @override
  String toString() => 'sent $sent, skipped $skipped, '
      'already sent $alreadySent, failed $failed';
}

/// Announces a project's changes to the places its owner asked for.
///
/// Delivery is at-most-once per (target, revision): the claim is taken before
/// the request goes out, so a scan that runs twice, or a machine that dies
/// mid-send, cannot produce a second alert. That trades a delivery that might
/// be lost for one that might be doubled, deliberately and in that direction —
/// an alert repeated days later, about a change already dealt with, does more
/// damage to a channel's credibility than a missed one does.
class Notifier {
  Notifier({
    required NotificationStore store,
    http.Client? client,
    this.appBaseUrl,
    Duration timeout = const Duration(seconds: 10),
  })  : _store = store,
        _client = client ?? http.Client(),
        _timeout = timeout;

  final NotificationStore _store;
  final http.Client _client;
  final Duration _timeout;

  /// Where the UI lives, so a message can link to the report. Null when the
  /// deployment has not said, in which case messages carry no link rather than
  /// a guessed one.
  final String? appBaseUrl;

  static final _log = log.tagged('notify');

  /// Tells everyone watching [project] about [diff].
  ///
  /// [revisionId] is what makes the delivery idempotent — it identifies the
  /// change rather than the run, so two scans that produce the same revision
  /// announce it once between them.
  Future<NotificationOutcome> announce({
    required Project project,
    required ReportDiff diff,
    required String revisionId,
  }) async {
    final ownerId = project.ownerId;
    if (ownerId == null) return const NotificationOutcome();

    final targets = await _store.targetsWatching(
      ownerId: ownerId,
      projectId: project.id,
    );
    if (targets.isEmpty) return const NotificationOutcome();

    var sent = 0;
    var skipped = 0;
    var alreadySent = 0;
    var failed = 0;

    for (final target in targets) {
      if (!NotificationRules.shouldNotify(target, diff)) {
        skipped++;
        continue;
      }

      // Claimed before the request. Everything after this point has happened
      // exactly once for this (target, revision), including the failures.
      final claimed = await _store.claimDelivery(
        targetId: target.id,
        revisionId: revisionId,
      );
      if (!claimed) {
        alreadySent++;
        continue;
      }

      final reason = NotificationRules.reason(target, diff);
      final message = NotificationMessage.of(
        project: project,
        diff: diff,
        reason: reason,
        link: _linkTo(project),
      );

      final failure = await _deliver(target, message);
      if (failure == null) {
        sent++;
        _log.info(
          'Told ${target.channel.name} about ${project.name}: $reason.',
        );
      } else {
        failed++;
        _log.warn(
          'Could not tell ${target.channel.name} about ${project.name}: '
          '$failure',
        );
      }

      await _store.recordDelivery(
        targetId: target.id,
        revisionId: revisionId,
        succeeded: failure == null,
        detail: failure,
      );
    }

    return NotificationOutcome(
      sent: sent,
      skipped: skipped,
      alreadySent: alreadySent,
      failed: failed,
    );
  }

  /// Posts [message] to [target], returning null on success or a reason.
  ///
  /// The URL is re-validated here rather than trusted from the database. It was
  /// checked when it was written, but the allowlist can narrow, and a row can
  /// be edited by something other than this application — an outbound request
  /// to an arbitrary address is not a thing to take on trust from storage.
  Future<String?> _deliver(
    NotificationTarget target,
    NotificationMessage message,
  ) async {
    final Uri url;
    try {
      url = WebhookUrl.parse(target.url, target.channel);
    } on WebhookUrlError catch (e) {
      return 'the stored URL is not deliverable: ${e.message}';
    }

    final http.Response response;
    try {
      response = await _client
          .post(
            url,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(message.payloadFor(target.channel)),
          )
          .timeout(_timeout);
    } on TimeoutException {
      return 'timed out after ${_timeout.inSeconds}s';
    } on http.ClientException catch (e) {
      return 'the request failed: ${e.message}';
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return null;

    // Slack answers 4xx with a one-word body — `invalid_payload`,
    // `channel_not_found` — which is the whole diagnosis and is worth keeping.
    final detail = response.body.trim();
    return 'HTTP ${response.statusCode}'
        '${detail.isEmpty ? '' : ': ${detail.length > 200 ? '${detail.substring(0, 200)}…' : detail}'}';
  }

  String? _linkTo(Project project) {
    final base = appBaseUrl;
    if (base == null || base.isEmpty) return null;
    final trimmed = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    return '$trimmed/projects/${project.id}';
  }

  void close() => _client.close();
}
