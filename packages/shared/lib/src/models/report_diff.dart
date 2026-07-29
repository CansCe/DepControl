import 'package:pub_semver/pub_semver.dart';

import 'dep_advisory.dart';
import 'dep_node.dart';
import 'dep_report.dart';

/// What happened to one package between two reports.
enum ChangeKind {
  /// The project did not resolve this package before and does now.
  added,

  /// It did and does not any more.
  removed,

  /// It resolves in both, at a different version or with something else about
  /// it changed.
  changed,
}

/// How far a version moved, in the vocabulary [UpgradeRisk] already uses.
///
/// `breaking` rather than `major`, because the major component is not the only
/// thing that carries a breaking change and saying "major" would be a claim
/// about which digit moved.
enum VersionBump {
  /// The author declares this as breaking — a major bump, or the pre-1.0
  /// equivalent.
  breaking,

  /// Backwards-compatible additions.
  minor,

  /// Bug fixes.
  patch,

  /// The versions are equal.
  none,

  /// At least one side is not a version this can read — `(unresolved)`, or a
  /// scheme that is not semver.
  incomparable,
}

/// One package's story between two reports.
class PackageChange {
  const PackageChange({
    required this.name,
    required this.ecosystem,
    required this.kind,
    this.fromVersion,
    this.toVersion,
    this.bump = VersionBump.none,
    this.isDowngrade = false,
    this.newAdvisories = const [],
    this.clearedAdvisories = const [],
    this.fromLicense,
    this.toLicense,
    this.fromKind,
    this.toKind,
  });

  final String name;
  final String ecosystem;
  final ChangeKind kind;

  /// Null when the package was [ChangeKind.added].
  final String? fromVersion;

  /// Null when the package was [ChangeKind.removed].
  final String? toVersion;

  final VersionBump bump;

  /// Whether the version went backwards. Kept separate from [bump] because a
  /// downgrade across a major boundary is as breaking as the upgrade was, and
  /// folding direction into the magnitude would hide one of them.
  final bool isDowngrade;

  /// Advisories that apply now and did not before.
  ///
  /// Three ways that happens, and they are not distinguished here because the
  /// report cannot tell them apart: the advisory was newly published, the
  /// package moved into an affected range, or the package is new and arrived
  /// carrying it. All three are the same news to whoever is on call.
  final List<DepAdvisory> newAdvisories;

  /// Advisories that applied before and do not now.
  ///
  /// Deliberately not called "fixed". An advisory clears because the package
  /// moved to a fixed version, because the package left the project entirely,
  /// or because the advisory was **withdrawn** by its database — and a
  /// withdrawal means the finding was never right rather than that anybody
  /// repaired anything. Nothing in two reports can tell those apart, so the
  /// name does not claim to.
  final List<DepAdvisory> clearedAdvisories;

  /// SPDX ids before and after, where either was determined.
  ///
  /// A relicensing on an unchanged version is one of the two things a re-scan
  /// of an untouched project exists to find; the other is a new advisory.
  final String? fromLicense;
  final String? toLicense;

  final DepKind? fromKind;
  final DepKind? toKind;

  /// Whether the version moved at all.
  bool get versionMoved =>
      fromVersion != null && toVersion != null && fromVersion != toVersion;

  /// Whether this is a breaking move in either direction.
  bool get isBreaking => bump == VersionBump.breaking;

  /// Whether the package changed how it is reached — a direct dependency
  /// becoming transitive, or the reverse.
  bool get kindMoved => fromKind != null && toKind != null && fromKind != toKind;

  /// Whether the license changed on a package that stayed put.
  bool get relicensed =>
      !versionMoved && fromLicense != toLicense && kind == ChangeKind.changed;

  /// The worst severity among [newAdvisories], or null when there are none.
  AdvisorySeverity? get worstNewSeverity {
    if (newAdvisories.isEmpty) return null;
    return newAdvisories
        .map((a) => a.severity)
        .reduce((a, b) => a.index < b.index ? a : b);
  }

  /// `name` for a single-ecosystem project, `name (npm)` where it could be
  /// either. The caller decides which by passing [qualify].
  String label({bool qualify = false}) =>
      qualify ? '$name ($ecosystem)' : name;

