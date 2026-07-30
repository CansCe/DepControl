import 'package:shared/shared.dart';

/// Why a webhook URL was refused, in words the person who typed it can act on.
class WebhookUrlError implements Exception {
  const WebhookUrlError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Validates the URLs this server will POST to.
///
/// Everything else in this application fetches from hosts *it* chose. A
/// notification target is the opposite: a URL a user supplies, which the server
/// then makes an outbound request to from inside its own network. That is a
/// server-side request forgery primitive unless it is constrained, and the
/// constraint has to be an allowlist — a denylist of private ranges loses to
/// DNS rebinding, redirects, IPv6 mappings of IPv4 addresses, and the several
/// spellings of 127.0.0.1 that parse as something else.
///
/// So: https only, and the host must be one a chat provider actually serves
/// incoming webhooks on. A URL that is not one of those is not a webhook this
/// server can deliver to, whatever else it may be.
///
/// This is the same discipline [GitFetcher] applies to repository URLs, for the
/// same reason and with a shorter list.
abstract final class WebhookUrl {
  /// Hosts each channel serves incoming webhooks on.
  ///
  /// Matched as exact hosts or as suffixes beginning with a dot, so
  /// `.webhook.office.com` admits `acme.webhook.office.com` and rejects
  /// `evil-webhook.office.com` and `webhook.office.com.attacker.test` alike.
  static const allowedHosts = <NotificationChannel, List<String>>{
    NotificationChannel.slack: ['hooks.slack.com'],
    NotificationChannel.teams: [
      // The classic Office 365 connector.
      '.webhook.office.com',
      // Power Automate, which is what Microsoft moved Teams webhooks to.
      '.logic.azure.com',
      '.logic.azure.us',
    ],
  };

  /// Returns [raw] parsed, or throws [WebhookUrlError] naming what is wrong.
  ///
  /// Throwing rather than returning null because every failure here has a
  /// different fix and the person pasting a URL should be told which one.
  static Uri parse(String raw, NotificationChannel channel) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const WebhookUrlError('The webhook URL is empty.');
    }

    final Uri url;
    try {
      url = Uri.parse(trimmed);
    } on FormatException {
      throw const WebhookUrlError('That is not a URL.');
    }

    if (url.scheme != 'https') {
      // A webhook URL is a bearer credential — anyone holding it can post to
      // the channel — so it does not travel over plaintext.
      throw const WebhookUrlError('The webhook URL must use https.');
    }

    // `https://hooks.slack.com@attacker.test/` has a host of `attacker.test`
    // and reads to a human as Slack. Refused outright rather than parsed
    // carefully, because there is no legitimate reason for credentials here.
    if (url.userInfo.isNotEmpty) {
      throw const WebhookUrlError(
        'The webhook URL must not contain a username or password.',
      );
    }

    if (url.hasPort && url.port != 443) {
      throw const WebhookUrlError(
        'The webhook URL must use the default https port.',
      );
    }

    final host = url.host.toLowerCase();
    if (host.isEmpty) {
      throw const WebhookUrlError('The webhook URL has no host.');
    }

    if (!_isAllowed(host, channel)) {
      throw WebhookUrlError(
        'This server only delivers to ${describeHosts(channel)}. '
        'A ${channel.label} webhook URL does not look like this one.',
      );
    }

    return url;
  }

  /// Whether [raw] would be accepted, without saying why not.
  static bool isValid(String raw, NotificationChannel channel) {
    try {
      parse(raw, channel);
      return true;
    } on WebhookUrlError {
      return false;
    }
  }

  static bool _isAllowed(String host, NotificationChannel channel) {
    for (final allowed in allowedHosts[channel] ?? const <String>[]) {
      if (allowed.startsWith('.')) {
        // A suffix match, and the leading dot is what makes it one: without it
        // `webhook.office.com` would also admit `evilwebhook.office.com`.
        if (host.endsWith(allowed)) return true;
      } else if (host == allowed) {
        return true;
      }
    }
    return false;
  }

  /// The allowed hosts for [channel], for an error message.
  static String describeHosts(NotificationChannel channel) {
    final hosts = allowedHosts[channel] ?? const <String>[];
    return hosts
        .map((h) => h.startsWith('.') ? '*$h' : h)
        .join(' and ');
  }

  /// A webhook URL as it is safe to show back to its owner.
  ///
  /// The URL *is* the credential: anybody holding it can post to the channel.
  /// So it is stored, used, and never echoed — a target that has been saved
  /// reads back as its host and a stub, which is enough to tell two apart
  /// without handing either of them out again.
  static String redact(String raw) {
    final Uri url;
    try {
      url = Uri.parse(raw.trim());
    } on FormatException {
      return 'a malformed URL';
    }

    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return url.host;

    final last = segments.last;
    final tail = last.length <= 4 ? last : last.substring(last.length - 4);
    return '${url.host}/…$tail';
  }
}
