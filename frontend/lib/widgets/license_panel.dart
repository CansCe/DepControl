import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import '../theme.dart';
import 'chrome.dart';
import 'license_chip.dart';

/// What the loader hands back: the judged report, and whether the rules that
/// judged it were written by anyone here.
typedef LicenseReportResult = ({LicenseReport report, bool policyIsCustom});

/// Which dependency licenses this project ships, and what the company policy
/// says about them.
///
/// Loaded with the report rather than behind a button, unlike the remediation
/// panel. Remediation answers a question the reader arrived with; this one
/// answers a question they did not know to ask, and an AGPL dependency nobody
/// clicked to reveal has not been found.
///
/// Only the packages the policy will not clear on its own are listed. The full
/// inventory — including everything permissive — is what the CSV manifest is
/// for, because that is a document to file rather than a screen to read.
class LicensePanel extends StatefulWidget {
  const LicensePanel({
    required this.load,
    this.onLoadManifest,
    this.onSavePolicy,
    this.onResetPolicy,
    super.key,
  });

  final Future<LicenseReportResult> Function() load;

  /// Fetches the CSV manifest. Optional so the panel renders without a backend.
  final Future<String> Function()? onLoadManifest;

  /// Replaces the policy. Null hides the editor — an archived project's report
  /// can still be judged, but there is nothing project-specific to edit from
  /// there.
  final Future<void> Function(LicensePolicy policy)? onSavePolicy;

  /// Drops the policy back to the standard one.
  final Future<void> Function()? onResetPolicy;

  @override
  State<LicensePanel> createState() => _LicensePanelState();
}

class _LicensePanelState extends State<LicensePanel> {
  late Future<LicenseReportResult> _result;

  @override
  void initState() {
    super.initState();
    _result = _start();
  }

  /// A block body, not an arrow: an arrow would return the assigned Future out
  /// of the setState callback, which Flutter asserts against.
  void _reload() {
    final result = _start();
    setState(() {
      _result = result;
    });
  }

  /// Starts the load with an error handler already attached. The FutureBuilder
  /// does not subscribe until the next frame, and a failure landing before then
  /// would otherwise surface as an unhandled async error rather than as the
  /// line this widget wants to show.
  Future<LicenseReportResult> _start() {
    final result = widget.load();
    result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _showManifest() async {
    final messenger = ScaffoldMessenger.of(context);
    final String csv;
    try {
      csv = await widget.onLoadManifest!();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not build the manifest.')),
      );
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _ManifestDialog(csv: csv),
    );
  }

  Future<void> _editPolicy(LicenseReportResult current) async {
    final edit = await showDialog<_PolicyEdit>(
      context: context,
      builder: (_) => _PolicyDialog(
        policy: current.report.policy,
        isCustom: current.policyIsCustom,
        canReset: widget.onResetPolicy != null && current.policyIsCustom,
      ),
    );
    if (edit == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (edit) {
        // Dropping the policy is not the same as saving a copy of the standard
        // one: the account goes back to having no rules of its own, and the
        // report says so.
        case _ResetPolicy():
          await widget.onResetPolicy!();
        case _SavePolicy(:final policy):
          await widget.onSavePolicy!(policy);
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save the policy.')),
      );
      return;
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<LicenseReportResult>(
      future: _result,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        if (snap.hasError || snap.data == null) {
          // Secondary to the dependency report, so a failure here is a line
          // rather than an error screen — but it is a line, not a silence.
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                Icon(
                  Icons.policy_outlined,
                  size: 15,
                  color: theme.textTheme.bodySmall?.color,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Could not check dependency licenses.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(onPressed: _reload, child: const Text('Retry')),
              ],
            ),
          );
        }

        return _Card(
          result: snap.data!,
          onShowManifest: widget.onLoadManifest == null ? null : _showManifest,
          onEditPolicy: widget.onSavePolicy == null
              ? null
              : () => _editPolicy(snap.data!),
        );
      },
    );
  }
}

