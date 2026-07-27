// End-to-end smoke test: drives a RUNNING server over real HTTP.
//
// Unlike `dart test`, this catches wiring problems that only appear in a built
// server — middleware order, dependency injection, JSON shapes, auth enforcement.
//
//   dart run tool/smoke_test.dart
//   dart run tool/smoke_test.dart --url http://localhost:8090
//
// Endpoints under /projects and /me require a Supabase JWT. Without one, only
// the public and auth-rejection checks run. To exercise the full authenticated
// flow, supply a real access token:
//
//   $env:SMOKE_TOKEN="<jwt>"; dart run tool/smoke_test.dart
//
// (Get one from your Flutter app's session, or any signed-in Supabase client.)
import 'dart:convert';
import 'dart:io';

late final String baseUrl;
final _client = HttpClient();

int _passed = 0;
int _failed = 0;

Future<void> main(List<String> args) async {
  baseUrl = _argValue(args, '--url') ?? 'http://localhost:8080';
  final token = Platform.environment['SMOKE_TOKEN'];

  stdout.writeln('Smoke testing $baseUrl');
  stdout.writeln('');

  if (!await _serverIsUp()) {
    stderr.writeln('Server is not reachable at $baseUrl.');
    stderr.writeln('Start it first:  .\\run.cmd');
    exit(2);
  }

  await _publicChecks();
  await _authRejectionChecks();

  if (token == null || token.isEmpty) {
    stdout.writeln('');
    stdout.writeln('SMOKE_TOKEN not set - skipping authenticated flow.');
    stdout.writeln('Set it to also verify project ingest, listing, and '
        'ownership scoping.');
  } else {
    await _authenticatedFlow(token);
  }

  stdout.writeln('');
  stdout.writeln('$_passed passed, $_failed failed');
  exit(_failed == 0 ? 0 : 1);
}

// --- checks ---------------------------------------------------------------

Future<void> _publicChecks() async {
  final res = await _get('/');
  _check('GET / responds 200', res.status == 200, 'got ${res.status}');
  _check(
    'GET / identifies the service',
    res.json?['service'] == 'depcontrol-api',
    'got ${res.json?['service']}',
  );
  _check(
    'GET / lists its endpoints',
    (res.json?['endpoints'] as List?)?.isNotEmpty ?? false,
    'endpoints missing',
  );
}

Future<void> _authRejectionChecks() async {
  for (final path in ['/me', '/projects']) {
    final res = await _get(path);
    _check(
      'GET $path without a token is 401',
      res.status == 401,
      'got ${res.status}',
    );
    _check(
      'GET $path explains why it was rejected',
      (res.json?['reason'] as String?)?.isNotEmpty ?? false,
      'no reason field in ${res.body}',
    );
  }

  final garbage = await _get('/me', token: 'not-a-jwt');
  _check(
    'GET /me with a malformed token is 401',
    garbage.status == 401,
    'got ${garbage.status}',
  );
  _check(
    'a malformed token is not reported as a server error',
    garbage.status != 500,
    'got 500 - verification may be misconfigured',
  );

  final post = await _post('/projects', {'gitUrl': 'https://x/y.git'});
  _check(
    'POST /projects without a token is 401',
    post.status == 401,
    'got ${post.status}',
  );
}

Future<void> _authenticatedFlow(String token) async {
  stdout.writeln('');
  stdout.writeln('Authenticated flow:');

  final me = await _get('/me', token: token);
  _check('GET /me with a valid token is 200', me.status == 200,
      'got ${me.status} - ${me.body}');
  if (me.status != 200) {
    stderr.writeln('  Token rejected; skipping the rest of the flow.');
    return;
  }
  final userId = (me.json?['user'] as Map?)?['id'] as String?;
  _check('GET /me returns a user id', userId != null, 'no user.id');

  final list = await _get('/projects', token: token);
  _check('GET /projects with a valid token is 200', list.status == 200,
      'got ${list.status}');
  final before = (list.json?['projects'] as List?)?.length ?? -1;
  _check('GET /projects returns a list', before >= 0, 'projects missing');

  // Ingest a small, stable public repo.
  final created = await _post(
    '/projects',
    {'gitUrl': 'https://github.com/dart-lang/http.git'},
    token: token,
  );
  _check('POST /projects is 201', created.status == 201,
      'got ${created.status} - ${created.body}');
  if (created.status != 201) return;

  final project = created.json?['project'] as Map<String, dynamic>?;
  final report = created.json?['report'] as Map<String, dynamic>?;
  final id = project?['id'] as String?;

  _check('created project has an id', id != null, 'no id');
  _check(
    'created project is owned by the caller',
    project?['ownerId'] == userId,
    'ownerId=${project?['ownerId']} userId=$userId',
  );
  _check(
    'the report contains dependency nodes',
    (report?['nodes'] as List?)?.isNotEmpty ?? false,
    'no nodes in report',
  );

  if (id == null) return;

  final detail = await _get('/projects/$id', token: token);
  _check('GET /projects/<id> is 200', detail.status == 200,
      'got ${detail.status}');
  _check(
    'GET /projects/<id> returns the same project',
    (detail.json?['project'] as Map?)?['id'] == id,
    'id mismatch',
  );

  final after = await _get('/projects', token: token);
  final count = (after.json?['projects'] as List?)?.length ?? -1;
  _check('the new project appears in the list', count == before + 1,
      'before=$before after=$count');

  final missing = await _get(
    '/projects/00000000-0000-0000-0000-000000000000',
    token: token,
  );
  _check('an unknown project id is 404', missing.status == 404,
      'got ${missing.status}');

  stdout.writeln('');
  stdout.writeln('Created project $id - delete it from Supabase if you do not '
      'want it kept.');
}

// --- helpers --------------------------------------------------------------

void _check(String label, bool ok, String detail) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $label');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $label ($detail)');
  }
}

Future<bool> _serverIsUp() async {
  try {
    await _get('/');
    return true;
  } catch (_) {
    return false;
  }
}

class _Res {
  _Res(this.status, this.body);
  final int status;
  final String body;

  Map<String, dynamic>? get json {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

Future<_Res> _get(String path, {String? token}) async {
  final req = await _client.getUrl(Uri.parse('$baseUrl$path'));
  if (token != null) req.headers.set('Authorization', 'Bearer $token');
  return _read(await req.close());
}

Future<_Res> _post(String path, Object body, {String? token}) async {
  final req = await _client.postUrl(Uri.parse('$baseUrl$path'));
  req.headers.contentType = ContentType.json;
  if (token != null) req.headers.set('Authorization', 'Bearer $token');
  req.write(jsonEncode(body));
  return _read(await req.close());
}

Future<_Res> _read(HttpClientResponse response) async =>
    _Res(response.statusCode, await response.transform(utf8.decoder).join());

String? _argValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
}