  factory PackageChange.fromJson(Map<String, dynamic> json) => PackageChange(
        name: json['name'] as String,
        ecosystem: (json['ecosystem'] as String?) ?? DepNode.defaultEcosystem,
        kind: ChangeKind.values.byName(json['kind'] as String),
        fromVersion: json['fromVersion'] as String?,
        toVersion: json['toVersion'] as String?,
        bump: VersionBump.values.byName(
          (json['bump'] as String?) ?? 'none',
        ),
        isDowngrade: (json['isDowngrade'] as bool?) ?? false,
        newAdvisories: _advisories(json['newAdvisories']),
        clearedAdvisories: _advisories(json['clearedAdvisories']),
        fromLicense: json['fromLicense'] as String?,
        toLicense: json['toLicense'] as String?,
        fromKind: _depKind(json['fromKind']),
        toKind: _depKind(json['toKind']),
      );

  static List<DepAdvisory> _advisories(Object? raw) => [
        for (final entry in (raw as List?) ?? const [])
          DepAdvisory.fromJson((entry as Map).cast<String, dynamic>()),
      ];

  static DepKind? _depKind(Object? raw) =>
      raw is String ? DepKind.values.byName(raw) : null;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (ecosystem != DepNode.defaultEcosystem) 'ecosystem': ecosystem,
        'kind': kind.name,
        if (fromVersion != null) 'fromVersion': fromVersion,
        if (toVersion != null) 'toVersion': toVersion,
        'bump': bump.name,
        if (isDowngrade) 'isDowngrade': true,
        if (newAdvisories.isNotEmpty)
          'newAdvisories': [for (final a in newAdvisories) a.toJson()],
        if (clearedAdvisories.isNotEmpty)
          'clearedAdvisories': [for (final a in clearedAdvisories) a.toJson()],
        if (fromLicense != null) 'fromLicense': fromLicense,
        if (toLicense != null) 'toLicense': toLicense,
        if (fromKind != null) 'fromKind': fromKind!.name,
        if (toKind != null) 'toKind': toKind!.name,
      };
}

/// What changed between two dependency reports.
///
/// A pure comparison: no I/O, no clock, nothing but the two documents. That is
/// deliberate — this is what a notification is built from and what a history
/// screen renders, and both need to be able to re-derive the same answer from
/// stored reports months later.
class ReportDiff {
  const ReportDiff({
    required this.projectId,
    required this.packages,
    this.fromGeneratedAt,
    this.toGeneratedAt,
  });

  /// Compares [from] (the older report) with [to].
  ///
  /// Packages are matched on **ecosystem and name**, not on
  /// [DepNode.key] — the version is the thing being compared, so it cannot also
  /// be part of the identity. The ecosystem is, because npm and pub.dev both
  /// publish `path`, `http` and `crypto` and they are unrelated software.
  ///
  /// A repository can resolve one package at two versions at once, which this
  /// project's own does. Where that happens there is no single "it moved from
  /// here to there" to report, so the differing versions are listed as
  /// additions and removals instead of an invented bump.
  factory ReportDiff.between(DepReport from, DepReport to) {
    final before = _byPackage(from.nodes);
    final after = _byPackage(to.nodes);

    final changes = <PackageChange>[];

    for (final key in {...before.keys, ...after.keys}) {
      final was = before[key] ?? const <DepNode>[];
      final now = after[key] ?? const <DepNode>[];

      if (was.length == 1 && now.length == 1) {
        final change = _compare(was.single, now.single);
        if (change != null) changes.add(change);
        continue;
      }

      // More than one version on a side: report the version-level difference
      // rather than pretending there was a single move.
      final wasVersions = {for (final n in was) n.installed: n};
      final nowVersions = {for (final n in now) n.installed: n};

      for (final entry in nowVersions.entries) {
        if (wasVersions.containsKey(entry.key)) continue;
        changes.add(_added(entry.value));
      }
      for (final entry in wasVersions.entries) {
        if (nowVersions.containsKey(entry.key)) continue;
        changes.add(_removed(entry.value));
      }
    }

    changes.sort(_bySeverityThenName);

    return ReportDiff(
      projectId: to.projectId,
      fromGeneratedAt: from.generatedAt,
      toGeneratedAt: to.generatedAt,
      packages: List.unmodifiable(changes),
    );
  }

