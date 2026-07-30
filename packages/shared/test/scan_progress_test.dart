import 'package:shared/shared.dart';
import 'package:test/test.dart';

final _start = DateTime.utc(2026, 1, 1, 12);

ScanProgress _progress({
  ScanPhase phase = ScanPhase.analyzing,
  int done = 0,
  int total = 0,
  int manifestsSeen = 0,
  int manifestsTotal = 0,
  bool analysing = true,
}) =>
    ScanProgress(
      phase: phase,
      startedAt: _start,
      phaseStartedAt: _start,
      analysisStartedAt: analysing ? _start : null,
      packagesDone: done,
      packagesTotal: total,
      manifestsSeen: manifestsSeen,
      manifestsTotal: manifestsTotal,
    );

void main() {
  group('how complete a scan is', () {
    // The distinction the whole design rests on: "not measurable yet" is not
    // "zero". A caller must be able to tell them apart, because one means an
    // indeterminate bar and the other means a bar at the far left.
    test('is unknown before anything has been counted', () {
      expect(_progress(phase: ScanPhase.fetching).fraction, isNull);
    });

    test('is a real fraction once packages are counted', () {
      expect(_progress(done: 50, total: 200).fraction, 0.25);
    });

    test('is whole when the scan is done', () {
      expect(_progress(phase: ScanPhase.done).fraction, 1);
    });

    test('never exceeds whole', () {
      expect(_progress(done: 300, total: 200).fraction, 1.0);
    });
  });

  group('projecting the eventual package count', () {
    test('is what has been counted when there is one manifest', () {
      expect(
        _progress(total: 120, manifestsSeen: 1, manifestsTotal: 1)
            .projectedPackages,
        120,
      );
    });

    // GeoLibre's shape: twelve pubspecs, and the count so far covers two of
    // them. Reporting 240 as the total would put the bar at 50% when the real
    // answer is nearer 8%.
    test('extrapolates from the manifests read so far', () {
      expect(
        _progress(total: 240, manifestsSeen: 2, manifestsTotal: 12)
            .projectedPackages,
        1440,
      );
    });

    test('stops extrapolating once every manifest is in', () {
      expect(
        _progress(total: 1444, manifestsSeen: 12, manifestsTotal: 12)
            .projectedPackages,
        1444,
      );
    });

    test('is unknown before any manifest is read', () {
      expect(_progress().projectedPackages, isNull);
    });
  });

  group('estimating the time left', () {
    test('says nothing until the sample is worth trusting', () {
      final progress = _progress(done: 3, total: 100, manifestsTotal: 1);
      expect(
        progress.estimatedRemaining(now: _start.add(const Duration(seconds: 3))),
        isNull,
        reason: 'a rate from three packages swings wildly',
      );
    });

    test('extrapolates the measured rate', () {
      // 20 packages in 10s is 0.5s each; 80 left is 40s.
      final progress = _progress(
        done: 20,
        total: 100,
        manifestsSeen: 1,
        manifestsTotal: 1,
      );
      expect(
        progress.estimatedRemaining(
          now: _start.add(const Duration(seconds: 10)),
        ),
        const Duration(seconds: 40),
      );
    });

    test('counts the manifests not yet read', () {
      // Same rate, but only half the repository has been discovered, so there
      // is twice as much left as the counted total implies.
      final progress = _progress(
        done: 20,
        total: 100,
        manifestsSeen: 1,
        manifestsTotal: 2,
      );
      expect(
        progress.estimatedRemaining(
          now: _start.add(const Duration(seconds: 10)),
        ),
        const Duration(seconds: 90),
      );
    });

    test('says nothing while the repository is still being fetched', () {
      final progress = _progress(phase: ScanPhase.fetching, analysing: false);
      expect(
        progress.estimatedRemaining(
          now: _start.add(const Duration(seconds: 30)),
        ),
        isNull,
      );
    });

    test('is zero once the scan is over', () {
      expect(
        _progress(phase: ScanPhase.done).estimatedRemaining(now: _start),
        Duration.zero,
      );
    });

    // A monorepo alternates resolving and analyzing per manifest. Timing the
    // rate from the current phase would restart the clock each time and the
    // estimate would collapse.
    test('survives a phase change mid-scan', () {
      final progress = ScanProgress(
        phase: ScanPhase.resolving,
        startedAt: _start,
        phaseStartedAt: _start.add(const Duration(seconds: 9)),
        analysisStartedAt: _start,
        packagesDone: 20,
        packagesTotal: 100,
        manifestsSeen: 1,
        manifestsTotal: 1,
      );
      expect(
        progress.estimatedRemaining(
          now: _start.add(const Duration(seconds: 10)),
        ),
        const Duration(seconds: 40),
      );
    });
  });

  test('round-trips through json', () {
    final progress = ScanProgress(
      phase: ScanPhase.analyzing,
      startedAt: _start,
      phaseStartedAt: _start.add(const Duration(seconds: 2)),
      analysisStartedAt: _start.add(const Duration(seconds: 2)),
      packagesDone: 7,
      packagesTotal: 30,
      manifestsSeen: 1,
      manifestsTotal: 3,
      error: null,
    );

    final back = ScanProgress.fromJson(progress.toJson());

    expect(back.phase, progress.phase);
    expect(back.startedAt, progress.startedAt);
    expect(back.analysisStartedAt, progress.analysisStartedAt);
    expect(back.packagesDone, 7);
    expect(back.packagesTotal, 30);
    expect(back.manifestsSeen, 1);
    expect(back.manifestsTotal, 3);
  });

  test('an unrecognised phase reads as queued rather than throwing', () {
    expect(ScanPhase.parse('something-new'), ScanPhase.queued);
    expect(ScanPhase.parse(null), ScanPhase.queued);
  });
}
