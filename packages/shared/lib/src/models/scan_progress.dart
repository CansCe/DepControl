/// What a scan is doing right now.
///
/// Ordered by when it happens, so a client can tell "further along" from
/// "different" without a lookup table.
enum ScanPhase {
  /// Accepted, nothing started yet.
  queued,

  /// Cloning the repository and finding its manifests. Duration is dominated by
  /// the network and the size of the repository, and nothing about it can be
  /// counted — there is no denominator until the manifests are read.
  fetching,

  /// No lockfile, so what an install *would* pick is being worked out by
  /// resolving the declared constraints against the registry.
  resolving,

  /// Asking the registry about each package: latest version, advisories,
  /// license, edges. This is where nearly all of the time goes on a large
  /// repository, and it is the only phase with a real denominator.
  analyzing,

  /// Writing the report.
  saving,

  done,
  failed;

  static ScanPhase parse(String? raw) => ScanPhase.values.firstWhere(
        (p) => p.name == raw,
        orElse: () => ScanPhase.queued,
      );
}

/// How far a scan has got, as the server sees it.
///
/// Deliberately reports counts rather than a percentage. A percentage would
/// have to be invented during [ScanPhase.fetching], where there is nothing to
/// count, and it would hide the fact that the denominator itself grows as more
/// manifests are read. Callers that want a bar can derive one; callers that
/// want to say "412 of 1444 packages" can do that instead.
class ScanProgress {
  const ScanProgress({
    required this.phase,
    required this.startedAt,
    required this.phaseStartedAt,
    this.analysisStartedAt,
    this.packagesDone = 0,
    this.packagesTotal = 0,
    this.manifestsSeen = 0,
    this.manifestsTotal = 0,
    this.error,
  });

  final ScanPhase phase;

  /// When the scan began, and when the current phase did.
  ///
  /// Both, because a rate worked out over the whole scan is wrong: the clone
  /// happens once and says nothing about how fast the registry is answering.
  final DateTime startedAt;
  final DateTime phaseStartedAt;

  /// When registry work first started, and never reset after that.
  ///
  /// Separate from [phaseStartedAt] because a monorepo alternates between
  /// resolving and analyzing once per manifest. Timing the rate from the
  /// current phase would restart the clock a dozen times while [packagesDone]
  /// kept climbing, and the estimate would fall through the floor. Everything
  /// since the first manifest began is registry work, so all of it counts.
  final DateTime? analysisStartedAt;

  /// Packages examined, and how many are known to need examining.
  ///
  /// [packagesTotal] grows: a monorepo's manifests are analyzed one after
  /// another, and each contributes its own set. It is a running total of what
  /// has been discovered, not a promise about the end.
  final int packagesDone;
  final int packagesTotal;

  /// Manifests started, out of how many the repository holds.
  ///
  /// This is what makes [packagesTotal] extrapolatable — halfway through the
  /// second of twelve pubspecs, the packages seen so far are roughly a sixth of
  /// the eventual set.
  final int manifestsSeen;
  final int manifestsTotal;

  /// Why the scan stopped, when it did.
  final String? error;

  bool get isFinished => phase == ScanPhase.done || phase == ScanPhase.failed;

  /// How complete the scan is, or null when nothing countable has started.
  ///
  /// Null is a real answer and callers must render it as such — an
  /// indeterminate bar — rather than falling back to zero, which claims no
  /// progress when the truth is that progress is not yet measurable.
  double? get fraction {
    if (phase == ScanPhase.done) return 1;
    final total = projectedPackages;
    if (total == null || total == 0) return null;
    final value = packagesDone / total;
    return value.clamp(0.0, 1.0);
  }

  /// How many packages this scan will examine in total, as best we can tell.
  ///
  /// With one manifest that is [packagesTotal] exactly. With several, the ones
  /// not yet read are assumed to be about the size of the ones already read —
  /// an assumption, and the reason everything derived from this is presented as
  /// approximate.
  int? get projectedPackages {
    if (packagesTotal == 0) return null;
    if (manifestsTotal <= 1 || manifestsSeen <= 0) return packagesTotal;
    if (manifestsSeen >= manifestsTotal) return packagesTotal;
    return (packagesTotal * manifestsTotal / manifestsSeen).round();
  }

  /// How much longer the scan is likely to take, or null when there is not
  /// enough evidence to say.
  ///
  /// Measured, not guessed: the rate is what this scan has actually achieved
  /// since the analyzing phase began, against this registry, on this
  /// connection. It withholds an answer until a handful of packages have gone
  /// through, because a rate taken from two samples swings wildly and a number
  /// that jumps from "4 minutes" to "20 seconds" is worse than no number.
  Duration? estimatedRemaining({DateTime? now}) {
    if (isFinished) return Duration.zero;

    final since = analysisStartedAt;
    if (since == null) return null;

    final total = projectedPackages;
    if (total == null || packagesDone < _minimumSamples) return null;

    final elapsed =
        (now ?? DateTime.now().toUtc()).toUtc().difference(since.toUtc());
    if (elapsed <= Duration.zero) return null;

    final remaining = total - packagesDone;
    if (remaining <= 0) return Duration.zero;

    final perPackage = elapsed.inMilliseconds / packagesDone;
    return Duration(milliseconds: (remaining * perPackage).round());
  }

  /// Below this the measured rate is noise rather than a trend.
  static const _minimumSamples = 8;

  ScanProgress copyWith({
    ScanPhase? phase,
    DateTime? phaseStartedAt,
    DateTime? analysisStartedAt,
    int? packagesDone,
    int? packagesTotal,
    int? manifestsSeen,
    int? manifestsTotal,
    String? error,
  }) =>
      ScanProgress(
        phase: phase ?? this.phase,
        startedAt: startedAt,
        phaseStartedAt: phaseStartedAt ?? this.phaseStartedAt,
        analysisStartedAt: analysisStartedAt ?? this.analysisStartedAt,
        packagesDone: packagesDone ?? this.packagesDone,
        packagesTotal: packagesTotal ?? this.packagesTotal,
        manifestsSeen: manifestsSeen ?? this.manifestsSeen,
        manifestsTotal: manifestsTotal ?? this.manifestsTotal,
        error: error ?? this.error,
      );

  Map<String, dynamic> toJson() => {
        'phase': phase.name,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'phaseStartedAt': phaseStartedAt.toUtc().toIso8601String(),
        if (analysisStartedAt != null)
          'analysisStartedAt': analysisStartedAt!.toUtc().toIso8601String(),
        'packagesDone': packagesDone,
        'packagesTotal': packagesTotal,
        'manifestsSeen': manifestsSeen,
        'manifestsTotal': manifestsTotal,
        if (error != null) 'error': error,
      };

  factory ScanProgress.fromJson(Map<String, dynamic> json) {
    final started = _time(json['startedAt']) ?? DateTime.now().toUtc();
    return ScanProgress(
      phase: ScanPhase.parse(json['phase'] as String?),
      startedAt: started,
      phaseStartedAt: _time(json['phaseStartedAt']) ?? started,
      analysisStartedAt: _time(json['analysisStartedAt']),
      packagesDone: (json['packagesDone'] as num?)?.toInt() ?? 0,
      packagesTotal: (json['packagesTotal'] as num?)?.toInt() ?? 0,
      manifestsSeen: (json['manifestsSeen'] as num?)?.toInt() ?? 0,
      manifestsTotal: (json['manifestsTotal'] as num?)?.toInt() ?? 0,
      error: json['error'] as String?,
    );
  }

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
}
