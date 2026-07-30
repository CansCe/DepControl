import '../deps.dart';
import 'scan_progress_store.dart';

/// How long a client-supplied scan id may be.
///
/// The id is a map key chosen by the caller, so it is bounded for the same
/// reason [ScanProgressStore.capacity] exists: nothing an untrusted caller
/// controls gets to be arbitrarily large.
const int kMaxScanIdLength = 64;

/// The sink a scan should report to, given whatever the caller sent as its
/// scan id.
///
/// Returns [ScanProgressSink.none] for anything that is not a usable id —
/// absent, empty, the wrong type, or too long. Progress is a convenience for a
/// client watching its own request; refusing the whole scan because the id was
/// malformed would break callers that never asked to be watched.
ScanProgressSink scanSinkFor(Deps deps, Object? rawScanId) {
  final id = scanIdFrom(rawScanId);
  return id == null
      ? ScanProgressSink.none
      : deps.scanProgress.sinkFor(id);
}

/// Validates a client-supplied scan id, or null when it is not one.
String? scanIdFrom(Object? raw) {
  if (raw is! String) return null;
  final id = raw.trim();
  if (id.isEmpty || id.length > kMaxScanIdLength) return null;
  return id;
}