/// What the policy dialog came back with. Cancelling returns null instead.
sealed class _PolicyEdit {
  const _PolicyEdit();
}

class _SavePolicy extends _PolicyEdit {
  const _SavePolicy(this.policy);
  final LicensePolicy policy;
}

/// "Stop having a policy" — not the same as saving one that happens to match
/// the standard rules, because the report tells a reader which of the two they
/// are looking at.
class _ResetPolicy extends _PolicyEdit {
  const _ResetPolicy();
}

class _Card extends StatelessWidget {
  const _Card({
    required this.result,
    this.onShowManifest,
    this.onEditPolicy,
  });

  final LicenseReportResult result;
  final VoidCallback? onShowManifest;
  final VoidCallback? onEditPolicy;

  /// How many packages needing review to list before deferring to the manifest.
  static const _reviewShown = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = result.report;

    final forbidden = report.forbidden;
    final review = report.flagged
        .where((f) => f.rule == LicenseRule.review)
        .toList(growable: false);

    // A clean report gets the neutral treatment, not a green one. Colour on
    // this card means "something to decide"; spending it on good news teaches
    // the reader that the card is decorative and can be skipped, which is the
    // one thing it must not be. Findings are already worst-first, so the first
    // flagged one is the accent.
    final accent = report.flagged.isEmpty
        ? Palette.slate
        : licenseRuleColor(report.flagged.first.rule, theme);