  final String projectId;
  final DateTime? fromGeneratedAt;
  final DateTime? toGeneratedAt;

  /// Every package that changed, worst first — new advisories lead, then
  /// breaking moves, then the rest by name. A reader deals with the top of the
  /// list and runs out of time somewhere further down.
  final List<PackageChange> packages;

  bool get isEmpty => packages.isEmpty;
  bool get isNotEmpty => packages.isNotEmpty;

  Iterable<PackageChange> get added =>
      packages.where((p) => p.kind == ChangeKind.added);

  Iterable<PackageChange> get removed =>
      packages.where((p) => p.kind == ChangeKind.removed);

  /// Packages whose version moved, in either direction.
  Iterable<PackageChange> get moved => packages.where((p) => p.versionMoved);

  /// Moves the publisher declares as breaking. The notification rule "tell me
  /// about major version bumps" is this.
  Iterable<PackageChange> get breakingMoves =>
      moved.where((p) => p.isBreaking);

  /// Packages carrying an advisory that did not apply before. The notification
  /// rule "tell me about new vulnerabilities" is this.
  Iterable<PackageChange> get newlyVulnerable =>
      packages.where((p) => p.newAdvisories.isNotEmpty);

  bool get hasNewVulnerabilities => newlyVulnerable.isNotEmpty;

  /// The worst severity newly appearing anywhere, or null when nothing did.
  ///
  /// What a severity threshold is compared against: "notify me at high and
  /// above" is a question about the worst thing in the diff.
  AdvisorySeverity? get worstNewSeverity {
    final severities = [
      for (final change in packages)
        if (change.worstNewSeverity case final s?) s,
    ];
    if (severities.isEmpty) return null;
    return severities.reduce((a, b) => a.index < b.index ? a : b);
  }

  /// Every advisory that newly applies, paired with the package carrying it.
  List<({PackageChange package, DepAdvisory advisory})> get newAdvisories => [
        for (final change in packages)
          for (final advisory in change.newAdvisories)
            (package: change, advisory: advisory),
      ];

  /// Packages relicensed without moving version.
  Iterable<PackageChange> get relicensed => packages.where((p) => p.relicensed);

  /// ecosystem:name -> the nodes under it, since a repository can resolve one
  /// package at more than one version.
  static Map<String, List<DepNode>> _byPackage(List<DepNode> nodes) {
    final out = <String, List<DepNode>>{};
    for (final node in nodes) {
      (out['${node.ecosystem}:${node.name}'] ??= <DepNode>[]).add(node);
    }
    return out;
  }

  /// The change between two resolutions of one package, or null when nothing
  /// worth reporting moved.
  static PackageChange? _compare(DepNode before, DepNode after) {
    final newAdvisories = _advisoriesNotIn(after.advisories, before.advisories);
    final cleared = _advisoriesNotIn(before.advisories, after.advisories);

    final fromLicense = before.license?.spdxId;
    final toLicense = after.license?.spdxId;

    final versionMoved = before.installed != after.installed;
    final licenseMoved = fromLicense != toLicense;
    final kindMoved = before.kind != after.kind;

    if (!versionMoved &&
        !licenseMoved &&
        !kindMoved &&
        newAdvisories.isEmpty &&
        cleared.isEmpty) {
      return null;
    }

    final move = _classify(before.installed, after.installed, after.ecosystem);

    return PackageChange(
      name: after.name,
      ecosystem: after.ecosystem,
      kind: ChangeKind.changed,
      fromVersion: before.installed,
      toVersion: after.installed,
      bump: move.bump,
      isDowngrade: move.isDowngrade,
      newAdvisories: newAdvisories,
      clearedAdvisories: cleared,
      fromLicense: fromLicense,
      toLicense: toLicense,
      fromKind: before.kind,
      toKind: after.kind,
    );
  }

  static PackageChange _added(DepNode node) => PackageChange(
        name: node.name,
        ecosystem: node.ecosystem,
        kind: ChangeKind.added,
        toVersion: node.installed,
        // A new package arrives carrying whatever advisories apply to it, and
        // those are as new to this project as a freshly published one.
        newAdvisories: node.advisories,
        toLicense: node.license?.spdxId,
        toKind: node.kind,
      );

