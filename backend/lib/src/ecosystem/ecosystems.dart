import '../services/pub_api_client.dart';
import 'dart_ecosystem.dart';
import 'ecosystem.dart';

export 'dart_ecosystem.dart';
export 'ecosystem.dart';

/// Every ecosystem this server can scan.
///
/// Built once and shared, because each carries a registry client with its own
/// connection pool. Nothing here is per-request or per-user.
class Ecosystems {
  Ecosystems(List<Ecosystem> ecosystems)
      : all = List.unmodifiable(ecosystems),
        _byId = {for (final e in ecosystems) e.id: e};

  /// The production set.
  factory Ecosystems.standard({PubApiClient? pub}) => Ecosystems([
        DartEcosystem(pub ?? PubApiClient()),
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