    return SpineCard(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            icon: Icons.balance_outlined,
            title: 'License compliance',
            accent: accent,
            trailing: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final entry in report.counts.entries)
                  Text(
                    '${entry.value} ${entry.key.label.toLowerCase()}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: licenseRuleColor(entry.key, theme),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          if (!result.policyIsCustom) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.info_outline,
              // Whose decision the reader is looking at. Without this, a
              // forbidden dependency reads as company policy when in fact
              // nobody here has written one.
              text: 'Judged against the standard rules — nobody has written '
                  'a policy for this account yet.',
            ),
          ],
          if (forbidden.isEmpty && review.isEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Every dependency whose license was read clears the policy.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
          for (final finding in forbidden) _Finding(finding: finding),
          for (final finding in review.take(_reviewShown))
            _Finding(finding: finding),
          if (review.length > _reviewShown) ...[
            const SizedBox(height: 8),
            Text(
              '+${review.length - _reviewShown} more needing review — the '
              'manifest lists them all.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (report.unchecked.isNotEmpty) ...[
            const SizedBox(height: 10),
            _Note(
              icon: Icons.help_outline,
              // Not folded into the counts: these were never checked, and a
              // number that mixes them with checked packages would say this
              // report covers more than it does. Not listed as findings
              // either — an SDK dependency is not something a reviewer can
              // act on.
              text: '${report.unchecked.length} '
                  'package${report.unchecked.length == 1 ? '' : 's'} '
                  'could not be checked — the manifest says why for each.',
            ),
          ],
          if (report.licenseCounts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'In use: ${_inventory(report)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (onShowManifest != null || onEditPolicy != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                if (onShowManifest != null)
                  OutlinedButton.icon(
                    onPressed: onShowManifest,
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('Manifest for review'),
                  ),
                if (onEditPolicy != null)
                  TextButton.icon(
                    onPressed: onEditPolicy,
                    icon: const Icon(Icons.rule_outlined, size: 18),
                    label: const Text('Policy'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// `MIT 30 · BSD-3-Clause 8 · Apache-2.0 4 · +3 more`.
  static String _inventory(LicenseReport report) {
    final entries = report.licenseCounts.entries.toList();
    final shown = entries.take(5).map((e) => '${e.key} ${e.value}');
    return [
      ...shown,
      if (entries.length > 5) '+${entries.length - 5} more',
    ].join('  ·  ');
  }
}

/// One package the policy will not clear, and why.
class _Finding extends StatelessWidget {
  const _Finding({required this.finding});

  final LicenseFinding finding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caveat = finding.license.caveat;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: finding.package,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: ' ${finding.version}'),
                      if (finding.devOnly)
                        TextSpan(
                          text: '  (dev only)',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              LicenseRuleChip(
                rule: finding.rule,
                license: finding.license.spdxId,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(finding.reason, style: theme.textTheme.bodySmall),
          // The one part of a finding that is inferred rather than read: the
          // license came from a different release than the one installed.
          if (caveat != null) ...[
            const SizedBox(height: 2),
            Text(
              caveat,
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.textTheme.bodySmall?.color;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

/// The manifest, ready to be taken somewhere else.
///
/// Shown and copied rather than downloaded: a download from a Flutter Web app
/// means reaching for browser APIs that do not exist when this widget is under
/// test, and the same document is one authenticated GET away for anyone
/// scripting it — see the CSV endpoint in the README.
class _ManifestDialog extends StatelessWidget {
  const _ManifestDialog({required this.csv});

  final String csv;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = csv.split('\r\n').length - 1;

    return AlertDialog(
      title: const Text('License manifest'),
      content: SizedBox(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$rows dependenc${rows == 1 ? 'y' : 'ies'}, as CSV.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    csv,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Courier New', 'monospace'],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: csv));
            if (context.mounted) Navigator.of(context).pop();
          },
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}

/// The rules, one row per obligation family.
///
/// Families rather than individual licenses, because that is what a policy is
/// actually decided on — the question is whether a dependency can oblige you to
/// publish your own source, not how you feel about BSD-2-Clause as distinct
/// from BSD-3-Clause. Exceptions for named licenses go through the API; they
/// are rare and they are not a checkbox.
class _PolicyDialog extends StatefulWidget {
  const _PolicyDialog({
    required this.policy,
    required this.isCustom,
    required this.canReset,
  });

  final LicensePolicy policy;
  final bool isCustom;
  final bool canReset;

  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  late Map<LicenseCategory, LicenseRule> _categories;
  late bool _checkDev;

  @override
  void initState() {
    super.initState();
    // Read through `ruleForCategory` so every row starts on a concrete rule,
    // including the families a stored policy has no entry for.
    _categories = {
      for (final category in LicenseCategory.values)
        category: widget.policy.ruleForCategory(category),
    };
    _checkDev = widget.policy.checkDevDependencies;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('License policy'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.isCustom
                    ? 'Applies to every project in this account.'
                    : 'Nobody has written one yet — these are the standard '
                        'rules, and saving makes them yours to change.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final category in LicenseCategory.values) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            category.label,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            category.obligation,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    DropdownButton<LicenseRule>(
                      key: ValueKey('rule-${category.name}'),
                      value: _categories[category],
                      onChanged: (rule) => setState(() {
                        if (rule != null) _categories[category] = rule;
                      }),
                      items: [
                        for (final rule in LicenseRule.values)
                          DropdownMenuItem(
                            value: rule,
                            child: Text(rule.label),
                          ),
                      ],
                    ),
                  ],
                ),
                const Divider(height: 20),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _checkDev,
                onChanged: (on) => setState(() => _checkDev = on),
                title: const Text('Check dev dependencies too'),
                subtitle: const Text(
                  'Off by default: a code generator or test runner is not '
                  'linked into what you ship. Turn it on if you redistribute '
                  'your toolchain.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canReset)
          TextButton(
            onPressed: () => Navigator.of(context).pop(const _ResetPolicy()),
            child: const Text('Reset to standard'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _SavePolicy(
              LicensePolicy(
                categories: _categories,
                // Named exceptions are not editable here, so they are carried
                // through untouched rather than silently dropped by a save.
                licenses: widget.policy.licenses,
                checkDevDependencies: _checkDev,
              ),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
