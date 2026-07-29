import '../services/pub_api_client.dart';
import 'dart_ecosystem.dart';
import 'ecosystem.dart';
import 'npm/npm_ecosystem.dart';
import 'osv_client.dart';
import 'npm/npm_registry.dart';

export 'dart_ecosystem.dart';
export 'ecosystem.dart';
export 'npm/npm_ecosystem.dart';
export 'osv_client.dart';
export 'npm/npm_registry.dart';

/// Every ecosystem this server can scan.
///
/// Built once and shared, because each carries a registry client with its own
/// connection pool. Nothing here is per-request or per-user.
class Ecosystems {
  Ecosystems(List<Ecosystem> ecosystems)
      : all = List.unmodifiable(ecosystems),
        _byId = {for (final e in ecosystems) e.id: e};

  /// The production set.
  ///
  /// Dart leads, so it stays the ecosystem the single-manifest endpoints
  /// default to. Order is otherwise only a tie-break in repository discovery.
  factory Ecosystems.standard({
    PubApiClient? pub,
    NpmRegistry? npm,
    OsvClient? osv,
  }) =>
      Ecosystems([
        DartEcosystem(pub ?? PubApiClient(), osv: osv),
        NpmEcosystem(registry: npm),
      ]);

  /// Dart alone, for the tests and callers that are asserting about pub.dev
  /// and would otherwise have npm's discovery running alongside.
  factory Ecosystems.dartOnly({PubApiClient? pub, OsvClient? osv}) =>
      Ecosystems([
        DartEcosystem(pub ?? PubApiClient(), osv: osv),
      ]);

  final List<Ecosystem> all;
  final Map<String, Ecosystem> _byId;

  /// The manifest names to look for when walking a repository.
  List<ManifestNaming> get naming => [for (final e in all) e.naming];

  /// The ecosystem [id] names, or null for one this build does not have.
  ///
  /// Null is reachable from stored data: a report written when npm scanning was
  /// enabled still names npm after it is switched off. Callers serve what was
  /// stored rather than pretending the rows are Dart.
  Ecosystem? byId(String id) => _byId[id];

  /// The ecosystem [id] names, or throws when this build does not have it.
  /// For the analysis path, where there is no sensible way to continue.
  Ecosystem require(String id) {
    final found = _byId[id];
    if (found == null) {
      throw StateError(
        'No ecosystem "$id" is configured; this server scans '
        '${all.map((e) => e.id).join(', ')}.',
      );
    }
    return found;
  }
}