  static PackageChange _removed(DepNode node) => PackageChange(
        name: node.name,
        ecosystem: node.ecosystem,
        kind: ChangeKind.removed,
        fromVersion: node.installed,
        clearedAdvisories: node.advisories,
        fromLicense: node.license?.spdxId,
        fromKind: node.kind,
      );

  static List<DepAdvisory> _advisoriesNotIn(
    List<DepAdvisory> candidates,
    List<DepAdvisory> reference,
  ) {
    final known = {for (final a in reference) a.id};
    return [
      for (final advisory in candidates)
        if (!known.contains(advisory.id)) advisory,
    ];
  }

  /// How a version moved, and which way.
  ///
  /// The pre-1.0 rules are the ecosystems' own and they are not the same one.
  /// Both treat a minor change below 1.0.0 as breaking. npm goes further: at
  /// `0.0.x` the *patch* carries the breaking change, which is why `^0.0.3`
  /// admits nothing but `0.0.3` there while pub reads the same text as
  /// `>=0.0.3 <0.1.0`. Classifying an npm `0.0.3 -> 0.0.4` as a bug-fix bump
  /// would tell somebody a breaking change was routine.
  static ({VersionBump bump, bool isDowngrade}) _classify(
    String fromText,
    String toText,
    String ecosystem,
  ) {
    final from = _tryParse(fromText);
    final to = _tryParse(toText);

    if (from == null || to == null) {
      return (bump: VersionBump.incomparable, isDowngrade: false);
    }
    if (from == to) return (bump: VersionBump.none, isDowngrade: false);

    final isDowngrade = to < from;
    final lower = isDowngrade ? to : from;
    final higher = isDowngrade ? from : to;

    final VersionBump bump;
    if (lower.major != higher.major) {
      bump = VersionBump.breaking;
    } else if (lower.major == 0) {
      if (lower.minor != higher.minor) {
        bump = VersionBump.breaking;
      } else if (ecosystem == 'npm' && lower.minor == 0) {
        bump = VersionBump.breaking;
      } else {
        bump = VersionBump.patch;
      }
    } else if (lower.minor != higher.minor) {
      bump = VersionBump.minor;
    } else {
      bump = VersionBump.patch;
    }

    return (bump: bump, isDowngrade: isDowngrade);
  }

  /// New advisories first, worst band leading; then breaking moves; then the
  /// rest alphabetically. Ordering is most of the value of a list somebody
  /// reads under time pressure.
  static int _bySeverityThenName(PackageChange a, PackageChange b) {
    final aSeverity = a.worstNewSeverity;
    final bSeverity = b.worstNewSeverity;

    if (aSeverity != null || bSeverity != null) {
      if (aSeverity == null) return 1;
      if (bSeverity == null) return -1;
      final bySeverity = aSeverity.index.compareTo(bSeverity.index);
      if (bySeverity != 0) return bySeverity;
    }

    if (a.isBreaking != b.isBreaking) return a.isBreaking ? -1 : 1;

    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.ecosystem.compareTo(b.ecosystem);
  }

  static Version? _tryParse(String raw) {
    try {
      return Version.parse(raw);
    } on FormatException {
      return null;
    }
  }

  factory ReportDiff.fromJson(Map<String, dynamic> json) => ReportDiff(
        projectId: json['projectId'] as String,
        fromGeneratedAt: _date(json['fromGeneratedAt']),
        toGeneratedAt: _date(json['toGeneratedAt']),
        packages: [
          for (final entry in (json['packages'] as List?) ?? const [])
            PackageChange.fromJson((entry as Map).cast<String, dynamic>()),
        ],
      );

  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;

  Map<String, dynamic> toJson() => {
        'projectId': projectId,
        if (fromGeneratedAt != null)
          'fromGeneratedAt': fromGeneratedAt!.toIso8601String(),
        if (toGeneratedAt != null)
          'toGeneratedAt': toGeneratedAt!.toIso8601String(),
        'packages': [for (final change in packages) change.toJson()],
        // A summary the caller would otherwise recompute, and which a
        // notification rule is written directly against.
        'summary': {
          'added': added.length,
          'removed': removed.length,
          'moved': moved.length,
          'breaking': breakingMoves.length,
          'newlyVulnerable': newlyVulnerable.length,
          if (worstNewSeverity != null)
            'worstNewSeverity': worstNewSeverity!.name,
        },
      };
}
