import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Where the API lives, baked in at build time:
///
/// ```
/// flutter build web --dart-define=API_BASE_URL=https://depcontrol-api.fly.dev
/// ```
///
/// A deployed frontend is served from a different origin than the API, so the
/// address cannot be a runtime lookup against the page's own origin. It falls
/// back to the local dev server, so `flutter run` still needs no flags.
const String kDefaultApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080',
);

/// Talks to the Dart Frog backend.
///
/// Every endpoint except `GET /` requires a Supabase access token: projects are
/// owned by the user who created them. The token is read from the current
/// session on each request, so it always reflects the latest background
/// refresh rather than a value captured at construction.
class ApiClient {
  ApiClient({
    this.baseUrl = kDefaultApiBaseUrl,
    http.Client? client,
    Future<String?> Function()? accessToken,
  })  : _client = client ?? http.Client(),
        _accessToken = accessToken ?? _sessionToken;

  final String baseUrl;
  final http.Client _client;
  final Future<String?> Function() _accessToken;

  static Future<String?> _sessionToken() async =>
      Supabase.instance.client.auth.currentSession?.accessToken;

  /// The caller's projects — active ones by default, archived ones when
  /// [archived] is true. Never both: archiving is how someone puts a project
  /// out of the way.
  Future<List<Project>> listProjects({bool archived = false}) async {
    final json = await _send(() async => _client.get(
          Uri.parse('$baseUrl/projects${archived ? '?archived=true' : ''}'),
          headers: await _headers(),
        ));
    return (json['projects'] as List? ?? const [])
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Archives or restores a project. The project and its report are kept
  /// either way.
  Future<Project> setArchived(
    String projectId, {
    required bool archived,
  }) async {
    final json = await _send(() async => _client.patch(
          Uri.parse('$baseUrl/projects/$projectId'),
          headers: await _headers(json: true),
          body: jsonEncode({'archived': archived}),
        ));
    return Project.fromJson(json['project'] as Map<String, dynamic>);
  }

  /// Deletes a project and its report. There is no undo on the server, so
  /// callers are responsible for confirming first.
  Future<void> deleteProject(String projectId) async {
    await _sendNoContent(() async => _client.delete(
          Uri.parse('$baseUrl/projects/$projectId'),
          headers: await _headers(),
        ));
  }

  /// Ingests a project by git URL and returns its first report.
  Future<(Project, DepReport)> addProject(String gitUrl, {String? ref}) async {
    final json = await _send(() async => _client.post(
          Uri.parse('$baseUrl/projects'),
          headers: await _headers(json: true),
          body: jsonEncode({'gitUrl': gitUrl, if (ref != null) 'ref': ref}),
        ));
    return (
      Project.fromJson(json['project'] as Map<String, dynamic>),
      DepReport.fromJson(json['report'] as Map<String, dynamic>),
    );
  }

  /// Re-fetches the repository and re-analyzes it, replacing the stored report.
  ///
  /// Distinct from [report], which only reads what was already stored: a report
  /// goes stale as soon as a dependency publishes a new version or advisory.
  Future<(Project, DepReport)> refreshProject(String projectId) async {
    final json = await _send(() async => _client.post(
          Uri.parse('$baseUrl/projects/$projectId/refresh'),
          headers: await _headers(json: true),
        ));
    return (
      Project.fromJson(json['project'] as Map<String, dynamic>),
      DepReport.fromJson(json['report'] as Map<String, dynamic>),
    );
  }

  Future<DepReport?> report(String projectId) async {
    final json = await _send(() async => _client.get(
          Uri.parse('$baseUrl/projects/$projectId'),
          headers: await _headers(),
        ));
    final report = json['report'];
    return report == null
        ? null
        : DepReport.fromJson(report as Map<String, dynamic>);
  }

  /// What changes if [package] moves to its newest published version.
  ///
  /// Both halves can be absent, for different reasons: a null `impact` means
  /// there is nothing to compare — already newest, or no resolved version to
  /// start from — while a null `apiDiff` means nothing has compared the two
  /// versions' public APIs yet. Asking is what puts that comparison in the
  /// queue, so a second look at the same package will usually have it.
  Future<UpgradeDetails> upgradeDetails(
    String projectId,
    String package,
  ) async {
    final json = await _send(() async => _client.get(
          Uri.parse('$baseUrl/projects/$projectId/upgrade/$package'),
          headers: await _headers(),
        ));
    return UpgradeDetails.fromJson(json);
  }

  /// Verified fixes for the advisories in this project's stored report.
  ///
  /// Every suggestion has been through the resolver on the server, so anything
  /// returned here is known to reach a fixed version rather than merely to look
  /// like it should.
  Future<RemediationPlan> remediation(String projectId) async {
    final json = await _send(() async => _client.get(
          Uri.parse('$baseUrl/projects/$projectId/remediation'),
          headers: await _headers(),
        ));
    return RemediationPlan.fromJson(json);
  }

  /// Every dependency's license in this project's stored report, judged
  /// against the caller's policy.
  ///
  /// `policyIsCustom` says whether anyone has actually written those rules. A
  /// reader looking at a forbidden dependency needs to know whether they are
  /// reading their own company's decision or this app's default, because those
  /// send them to different places.
  Future<({LicenseReport report, bool policyIsCustom})> licenseReport(
    String projectId,
  ) async {
    final json = await _send(() async => _client.get(
          Uri.parse('$baseUrl/projects/$projectId/licenses'),
          headers: await _headers(),
        ));
    return (
      report: LicenseReport.fromJson(json['report'] as Map<String, dynamic>),
      policyIsCustom: json['policyIsCustom'] as bool? ?? false,
    );
  }

  /// The same report as a CSV manifest — the artefact whoever signs off on
  /// shipping actually opens.
  Future<String> licenseManifest(String projectId) => _sendText(
        () async => _client.get(
          Uri.parse('$baseUrl/projects/$projectId/licenses?format=csv'),
          headers: await _headers(),
        ),
      );

  /// The caller's license rules, and the standard ones to compare against.
  Future<({LicensePolicy policy, bool isCustom, LicensePolicy standard})>
      licensePolicy() async {
    final json = await _send(() async => _client.get(
          Uri.parse('$baseUrl/policy/licenses'),
          headers: await _headers(),
        ));
    return _policyFrom(json);
  }

  /// Replaces the caller's license rules. Whole-document: a partial update
  /// would leave no way to remove a rule.
  Future<({LicensePolicy policy, bool isCustom, LicensePolicy standard})>
      saveLicensePolicy(LicensePolicy policy) async {
    final json = await _send(() async => _client.put(
          Uri.parse('$baseUrl/policy/licenses'),
          headers: await _headers(json: true),
          body: jsonEncode(policy.toJson()),
        ));
    return _policyFrom(json);
  }

  /// Drops the caller's rules, so the standard policy applies again.
  Future<({LicensePolicy policy, bool isCustom, LicensePolicy standard})>
      resetLicensePolicy() async {
    final json = await _send(() async => _client.delete(
          Uri.parse('$baseUrl/policy/licenses'),
          headers: await _headers(),
        ));
    return _policyFrom(json);
  }

  static ({LicensePolicy policy, bool isCustom, LicensePolicy standard})
      _policyFrom(Map<String, dynamic> json) => (
            policy:
                LicensePolicy.fromJson(json['policy'] as Map<String, dynamic>),
            isCustom: json['isCustom'] as bool? ?? false,
            standard: LicensePolicy.fromJson(
              json['standard'] as Map<String, dynamic>,
            ),
          );

  Future<ResolutionResult> simulate(
    String projectId,
    ResolutionRequest request,
  ) async {
    final json = await _send(() async => _client.post(
          Uri.parse('$baseUrl/projects/$projectId/resolve'),
          headers: await _headers(json: true),
          body: jsonEncode(request.toJson()),
        ));
    return ResolutionResult.fromJson(json);
  }

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await _accessToken();
    return {
      if (json) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Runs a request whose successful response is not JSON — the CSV manifest.
  ///
  /// Errors still are, so the failure path decodes and reports them the same
  /// way [_send] does; only the success path differs.
  Future<String> _sendText(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request();
    } catch (e) {
      throw ApiException('Cannot reach the API at $baseUrl — is it running?');
    }
    if (res.statusCode < 400) return res.body;

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // Reported using the status code alone.
    }

    if (res.statusCode == 401) {
      throw ApiAuthException(
        json?['reason']?.toString() ??
            'Your session has expired. Please sign in again.',
      );
    }
    throw ApiException(
      json?['error']?.toString() ?? 'Request failed (${res.statusCode})',
    );
  }

