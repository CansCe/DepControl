import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// `/policy/licenses` — the caller's rules about which dependency licenses
/// their code may ship.
///
/// * `GET` -> the current policy, and the standard one alongside it.
/// * `PUT` -> replaces it wholesale.
/// * `DELETE` -> drops it, so the standard policy applies again.
///
/// A user who has never written one reads back [LicensePolicy.standard]. The
/// response says which of the two it is, because "we decided this" and "nobody
/// has decided yet" are different things to be looking at when a report tells
/// you a dependency is forbidden.
Future<Response> onRequest(RequestContext context) async {
  return switch (context.request.method) {
    HttpMethod.get => _get(context),
    HttpMethod.put => _put(context),
    HttpMethod.delete => _delete(context),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _get(RequestContext context) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final stored = await deps.licensePolicies.forOwner(user.id);
  return Response.json(
    body: _body(stored.policy, isCustom: stored.isCustom),
  );
}

/// Replaces the policy. Whole-document, because that is how it is read: a
/// partial update would leave the caller unable to remove a rule.
Future<Response> _put(RequestContext context) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final LicensePolicy policy;
  try {
    final body = await context.request.json() as Map<String, dynamic>;
    policy = LicensePolicy.fromJson(body);
  } catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'body must be a license policy: '
            '{categories: {...}, licenses: {...}, checkDevDependencies: bool}',
      },
    );
  }

  final saved = await deps.licensePolicies.save(user.id, policy);
  return Response.json(body: _body(saved, isCustom: true));
}

Future<Response> _delete(RequestContext context) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  await deps.licensePolicies.reset(user.id);
  return Response.json(
    body: _body(LicensePolicy.standard, isCustom: false),
  );
}

/// The policy, whether anyone wrote it, and the standard one — so a client can
/// offer "reset to default" and show what that would change without a second
/// request.
Map<String, dynamic> _body(LicensePolicy policy, {required bool isCustom}) => {
      'policy': policy.toJson(),
      'isCustom': isCustom,
      'standard': LicensePolicy.standard.toJson(),
    };
