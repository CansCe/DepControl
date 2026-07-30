import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/notifications/webhook_url.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';

/// `/notifications` — where this owner's changes get announced.
///
/// GET lists them; POST adds one. Both are scoped to the caller: a target is a
/// statement about one person's channels, and the webhook URL in it is a
/// credential.
///
/// **Reads never return the URL.** Anything holding an incoming-webhook URL can
/// post to the channel, so a target reads back as its host and the last few
/// characters of its path — enough to tell two apart, not enough to use. That
/// is also why there is no "reveal" parameter: an endpoint that can be asked
/// for the credential is one that eventually hands it to the wrong caller.
Future<Response> onRequest(RequestContext context) async {
  return switch (context.request.method) {
    HttpMethod.get => _list(context),
    HttpMethod.post => _create(context),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _list(RequestContext context) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final targets = await deps.notifications.targetsFor(user.id);
  return Response.json(
    body: {
      'targets': [
        for (final target in targets)
          target.toJson(redactedUrl: WebhookUrl.redact(target.url)),
      ],
    },
  );
}

Future<Response> _create(RequestContext context) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final Map<String, dynamic> body;
  try {
    body = await context.request.json() as Map<String, dynamic>;
  } catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'expected a JSON object'},
    );
  }

  final channel = _channelOf(body['channel']);
  if (channel == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'channel must be one of '
            '${NotificationChannel.values.map((c) => c.name).join(', ')}',
      },
    );
  }

  final rawUrl = body['url'];
  if (rawUrl is! String) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'url is required'},
    );
  }

  try {
    WebhookUrl.parse(rawUrl, channel);
  } on WebhookUrlError catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  }

  final onNewAdvisory = body['onNewAdvisory'] as bool? ?? true;
  final onBreakingChange = body['onBreakingChange'] as bool? ?? true;
  if (!onNewAdvisory && !onBreakingChange) {
    // Refused rather than saved, because a target that can never fire is
    // indistinguishable from one that is working until the day it matters.
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'turn on at least one of onNewAdvisory and onBreakingChange, '
            'or this target would never fire',
      },
    );
  }

  final severity = _severityOf(body['minSeverity']);
  if (severity == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'minSeverity must be one of '
            '${AdvisorySeverity.values.map((s) => s.name).join(', ')}',
      },
    );
  }

  // A target may name a project, and only one the caller owns. Checked rather
  // than trusted: a project id from somebody else's registry would otherwise
  // create a target that quietly never matches, or — worse, if the id were
  // later transferred — one that does.
  final projectId = body['projectId'] as String?;
  if (projectId != null) {
    final project = await deps.repository.byId(projectId, ownerId: user.id);
    if (project == null) {
      return Response.json(
        statusCode: HttpStatus.notFound,
        body: {'error': 'project not found'},
      );
    }
  }

  final saved = await deps.notifications.save(
    NotificationTarget(
      id: const Uuid().v4(),
      ownerId: user.id,
      projectId: projectId,
      channel: channel,
      url: rawUrl.trim(),
      minSeverity: severity,
      onNewAdvisory: onNewAdvisory,
      onBreakingChange: onBreakingChange,
      createdAt: DateTime.now().toUtc(),
    ),
  );

  return Response.json(
    statusCode: HttpStatus.created,
    body: saved.toJson(redactedUrl: WebhookUrl.redact(saved.url)),
  );
}

NotificationChannel? _channelOf(Object? raw) {
  if (raw is! String) return null;
  for (final channel in NotificationChannel.values) {
    if (channel.name == raw) return channel;
  }
  return null;
}

AdvisorySeverity? _severityOf(Object? raw) {
  if (raw == null) return AdvisorySeverity.high;
  if (raw is! String) return null;
  for (final severity in AdvisorySeverity.values) {
    if (severity.name == raw) return severity;
  }
  return null;
}
