import 'package:shared/shared.dart';

/// Whether a change is worth telling a target about, and what to say.
///
/// Kept apart from the delivery so the decision can be tested without a socket,
/// and read without one either. "Why did I get this?" and "why did I not?" are
/// the two questions a notification system has to be able to answer.
abstract final class NotificationRules {
  /// Whether [diff] clears the bar [target] set.
  ///
  /// Both rules are opt-in and either is sufficient. A target with neither on
  /// never fires, which is refused when one is written rather than discovered
  /// six months later.
  static bool shouldNotify(NotificationTarget target, ReportDiff diff) {
    if (diff.isEmpty) return false;

    if (target.onNewAdvisory) {
      final worst = diff.worstNewSeverity;
      if (worst != null && worst.atLeastAsBadAs(target.minSeverity)) return true;
    }

    if (target.onBreakingChange && diff.breakingMoves.isNotEmpty) return true;

    return false;
  }

  /// Why [diff] cleared the bar, for the message and for the logs.
  ///
  /// A notification that does not say what triggered it is one nobody can tune,
  /// and the first thing anybody does with an alert they did not want is look
  /// for the setting that stops it.
  static String reason(NotificationTarget target, ReportDiff diff) {
    final reasons = <String>[];

    if (target.onNewAdvisory) {
      final worst = diff.worstNewSeverity;
      if (worst != null && worst.atLeastAsBadAs(target.minSeverity)) {
        reasons.add(
          worst == AdvisorySeverity.unknown
              ? 'an advisory nobody has rated'
              : 'a ${worst.name} advisory',
        );
      }
    }

    if (target.onBreakingChange && diff.breakingMoves.isNotEmpty) {
      final count = diff.breakingMoves.length;
      reasons.add(count == 1 ? 'a breaking change' : '$count breaking changes');
    }

    return reasons.join(' and ');
  }
}

/// A change, written out for a human.
///
/// One text, rendered per channel. Slack and Teams disagree about the envelope
/// and agree about very little else, but the *content* of "here is what changed
/// in your dependencies" is not channel-specific and writing it twice is how
/// the two drift apart.
class NotificationMessage {
  const NotificationMessage({
    required this.title,
    required this.body,
    this.link,
  });

  /// One line: what happened, to which project.
  final String title;

  /// The detail, as Markdown. Both channels render a useful subset.
  final String body;

  /// Where to go and look, when the caller knows the address of the UI.
  final String? link;

  /// Builds the message for [diff] on [project].
  ///
  /// Leads with what would wake somebody — new advisories, worst first — and
  /// puts the routine version moves under them. A reader deals with the top of
  /// a message and stops somewhere in the middle, so the order is most of the
  /// value.
  factory NotificationMessage.of({
    required Project project,
    required ReportDiff diff,
    required String reason,
    String? link,
    int maxLines = 12,
  }) {
    final lines = <String>[];

    for (final entry in diff.newAdvisories) {
      final change = entry.package;
      final advisory = entry.advisory;
      final severity = advisory.severity == AdvisorySeverity.unknown
          ? 'unrated'
          : advisory.severity.name;

      final at = change.toVersion ?? change.fromVersion ?? 'unknown version';
      final fix = advisory.fixedIn == null
          ? 'no fix listed'
          : 'fixed in ${advisory.fixedIn}';

      lines.add(
        '• *${change.label(qualify: _spansEcosystems(diff))} $at* — '
        '$severity: ${advisory.id} ($fix)',
      );
    }

    for (final change in diff.breakingMoves) {
      final direction = change.isDowngrade ? 'downgraded' : 'upgraded';
      lines.add(
        '• *${change.label(qualify: _spansEcosystems(diff))}* $direction '
        '${change.fromVersion} → ${change.toVersion} (breaking)',
      );
    }

    final shown = lines.take(maxLines).toList();
    final hidden = lines.length - shown.length;
    if (hidden > 0) {
      // Said rather than silently truncated: a list that stops without saying
      // so reads as a complete one.
      shown.add('• …and $hidden more.');
    }

    final counts = <String>[
      if (diff.added.isNotEmpty) '${diff.added.length} added',
      if (diff.removed.isNotEmpty) '${diff.removed.length} removed',
      if (diff.moved.isNotEmpty) '${diff.moved.length} changed version',
    ];

    return NotificationMessage(
      title: '${project.name}: $reason',
      body: [
        ...shown,
        if (counts.isNotEmpty) '',
        if (counts.isNotEmpty) 'In all: ${counts.join(', ')}.',
      ].join('\n'),
      link: link,
    );
  }

  /// Whether the diff covers more than one ecosystem, which decides whether
  /// package names need qualifying. `http` means two different things when it
  /// does.
  static bool _spansEcosystems(ReportDiff diff) =>
      diff.packages.map((p) => p.ecosystem).toSet().length > 1;

  /// The JSON body for [channel].
  Map<String, dynamic> payloadFor(NotificationChannel channel) =>
      switch (channel) {
        NotificationChannel.slack => _slack(),
        NotificationChannel.teams => _teams(),
      };

  /// Slack's incoming-webhook shape.
  ///
  /// `text` is set as well as `blocks` because it is what Slack uses for the
  /// notification preview and for clients that do not render blocks; a
  /// blocks-only message shows up in a phone notification as "This content
  /// can't be displayed".
  Map<String, dynamic> _slack() => {
        'text': title,
        'blocks': [
          {
            'type': 'section',
            'text': {'type': 'mrkdwn', 'text': '*$title*'},
          },
          if (body.trim().isNotEmpty)
            {
              'type': 'section',
              'text': {'type': 'mrkdwn', 'text': body},
            },
          if (link != null)
            {
              'type': 'context',
              'elements': [
                {'type': 'mrkdwn', 'text': '<$link|Open the report>'},
              ],
            },
        ],
      };

  /// Teams' MessageCard shape, which the Office 365 connector renders.
  ///
  /// Microsoft is retiring that connector in favour of Power Automate
  /// workflows, which want an Adaptive Card instead. A workflow configured with
  /// the stock "post a card" template will not render this — see the README.
  /// `text` is included regardless, since a workflow that passes the body
  /// through will at least show the words.
  Map<String, dynamic> _teams() => {
        '@type': 'MessageCard',
        '@context': 'https://schema.org/extensions',
        'summary': title,
        'themeColor': '0F62FE',
        'title': title,
        // Teams renders a subset of Markdown and treats single newlines as
        // spaces, which runs every bullet into one paragraph.
        'text': body.replaceAll('\n', '\n\n'),
        if (link != null)
          'potentialAction': [
            {
              '@type': 'OpenUri',
              'name': 'Open the report',
              'targets': [
                {'os': 'default', 'uri': link},
              ],
            },
          ],
      };
}
