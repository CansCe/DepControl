import 'package:shared/shared.dart';
import 'package:test/test.dart';

ScanProgress _progress({ScanPhase phase = ScanPhase.analyzing}) {
  final started = DateTime.utc(2026, 8, 4, 10);
  return ScanProgress(
    phase: phase,
    startedAt: started,
    phaseStartedAt: started,
    analysisStartedAt: started,
    packagesDone: 20,
    packagesTotal: 100,
    manifestsSeen: 1,
    manifestsTotal: 1,
  );
}

void main() {
  group('ScanStatus', () {
    test('round-trips through JSON', () {
      final status = ScanStatus(
        scanId: 'scan-1',
        state: ScanJobState.running,
        progress: _progress(),
        projectId: 'p1',
      );

      final decoded = ScanStatus.fromJson(status.toJson());

      expect(decoded.scanId, 'scan-1');
      expect(decoded.state, ScanJobState.running);
      expect(decoded.projectId, 'p1');
      expect(decoded.progress.packagesDone, 20);
      expect(decoded.progress.phase, ScanPhase.analyzing);
      expect(decoded.isFinished, isFalse);
    });

    test('reads the older bare-progress shape', () {
      // What this route answered with before scans became jobs: a ScanProgress
      // and nothing around it. A client updated ahead of the server has to keep
      // showing a bar rather than reading it as a scan that never started.
      final decoded = ScanStatus.fromJson(_progress().toJson());

      expect(decoded.progress.packagesDone, 20);
      expect(decoded.progress.phase, ScanPhase.analyzing);
      expect(decoded.state, ScanJobState.queued);
      expect(decoded.projectId, isNull);
    });

    test('an unknown state reads as queued rather than throwing', () {
      expect(ScanJobState.parse('something-newer'), ScanJobState.queued);
      expect(ScanJobState.parse(null), ScanJobState.queued);
    });

    test('carries a failure the scan itself never got to report', () {
      // A job abandoned by a machine that died before writing a phase: the
      // progress still says `queued`, and the error is the only thing that
      // knows otherwise.
      final status = ScanStatus(
        scanId: 'scan-1',
        state: ScanJobState.failed,
        progress: _progress(phase: ScanPhase.queued),
        error: 'gave up after 3 attempts',
      );

      final decoded = ScanStatus.fromJson(status.toJson());

      expect(decoded.isFinished, isTrue);
      expect(decoded.error, 'gave up after 3 attempts');
      expect(decoded.progress.error, isNull);
    });
  });
}