  /// Runs a request that succeeds with no body, such as a delete.
  ///
  /// [_send] cannot serve these: it requires a JSON object back, and a 204 has
  /// nothing in it by definition.
  Future<void> _sendNoContent(
    Future<http.Response> Function() request,
  ) async {
    final http.Response res;
    try {
      res = await request();
    } catch (e) {
      throw ApiException('Cannot reach the API at $baseUrl — is it running?');
    }
    if (res.statusCode < 400) return;

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // Reported using the status code alone.
    }

    if (res.statusCode == 401) {
      throw ApiAuthException(
        json?['reason']?.toString() ??
            'Your session has expired. Please sign in again.',
      );
    }
    throw ApiException(
      json?['error']?.toString() ?? 'Request failed (${res.statusCode})',
    );
  }

  /// Runs a request and decodes it, turning every non-2xx response into an
  /// [ApiException]. Without this an error body — which has no `projects` or
  /// `project` key — surfaced as an opaque cast error at the call site.
  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
  ) async {
    final http.Response res;
    try {
      res = await request();
    } catch (e) {
      throw ApiException('Cannot reach the API at $baseUrl — is it running?');
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // A non-JSON body is reported using the status code alone.
    }

    if (res.statusCode == 401) {
      throw ApiAuthException(
        json?['reason']?.toString() ??
            json?['error']?.toString() ??
            'Your session has expired. Please sign in again.',
      );
    }
    if (res.statusCode >= 400) {
      throw ApiException(
        json?['error']?.toString() ?? 'Request failed (${res.statusCode})',
      );
    }
    if (json == null) throw ApiException('Unexpected response from $baseUrl');
    return json;
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The request was rejected for lack of a valid session. Callers should send
/// the user back to sign-in rather than showing a generic failure.
class ApiAuthException extends ApiException {
  ApiAuthException(super.message);
}
