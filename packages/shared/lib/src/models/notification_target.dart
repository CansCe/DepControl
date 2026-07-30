import 'dep_advisory.dart';

/// Where a notification is delivered.
///
/// Both are incoming webhooks: a URL the chat provider issues, which anything
/// holding it can post to. That is why there is no OAuth here and no token to
/// refresh — and also why the URL is treated as a credential.
enum NotificationChannel {
  slack,
  teams;

  String get label => switch (this) {
        NotificationChannel.slack => 'Slack',
        NotificationChannel.teams => 'Microsoft Teams',
      };
}

/// One place a project's changes get announced, and the rules for when.
///
/// A target that would fire on everything is a target somebody turns off, so
/// the rules are subtractive: nothing is sent unless it clears a bar the owner
/// set. Both bars are opt-in and at least one must be on, or the target would
/// never fire and would be a saved intention rather than a subscription.
class NotificationTarget {
  const NotificationTarget({
    required this.id,
    required this.ownerId,
    required this.channel,
    required this.url,
    this.projectId,
    this.minSeverity = AdvisorySeverity.high,
    this.onNewAdvisory = true,
    this.onBreakingChange = true,
    this.createdAt,
  });

  final String id;

  /// The Supabase user this belongs to. Every read is scoped by it, the same
  /// way projects are.
  final String ownerId;

  /// The one project this watches, or null for every project the owner has.
  ///
  /// Null is the useful default for a person with a handful of projects and
  /// one team channel. A per-project target is what you reach for when one
  /// repository is noisier or more important than the rest.
  final String? projectId;

  final NotificationChannel channel;

  /// The incoming-webhook URL. **A credential**: anything holding it can post
  /// to the channel, so it is never returned by the API — see
  /// [WebhookUrl.redact].
  final String url;

  /// The mildest advisory band worth waking somebody for.
  ///
  /// Compared against the *worst* new advisory in a change, so a diff carrying
  /// one critical and nine lows clears a threshold of critical. Bands are
  /// ordered worst-first, so "at least this bad" is an index comparison in the
  /// direction that reads backwards; [AdvisorySeverity.atLeastAsBadAs] does it
  /// so nobody has to remember which way.
  final AdvisorySeverity minSeverity;

  /// Whether a newly applying advisory is worth sending.
  final bool onNewAdvisory;

  /// Whether a breaking version move is worth sending, advisory or not.
  final bool onBreakingChange;

  final DateTime? createdAt;

  /// Whether this target watches [project].
  bool watches(String project) => projectId == null || projectId == project;

  /// Whether this target would ever fire. A target with both rules off is a
  /// saved intention rather than a subscription, and is refused on write.
  bool get isActionable => onNewAdvisory || onBreakingChange;

  NotificationTarget copyWith({
    String? projectId,
    bool clearProjectId = false,
    NotificationChannel? channel,
    String? url,
    AdvisorySeverity? minSeverity,
    bool? onNewAdvisory,
    bool? onBreakingChange,
  }) =>
      NotificationTarget(
        id: id,
        ownerId: ownerId,
        projectId: clearProjectId ? null : (projectId ?? this.projectId),
        channel: channel ?? this.channel,
        url: url ?? this.url,
        minSeverity: minSeverity ?? this.minSeverity,
        onNewAdvisory: onNewAdvisory ?? this.onNewAdvisory,
        onBreakingChange: onBreakingChange ?? this.onBreakingChange,
        createdAt: createdAt,
      );

  factory NotificationTarget.fromJson(Map<String, dynamic> json) =>
      NotificationTarget(
        id: json['id'] as String,
        ownerId: json['ownerId'] as String,
        projectId: json['projectId'] as String?,
        channel: NotificationChannel.values.byName(json['channel'] as String),
        url: (json['url'] as String?) ?? '',
        minSeverity: AdvisorySeverity.values.byName(
          (json['minSeverity'] as String?) ?? 'high',
        ),
        onNewAdvisory: (json['onNewAdvisory'] as bool?) ?? true,
        onBreakingChange: (json['onBreakingChange'] as bool?) ?? true,
        createdAt: switch (json['createdAt']) {
          final String s => DateTime.tryParse(s),
          _ => null,
        },
      );

  /// Serialises everything **except the URL**, which the API redacts instead.
  ///
  /// Deliberately not an option the caller passes: a `toJson` that can be told
  /// to include a credential is one that eventually is, in a log line or an
  /// error body nobody thought about.
  Map<String, dynamic> toJson({required String redactedUrl}) => {
        'id': id,
        'ownerId': ownerId,
        if (projectId != null) 'projectId': projectId,
        'channel': channel.name,
        'url': redactedUrl,
        'minSeverity': minSeverity.name,
        'onNewAdvisory': onNewAdvisory,
        'onBreakingChange': onBreakingChange,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      };
}
