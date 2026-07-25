import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

/// Talks to the Dart Frog backend.
class ApiClient {
  ApiClient({this.baseUrl = 'http://localhost:8080', http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Future<List<Project>> listProjects() async {
    final res = await _client.get(Uri.parse('$baseUrl/projects'));
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return (json['projects'] as List)
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Ingests a project by git URL and returns its first report.
  Future<(Project, DepReport)> addProject(String gitUrl, {String? ref}) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/projects'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'gitUrl': gitUrl, if (ref != null) 'ref': ref}),
    );
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException(json['error']?.toString() ?? 'Request failed');
    }
    return (
      Project.fromJson(json['project'] as Map<String, dynamic>),
      DepReport.fromJson(json['report'] as Map<String, dynamic>),
    );
  }

  Future<DepReport?> report(String projectId) async {
    final res = await _client.get(Uri.parse('$baseUrl/projects/$projectId'));
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final report = json['report'];
    return report == null
        ? null
        : DepReport.fromJson(report as Map<String, dynamic>);
  }

  Future<ResolutionResult> simulate(
    String projectId,
    ResolutionRequest request,
  ) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/projects/$projectId/resolve'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(request.toJson()),
    );
    return ResolutionResult.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
