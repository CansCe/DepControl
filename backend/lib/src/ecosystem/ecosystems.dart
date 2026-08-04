import 'package:ecosystem/ecosystem.dart';

import '../services/pub_api_client.dart';
import 'dart/dart_registry.dart';
import 'npm/npm_registry.dart';
import 'osv_client.dart';
import 'package_registry.dart';

// Parsing comes from `package:ecosystem`, which the local collector reads the
// same way; registry access is the server's alone. Re-exported together because
// nearly everything in `backend/` that holds an ecosystem also looks something
// up in its registry, and making those files import from two places to get one
// concept back would advertise a seam they have no stake in.
export 'package:ecosystem/ecosystem.dart';

export 'dart/dart_registry.dart';
export 'npm/npm_registry.dart';
export 'osv_client.dart';
export 'package_registry.dart';

/// Every ecosystem this server can scan, and where each one's packages are
/// looked up.
///
/// Built once and shared, because each registry holds a client with its own
/// connection pool. Nothing here is per-request or per-user.
///
/// The two halves are held side by side rather than as one object because they
/// no longer live in one place: an [Ecosystem] is manifest parsing and nothing
/// else, and ships in `package:ecosystem`; a [PackageRegistry] speaks a network
/// protocol and stays here. This class is the join, and [Ecosystem.id] is the
/// key — the same string already stored on every node of every report, so a
/// registry can still be found for a report read back out of the database.
class Ecosystems {
  Ecosystems(
    List<Ecosystem> ecosystems, {
    Map<String, PackageRegistry> registries = const {},
  })  : all = List.unmodifiable(ecosystems),
        _byId = {for (final e in ecosystems) e.id: e},
        _registries = Map.unmodifiable(registries);

  /// The production set.
  ///
  /// Dart leads, so it stays the ecosystem the single-manifest endpoints
  /// default to. Order is otherwise only a tie-break in repository discovery.
  factory Ecosystems.standard({
    PubApiClient? pub,
    NpmRegistry? npm,
    OsvClient? osv,
  }) =>
      Ecosystems(
        const [DartEcosystem(), NpmEcosystem()],
        registries: {
          'dart': DartRegistry(pub ?? PubApiClient(), osv: osv ?? OsvClient()),
          'npm': npm ?? NpmRegistry(),
        },
      );

  /// Dart alone, for the tests and callers that are asserting about pub.dev
  /// and would otherwise have npm's discovery running alongside.
  factory Ecosystems.dartOnly({PubApiClient? pub, OsvClient? osv}) =>
      Ecosystems(
        const [DartEcosystem()],
        registries: {
          'dart': DartRegistry(pub ?? PubApiClient(), osv: osv ?? OsvClient()),
        },
      );

  final List<Ecosystem> all;
  final Map<String, Ecosystem> _byId;

  /// One registry per ecosystem id. Empty is legitimate: repository discovery
  /// and the parse-only paths need the naming and the parsers, and building
  /// registry clients for them would open connection pools nobody uses.
  final Map<String, PackageRegistry> _registries;

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

  /// Where [id]'s published packages are looked up, or throws when this build
  /// has no registry for it.
  ///
  /// Throws for the same reason [require] does — a lookup with no registry
  /// behind it cannot report a version, a licence or an advisory, and a report
  /// that silently omits all three is worse than one that fails.
  PackageRegistry registryFor(String id) {
    final found = _registries[id];
    if (found == null) {
      throw StateError(
        'No registry is configured for ecosystem "$id"; this server can look '
        'up ${_registries.keys.join(', ')}.',
      );
    }
    return found;
  }
}
