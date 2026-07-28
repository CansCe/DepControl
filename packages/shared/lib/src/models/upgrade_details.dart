import 'api_diff.dart';
import 'upgrade_impact.dart';

/// Everything the API can say about moving one dependency to a newer version.
///
/// Two findings from two sources, deliberately kept apart. [impact] is derived
/// from published metadata and computed per request. [apiDiff] compares the
/// packages' own sources and is computed out of process, so it is only present
/// once something has actually done that work.
///
/// A null [apiDiff] therefore means "not computed", never "the API did not
/// change" — the difference matters enough that callers should say so rather
/// than render an empty list.
class UpgradeDetails {
  const UpgradeDetails({this.impact, this.apiDiff, this.reason});

  final UpgradeImpact? impact;
  final ApiDiff? apiDiff;

  /// Why there is nothing to report, when there is nothing to report.
  final String? reason;

  factory UpgradeDetails.fromJson(Map<String, dynamic> json) => UpgradeDetails(
        impact: switch (json['impact']) {
          final Map<String, dynamic> impact => UpgradeImpact.fromJson(impact),
          _ => null,
        },
        apiDiff: switch (json['apiDiff']) {
          final Map<String, dynamic> diff => ApiDiff.fromJson(diff),
          _ => null,
        },
        reason: json['reason'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'impact': impact?.toJson(),
        'apiDiff': apiDiff?.toJson(),
        if (reason != null) 'reason': reason,
      };
}
